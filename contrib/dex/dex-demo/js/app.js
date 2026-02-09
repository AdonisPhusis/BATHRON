/**
 * KPIV DEX - Main Application Logic
 *
 * Orchestrates the 2-HTLC atomic swap flow:
 * 1. Retail generates secret S, hashlock H
 * 2. Retail locks USDC on Polygon
 * 3. LP creates KPIV HTLC on BATHRON
 * 4. Retail claims KPIV (reveals S)
 * 5. LP claims USDC with S
 */

// =============================================================================
// CONFIGURATION
// =============================================================================

const CONFIG = {
    // SDK API endpoint
    SDK_API: 'http://162.19.251.75:8080/api',

    // LP Polygon address (Hot Wallet - for receiving USDC locks)
    LP_POLYGON_ADDRESS: '0xA1b41Fb9D8d82bDcA0bA5D7115D4C04be64171B6',

    // Refresh intervals
    ORDERBOOK_REFRESH_MS: 10000,  // 10 seconds
    SWAP_STATUS_REFRESH_MS: 5000, // 5 seconds

    // Local storage keys
    STORAGE_BATHRON_ADDRESS: 'kpiv_dex_bathron_address',
    STORAGE_ACTIVE_SWAPS: 'kpiv_dex_active_swaps'
};

// =============================================================================
// STATE
// =============================================================================

const State = {
    // Wallet state
    walletConnected: false,
    walletAddress: null,
    usdcBalance: '0',

    // Orderbook state
    orderbook: null,
    selectedLot: null,

    // Swap state
    activeSwaps: [],

    // Intervals
    orderbookInterval: null,
    swapStatusInterval: null
};

// =============================================================================
// WALLET CONNECTION
// =============================================================================

async function connectWallet() {
    const statusEl = document.getElementById('connect-prompt');
    const originalContent = statusEl ? statusEl.innerHTML : '';

    try {
        // Show loading state
        if (statusEl) {
            statusEl.innerHTML = '<div class="prompt-icon">⏳</div><h3>Connecting...</h3><p>Check MetaMask popup</p>';
        }

        if (!window.ethereum) {
            alert('MetaMask not found!\n\nPlease install MetaMask extension to use this DEX.');
            if (statusEl) statusEl.innerHTML = originalContent;
            return;
        }

        console.log('[App] Requesting accounts...');

        // Request accounts
        const accounts = await window.ethereum.request({
            method: 'eth_requestAccounts'
        });

        if (accounts.length === 0) {
            alert('No accounts found. Please unlock MetaMask.');
            if (statusEl) statusEl.innerHTML = originalContent;
            return;
        }

        console.log('[App] Got account:', accounts[0]);

        // Create provider and signer
        let provider = new ethers.BrowserProvider(window.ethereum);
        let signer = await provider.getSigner();
        State.walletAddress = accounts[0];

        // Detect current MetaMask network and set HTLC accordingly
        const network = await provider.getNetwork();
        const chainId = Number(network.chainId);

        // Find matching network in our config
        let matchedNetwork = null;
        for (const [key, config] of Object.entries(NETWORKS)) {
            if (config.chainId === chainId && config.enabled) {
                matchedNetwork = key;
                break;
            }
        }

        if (matchedNetwork) {
            // User is already on a supported network
            HTLC.currentNetwork = matchedNetwork;
            document.getElementById('network-select').value = matchedNetwork;
            document.getElementById('network-name').textContent = NETWORKS[matchedNetwork].name;
            console.log('[App] Using current network:', matchedNetwork);
        } else {
            // User is on unsupported network, switch to Polygon
            if (statusEl) {
                statusEl.innerHTML = '<div class="prompt-icon">🔄</div><h3>Switching Network...</h3><p>Please confirm in MetaMask</p>';
            }
            HTLC.currentNetwork = 'polygon';
            await HTLC.switchNetwork();
            // Recreate provider after switch
            await new Promise(resolve => setTimeout(resolve, 500));
            provider = new ethers.BrowserProvider(window.ethereum);
            signer = await provider.getSigner();
        }

        // Initialize HTLC module
        await HTLC.init(provider, signer);
        console.log('[App] HTLC initialized on', HTLC.currentNetwork);

        // Initialize SecretVault (requires signature)
        if (statusEl) {
            statusEl.innerHTML = '<div class="prompt-icon">🔐</div><h3>Vault Setup</h3><p>Please sign the message in MetaMask to enable encrypted secret storage</p>';
        }

        await SecretVault.init(State.walletAddress, async (message) => {
            return await signer.signMessage(message);
        });
        console.log('[App] Vault initialized');

        // Get USDC balance
        State.usdcBalance = await HTLC.getUSDCBalance();
        console.log('[App] USDC balance:', State.usdcBalance);

        // Update UI
        State.walletConnected = true;
        updateWalletUI();

        // Load saved BATHRON address
        loadBathronAddress();

        // Start refresh intervals
        startRefreshIntervals();

        // Load active swaps
        loadActiveSwaps();

        console.log('[App] Wallet connected:', State.walletAddress);

    } catch (error) {
        console.error('[App] Connection error:', error);
        alert('Connection failed: ' + error.message);
        if (statusEl) statusEl.innerHTML = originalContent;
    }
}

function updateWalletUI() {
    const connectBtn = document.getElementById('connect-btn');
    const walletStatus = document.getElementById('wallet-status');
    const connectPrompt = document.getElementById('connect-prompt');
    const swapForm = document.getElementById('swap-form');
    const displayAddress = document.getElementById('display-address');
    const usdcBalance = document.getElementById('usdc-balance');
    const networkBadge = document.getElementById('network-badge');

    if (State.walletConnected) {
        // Update button
        walletStatus.textContent = State.walletAddress.slice(0, 6) + '...' + State.walletAddress.slice(-4);
        connectBtn.classList.add('connected');

        // Show swap form
        connectPrompt.style.display = 'none';
        swapForm.style.display = 'block';

        // Update wallet info
        displayAddress.textContent = State.walletAddress.slice(0, 10) + '...' + State.walletAddress.slice(-8);
        usdcBalance.textContent = parseFloat(State.usdcBalance).toFixed(2);

        // Update network badge
        networkBadge.classList.add('connected');
    } else {
        walletStatus.textContent = 'Connect';
        connectBtn.classList.remove('connected');
        connectPrompt.style.display = 'block';
        swapForm.style.display = 'none';
        networkBadge.classList.remove('connected');
    }
}

// Handle account changes
if (window.ethereum) {
    window.ethereum.on('accountsChanged', (accounts) => {
        if (accounts.length === 0) {
            State.walletConnected = false;
            State.walletAddress = null;
            updateWalletUI();
        } else {
            // Reconnect with new account
            connectWallet();
        }
    });

    window.ethereum.on('chainChanged', () => {
        window.location.reload();
    });
}

// =============================================================================
// ORDERBOOK
// =============================================================================

async function refreshOrderbook() {
    try {
        const response = await fetch(`${CONFIG.SDK_API}/orderbook?pair=KPIV/USDC`);
        if (!response.ok) {
            throw new Error('Failed to fetch orderbook');
        }

        State.orderbook = await response.json();
        renderOrderbook();
        updateLastUpdate();

    } catch (error) {
        console.error('[App] Orderbook error:', error);
        // Show empty orderbook with error
        State.orderbook = { asks: [], bids: [], best_ask: null, best_bid: null };
        renderOrderbook();
    }
}

function renderOrderbook() {
    const asksList = document.getElementById('asks-list');
    const bidsList = document.getElementById('bids-list');
    const bestAsk = document.getElementById('best-ask');
    const bestBid = document.getElementById('best-bid');
    const spread = document.getElementById('spread');
    const spreadDisplay = document.getElementById('spread-display');

    if (!State.orderbook) return;

    // Render asks (reversed so lowest price is at bottom, closest to spread)
    const asksReversed = [...(State.orderbook.asks || [])].reverse();
    asksList.innerHTML = asksReversed.map(ask => `
        <div class="orderbook-row ask" onclick="selectLot('${ask.lot_id}', 'ask', ${ask.price}, ${ask.size})">
            <span class="price">${ask.price.toFixed(4)}</span>
            <span class="size">${formatNumber(ask.size)}</span>
            <span class="total">${formatNumber(ask.total)}</span>
            <div class="depth-bar" style="width: ${(ask.size / (State.orderbook.asks[0]?.total || 1)) * 100}%"></div>
        </div>
    `).join('');

    // Render bids
    bidsList.innerHTML = (State.orderbook.bids || []).map(bid => `
        <div class="orderbook-row bid" onclick="selectLot('${bid.lot_id}', 'bid', ${bid.price}, ${bid.size})">
            <span class="price">${bid.price.toFixed(4)}</span>
            <span class="size">${formatNumber(bid.size)}</span>
            <span class="total">${formatNumber(bid.total)}</span>
            <div class="depth-bar" style="width: ${(bid.size / (State.orderbook.bids[0]?.total || 1)) * 100}%"></div>
        </div>
    `).join('');

    // Update stats
    bestAsk.textContent = State.orderbook.best_ask ? State.orderbook.best_ask.toFixed(4) : '-';
    bestBid.textContent = State.orderbook.best_bid ? State.orderbook.best_bid.toFixed(4) : '-';

    if (State.orderbook.spread_pct) {
        spread.textContent = State.orderbook.spread_pct.toFixed(2) + '%';
        spreadDisplay.textContent = State.orderbook.spread_pct.toFixed(2) + '%';
    } else {
        spread.textContent = '-';
        spreadDisplay.textContent = '-';
    }
}

function selectLot(lotId, side, price, size) {
    State.selectedLot = { lotId, side, price, size };

    // Highlight selected row
    document.querySelectorAll('.orderbook-row').forEach(row => row.classList.remove('selected'));
    event.currentTarget.classList.add('selected');

    // Auto-fill amount with LOT size
    const amountInput = document.getElementById('amount-input');
    if (amountInput) {
        amountInput.value = size;
    }

    // Update preview
    updatePreview();
}

function updateLastUpdate() {
    const lastUpdate = document.getElementById('last-update');
    const now = new Date();
    lastUpdate.textContent = `Updated: ${now.toLocaleTimeString()}`;
}

// =============================================================================
// SWAP FLOW
// =============================================================================

function updatePreview() {
    const amountInput = document.getElementById('amount-input');
    const previewPay = document.getElementById('preview-pay');
    const previewReceive = document.getElementById('preview-receive');
    const previewPrice = document.getElementById('preview-price');
    const previewLp = document.getElementById('preview-lp');
    const swapBtn = document.getElementById('swap-btn');

    const amount = parseFloat(amountInput.value) || 0;

    // Get best ask price if no lot selected
    let price = State.selectedLot?.price || State.orderbook?.best_ask || 0;

    if (amount > 0 && price > 0) {
        const totalUsdc = amount * price;

        previewPay.textContent = totalUsdc.toFixed(2) + ' USDC';
        previewReceive.textContent = formatNumber(amount) + ' KPIV';
        previewPrice.textContent = price.toFixed(4) + ' USDC/KPIV';
        previewLp.textContent = CONFIG.LP_POLYGON_ADDRESS.slice(0, 10) + '...';

        // Check if user has enough balance
        const hasBalance = parseFloat(State.usdcBalance) >= totalUsdc;
        const hasBathronAddr = document.getElementById('bathron-address').value.length > 0;

        swapBtn.disabled = !hasBalance || !hasBathronAddr;

        if (!hasBalance) {
            swapBtn.querySelector('.btn-text').textContent = 'Insufficient USDC';
        } else if (!hasBathronAddr) {
            swapBtn.querySelector('.btn-text').textContent = 'Enter BATHRON Address';
        } else {
            swapBtn.querySelector('.btn-text').textContent = 'Lock USDC';
        }
    } else {
        previewPay.textContent = '0.00 USDC';
        previewReceive.textContent = '0 KPIV';
        previewPrice.textContent = '-';
        previewLp.textContent = '-';
        swapBtn.disabled = true;
    }
}

function setAmount(amount) {
    document.getElementById('amount-input').value = amount;
    updatePreview();
}

async function initiateSwap() {
    const amountInput = document.getElementById('amount-input');
    const bathronAddress = document.getElementById('bathron-address').value.trim();

    const kpivAmount = parseFloat(amountInput.value);
    const price = State.selectedLot?.price || State.orderbook?.best_ask;
    const usdcAmount = kpivAmount * price;
    const lotId = State.selectedLot?.lotId || State.orderbook?.asks?.[0]?.lot_id;

    if (!kpivAmount || !price || !bathronAddress) {
        showStatus('error', 'Please fill all fields');
        return;
    }

    // Validate BATHRON address
    if (!bathronAddress.match(/^[xy][a-km-zA-HJ-NP-Z1-9]{25,34}$/)) {
        showStatus('error', 'Invalid BATHRON address format');
        return;
    }

    try {
        showSwapStatus('pending', 'Generating secret...');

        // Step 1: Generate secret and hashlock
        const { secret, hashlock } = await SecretVault.generateSecret();
        console.log('[Swap] Generated hashlock:', hashlock.slice(0, 16) + '...');

        // Step 2: Store secret encrypted
        await SecretVault.storeSecret(hashlock, secret, {
            kpivAmount,
            usdcAmount,
            price,
            bathronAddress,
            lotId,
            lpAddress: CONFIG.LP_POLYGON_ADDRESS,
            status: 'PENDING'
        });

        // Step 3: Register swap with SDK
        showSwapStatus('pending', 'Registering swap...');
        const registerResponse = await fetch(`${CONFIG.SDK_API}/register`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                hashlock: hashlock,
                taker_kpiv_addr: bathronAddress,
                lot_id: lotId
            })
        });

        if (!registerResponse.ok) {
            throw new Error('Failed to register swap');
        }

        // Step 4: Approve USDC (if needed)
        showSwapStatus('pending', 'Approving USDC...');
        await HTLC.approveUSDC(usdcAmount);

        // Step 5: Lock USDC in HTLC
        showSwapStatus('pending', 'Locking USDC in HTLC...');
        const lockResult = await HTLC.lockUSDC(
            CONFIG.LP_POLYGON_ADDRESS,
            usdcAmount,
            hashlock,
            HTLC.DEFAULT_TIMELOCK_USDC
        );

        // Step 6: Save swap to active swaps
        const swap = {
            hashlock,
            swapId: lockResult.swapId,
            txHash: lockResult.txHash,
            kpivAmount,
            usdcAmount,
            price,
            bathronAddress,
            status: 'USDC_LOCKED',
            createdAt: Date.now()
        };

        State.activeSwaps.push(swap);
        saveActiveSwaps();

        // Step 7: Update SDK with swap_id (critical for Polygon HTLC lookup!)
        try {
            await fetch(`${CONFIG.SDK_API}/update_swap`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    hashlock: hashlock,
                    swap_id: lockResult.swapId,
                    tx_hash: lockResult.txHash
                })
            });
            console.log('[Swap] Updated SDK with swap_id:', lockResult.swapId.slice(0, 16) + '...');
        } catch (e) {
            console.warn('[Swap] Failed to update SDK with swap_id:', e);
        }

        // Update UI
        showSwapStatus('success', `USDC locked! Waiting for LP to create KPIV HTLC...`);
        updatePreview();
        refreshBalance();

        // Switch to portfolio page to track swap
        setTimeout(() => {
            switchPage('portfolio');
            loadSwaps();
        }, 2000);

    } catch (error) {
        console.error('[Swap] Error:', error);
        showSwapStatus('error', 'Swap failed: ' + error.message);
    }
}

// =============================================================================
// SWAP TRACKING
// =============================================================================

function loadActiveSwaps() {
    const saved = localStorage.getItem(CONFIG.STORAGE_ACTIVE_SWAPS);
    if (saved) {
        try {
            State.activeSwaps = JSON.parse(saved);
        } catch (e) {
            State.activeSwaps = [];
        }
    }
}

function saveActiveSwaps() {
    // Handle BigInt serialization (from blockchain data)
    const replacer = (key, value) =>
        typeof value === 'bigint' ? value.toString() : value;
    localStorage.setItem(CONFIG.STORAGE_ACTIVE_SWAPS, JSON.stringify(State.activeSwaps, replacer));
}

async function loadSwaps() {
    const swapsList = document.getElementById('swaps-list');

    if (State.activeSwaps.length === 0) {
        swapsList.innerHTML = `
            <div class="empty-state">
                <div class="empty-icon">📭</div>
                <p>No swaps yet</p>
                <p class="hint">Start trading to see your swap history</p>
            </div>
        `;
        return;
    }

    // Update status of each swap
    for (const swap of State.activeSwaps) {
        // Skip already completed/refunded swaps
        if (['COMPLETED', 'USDC_REFUNDED', 'KPIV_REFUNDED'].includes(swap.status)) {
            continue;
        }

        try {
            // Check Polygon HTLC status
            const htlcState = await HTLC.getSwap(swap.swapId);

            // Check if KPIV HTLC exists on BATHRON chain
            let kpivHtlcFound = false;
            let kpivHtlc = null;
            try {
                const htlcResponse = await fetch(`${CONFIG.SDK_API}/htlc/find_by_hashlock/${swap.hashlock}`);
                const htlcData = await htlcResponse.json();
                kpivHtlcFound = htlcData.found;
                kpivHtlc = htlcData.htlc;
            } catch (e) {
                console.warn('[Swap] Could not check KPIV HTLC:', e);
            }

            // Update swap status
            if (htlcState.withdrawn) {
                swap.status = 'COMPLETED';
            } else if (htlcState.refunded) {
                swap.status = 'USDC_REFUNDED';
            } else if (htlcState.status === 'EXPIRED' && !kpivHtlcFound) {
                // ═══════════════════════════════════════════════════════════
                // AUTO-REFUND: USDC expired and LP never created KPIV HTLC
                // ═══════════════════════════════════════════════════════════
                console.log('[AutoRefund] USDC HTLC expired, no KPIV HTLC found');
                console.log('[AutoRefund] Initiating auto-refund for swap:', swap.hashlock.slice(0, 16) + '...');
                showSwapStatus('pending', 'USDC HTLC expired. Auto-refunding...');

                const refunded = await refundUsdc(swap.swapId, true);
                if (refunded) {
                    swap.status = 'USDC_REFUNDED';
                    showSwapStatus('success', 'USDC refunded automatically!');
                }
            } else if (kpivHtlcFound && kpivHtlc) {
                // KPIV HTLC exists on BATHRON chain
                if (kpivHtlc.status === 'claimed') {
                    swap.status = 'COMPLETED';
                } else if (kpivHtlc.status === 'locked') {
                    swap.status = 'KPIV_LOCKED';
                    swap.kpivHtlc = kpivHtlc;

                    // ═══════════════════════════════════════════════════════════
                    // AUTO-CLAIM: Automatically claim KPIV when HTLC is detected
                    // ═══════════════════════════════════════════════════════════
                    console.log('[AutoClaim] KPIV HTLC detected for swap:', swap.hashlock.slice(0, 16) + '...');
                    console.log('[AutoClaim] HTLC amount:', kpivHtlc.amount, 'KPIV');

                    // Verify amount matches expected
                    const expectedAmount = swap.kpivAmount;
                    const actualAmount = parseFloat(kpivHtlc.amount);

                    if (actualAmount >= expectedAmount * 0.99) { // Allow 1% tolerance for fees
                        console.log('[AutoClaim] Amount OK, initiating auto-claim...');
                        showSwapStatus('pending', 'KPIV HTLC detected! Auto-claiming...');

                        // Attempt auto-claim
                        const claimed = await claimKpiv(swap.hashlock, true);
                        if (claimed) {
                            swap.status = 'COMPLETED';
                            showSwapStatus('success', 'KPIV claimed automatically!');
                        }
                    } else {
                        console.warn('[AutoClaim] Amount mismatch! Expected:', expectedAmount, 'Got:', actualAmount);
                        showSwapStatus('error', `KPIV amount mismatch: expected ${expectedAmount}, got ${actualAmount}`);
                    }
                }
            } else {
                swap.status = 'USDC_LOCKED';
            }

            swap.htlcState = htlcState;

        } catch (error) {
            console.error('[Swap] Status check error:', error);
        }
    }

    saveActiveSwaps();
    renderSwaps();
}

function renderSwaps() {
    const swapsList = document.getElementById('swaps-list');

    const activeSwaps = State.activeSwaps.filter(s =>
        !['COMPLETED', 'USDC_REFUNDED', 'KPIV_REFUNDED'].includes(s.status)
    );
    const completedSwaps = State.activeSwaps.filter(s =>
        ['COMPLETED', 'USDC_REFUNDED', 'KPIV_REFUNDED'].includes(s.status)
    );

    let html = '';

    // Active swaps
    if (activeSwaps.length > 0) {
        html += `
            <div class="swaps-section">
                <h3>Active Swaps</h3>
                ${activeSwaps.map(swap => renderSwapCard(swap, true)).join('')}
            </div>
        `;
    }

    // Completed swaps
    if (completedSwaps.length > 0) {
        html += `
            <div class="swaps-section">
                <h3>Completed Swaps</h3>
                ${completedSwaps.map(swap => renderSwapCard(swap, false)).join('')}
            </div>
        `;
    }

    if (html === '') {
        html = `
            <div class="empty-state">
                <div class="empty-icon">📭</div>
                <p>No swaps yet</p>
                <p class="hint">Start trading to see your swap history</p>
            </div>
        `;
    }

    swapsList.innerHTML = html;
}

function renderSwapCard(swap, isActive) {
    const statusColors = {
        'USDC_LOCKED': 'status-pending',
        'KPIV_LOCKED': 'status-ready',
        'COMPLETED': 'status-success',
        'USDC_REFUNDED': 'status-refunded',
        'KPIV_REFUNDED': 'status-refunded'
    };

    const statusLabels = {
        'USDC_LOCKED': 'Waiting for LP',
        'KPIV_LOCKED': 'Ready to Claim',
        'COMPLETED': 'Completed',
        'USDC_REFUNDED': 'Refunded',
        'KPIV_REFUNDED': 'LP Refunded'
    };

    const timeRemaining = swap.htlcState?.timeRemainingFormatted || '-';

    return `
        <div class="swap-card ${isActive ? 'active' : ''}">
            <div class="swap-header">
                <span class="swap-id">Swap #${swap.hashlock.slice(0, 8)}...</span>
                <span class="swap-status ${statusColors[swap.status] || ''}">${statusLabels[swap.status] || swap.status}</span>
            </div>
            <div class="swap-details">
                <div class="swap-row">
                    <span class="label">Paying:</span>
                    <span class="value">${swap.usdcAmount.toFixed(2)} USDC</span>
                </div>
                <div class="swap-row">
                    <span class="label">Receiving:</span>
                    <span class="value">${swap.kpivAmount} KPIV</span>
                </div>
                <div class="swap-row">
                    <span class="label">BATHRON Address:</span>
                    <span class="value small">${swap.bathronAddress.slice(0, 12)}...</span>
                </div>
                ${isActive ? `
                    <div class="swap-row">
                        <span class="label">Time Remaining:</span>
                        <span class="value">${timeRemaining}</span>
                    </div>
                ` : ''}
            </div>
            <div class="swap-actions">
                <a href="${HTLC.getPolygonscanUrl(swap.txHash)}" target="_blank" class="btn-link">
                    View on Polygonscan
                </a>
                ${swap.status === 'KPIV_LOCKED' ? `
                    <button onclick="claimKpiv('${swap.hashlock}')" class="btn-action btn-claim">
                        Claim KPIV
                    </button>
                ` : ''}
                ${swap.status === 'USDC_LOCKED' && swap.htlcState?.status === 'EXPIRED' ? `
                    <button onclick="refundUsdc('${swap.swapId}')" class="btn-action btn-refund">
                        Refund USDC
                    </button>
                ` : ''}
            </div>
        </div>
    `;
}

async function claimKpiv(hashlock, autoMode = false) {
    /**
     * Claim KPIV HTLC via SDK API.
     * @param {string} hashlock - The HTLC hashlock
     * @param {boolean} autoMode - If true, suppress UI alerts (called from auto-claim)
     */
    try {
        if (!autoMode) {
            showSwapStatus('pending', 'Claiming KPIV...');
        }

        // Get secret from vault
        const secretData = await SecretVault.getSecret(hashlock);
        if (!secretData) {
            if (!autoMode) {
                showSwapStatus('error', 'Secret not found in vault');
            }
            console.error('[Claim] Secret not found for hashlock:', hashlock.slice(0, 16) + '...');
            return false;
        }

        console.log('[Claim] Claiming KPIV with hashlock:', hashlock.slice(0, 16) + '...');

        // Call SDK API to claim
        const response = await fetch(`${CONFIG.SDK_API}/htlc/claim_kpiv`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                hashlock: hashlock,
                preimage: secretData.secret
            })
        });

        const result = await response.json();

        if (!response.ok || !result.success) {
            const errorMsg = result.error || 'Claim failed';
            if (!autoMode) {
                showSwapStatus('error', 'Claim failed: ' + errorMsg);
            }
            console.error('[Claim] Failed:', errorMsg);
            return false;
        }

        console.log('[Claim] Success! TX:', result.txid);

        // Update swap status
        const swap = State.activeSwaps.find(s => s.hashlock === hashlock);
        if (swap) {
            swap.status = 'COMPLETED';
            swap.claimTxid = result.txid;
            saveActiveSwaps();
        }

        if (!autoMode) {
            showSwapStatus('success', 'KPIV claimed successfully!');
        }

        // Refresh UI
        loadSwaps();
        return true;

    } catch (error) {
        console.error('[Claim] Error:', error);
        if (!autoMode) {
            showSwapStatus('error', 'Claim error: ' + error.message);
        }
        return false;
    }
}

async function refundUsdc(swapId, autoMode = false) {
    /**
     * Refund USDC from expired HTLC on Polygon.
     * @param {string} swapId - The Polygon HTLC swap ID
     * @param {boolean} autoMode - If true, suppress UI alerts (called from auto-refund)
     */
    try {
        if (!autoMode) {
            showSwapStatus('pending', 'Refunding USDC...');
        }
        console.log('[Refund] Refunding USDC for swap:', swapId.slice(0, 16) + '...');

        await HTLC.refund(swapId);

        // Update swap status
        const swap = State.activeSwaps.find(s => s.swapId === swapId);
        if (swap) {
            swap.status = 'USDC_REFUNDED';
            saveActiveSwaps();
        }

        if (!autoMode) {
            showSwapStatus('success', 'USDC refunded successfully!');
        }
        console.log('[Refund] Success!');

        loadSwaps();
        refreshBalance();
        return true;

    } catch (error) {
        console.error('[Refund] Error:', error);
        if (!autoMode) {
            showSwapStatus('error', 'Refund failed: ' + error.message);
        }
        return false;
    }
}

// =============================================================================
// UI HELPERS
// =============================================================================

function showStatus(type, message) {
    // Remove existing status after 5 seconds
    setTimeout(() => {
        // Could implement toast notifications here
    }, 5000);
    console.log(`[Status:${type}] ${message}`);
}

function showSwapStatus(type, message) {
    const statusDiv = document.getElementById('swap-status');
    const statusIcon = statusDiv.querySelector('.status-icon');
    const statusText = statusDiv.querySelector('.status-text');

    statusDiv.style.display = 'block';
    statusDiv.className = `swap-status ${type}`;

    const icons = {
        'pending': '⏳',
        'success': '✓',
        'error': '✗',
        'info': 'ℹ'
    };

    statusIcon.textContent = icons[type] || '•';
    statusText.textContent = message;
}

function formatNumber(num) {
    if (num >= 1000000) {
        return (num / 1000000).toFixed(1) + 'M';
    }
    if (num >= 1000) {
        return (num / 1000).toFixed(1) + 'K';
    }
    return num.toLocaleString();
}

async function refreshBalance() {
    if (State.walletConnected) {
        State.usdcBalance = await HTLC.getUSDCBalance();
        document.getElementById('usdc-balance').textContent = parseFloat(State.usdcBalance).toFixed(2);
    }
}

// =============================================================================
// PAGE NAVIGATION
// =============================================================================

function switchPage(pageName) {
    // Update tabs
    document.querySelectorAll('.nav-tab').forEach(tab => {
        tab.classList.remove('active');
        if (tab.dataset.page === pageName) {
            tab.classList.add('active');
        }
    });

    // Update pages
    document.querySelectorAll('.page').forEach(page => {
        page.classList.remove('active');
    });
    document.getElementById(`${pageName}-page`).classList.add('active');

    // Load data if needed
    if (pageName === 'portfolio') {
        loadSwaps();
    } else if (pageName === 'trade') {
        refreshOrderbook();
    }
}

// Tab click handlers
document.querySelectorAll('.nav-tab').forEach(tab => {
    tab.addEventListener('click', (e) => {
        e.preventDefault();
        switchPage(tab.dataset.page);
    });
});

// =============================================================================
// BATHRON ADDRESS PERSISTENCE
// =============================================================================

function saveBathronAddress() {
    const address = document.getElementById('bathron-address').value;
    localStorage.setItem(CONFIG.STORAGE_BATHRON_ADDRESS, address);
    updatePreview();
}

function loadBathronAddress() {
    const saved = localStorage.getItem(CONFIG.STORAGE_BATHRON_ADDRESS);
    if (saved) {
        document.getElementById('bathron-address').value = saved;
    }
}

// =============================================================================
// INTERVALS
// =============================================================================

function startRefreshIntervals() {
    // Clear existing intervals
    if (State.orderbookInterval) clearInterval(State.orderbookInterval);
    if (State.swapStatusInterval) clearInterval(State.swapStatusInterval);

    // Orderbook refresh
    State.orderbookInterval = setInterval(refreshOrderbook, CONFIG.ORDERBOOK_REFRESH_MS);

    // Swap status refresh (only if on portfolio page)
    State.swapStatusInterval = setInterval(() => {
        if (document.getElementById('portfolio-page').classList.contains('active')) {
            loadSwaps();
        }
    }, CONFIG.SWAP_STATUS_REFRESH_MS);
}

// =============================================================================
// INITIALIZATION
// =============================================================================

document.addEventListener('DOMContentLoaded', async () => {
    console.log('[App] Initializing KPIV DEX...');

    // Initial orderbook load
    await refreshOrderbook();

    // Check if wallet was previously connected
    if (window.ethereum && window.ethereum.selectedAddress) {
        await connectWallet();
    }

    console.log('[App] Ready');
});

// =============================================================================
// RECOVERY FUNCTIONS
// =============================================================================

async function recoverSwaps() {
    /**
     * Recover swaps from SDK that might have secrets in vault
     */
    console.log('[Recovery] Checking SDK for pending swaps...');

    try {
        const response = await fetch(`${CONFIG.SDK_API}/pending_swaps`);
        const data = await response.json();
        const pendingSwaps = data.swaps || [];

        console.log(`[Recovery] Found ${pendingSwaps.length} pending swaps in SDK`);

        let recovered = 0;
        for (const sdkSwap of pendingSwaps) {
            const hashlock = sdkSwap.hashlock;

            // Check if we have this swap already
            const existing = State.activeSwaps.find(s => s.hashlock === hashlock);
            if (existing) {
                console.log(`[Recovery] Swap ${hashlock.slice(0, 12)}... already tracked`);
                continue;
            }

            // Check if we have the secret in vault
            const secretData = await SecretVault.getSecret(hashlock);
            if (secretData) {
                console.log(`[Recovery] Found secret for ${hashlock.slice(0, 12)}... - recovering!`);

                // Reconstruct swap from SDK data + vault
                const swap = {
                    hashlock: hashlock,
                    swapId: sdkSwap.swap_id,
                    txHash: sdkSwap.tx_hash,
                    kpivAmount: sdkSwap.kpiv_amount || secretData.metadata?.kpivAmount || 0,
                    usdcAmount: secretData.metadata?.usdcAmount || 0,
                    price: secretData.metadata?.price || 0.05,
                    bathronAddress: sdkSwap.taker_kpiv_addr,
                    status: sdkSwap.kpiv_sent ? 'KPIV_LOCKED' : 'USDC_LOCKED',
                    createdAt: sdkSwap.registered_at * 1000
                };

                State.activeSwaps.push(swap);
                recovered++;
            } else {
                console.log(`[Recovery] No secret found for ${hashlock.slice(0, 12)}...`);
            }
        }

        if (recovered > 0) {
            saveActiveSwaps();
            console.log(`[Recovery] Recovered ${recovered} swaps!`);
            alert(`Recovered ${recovered} swap(s) from vault!`);
            loadSwaps();
        } else {
            console.log('[Recovery] No swaps to recover');
            alert('No recoverable swaps found. Secrets may have been lost.');
        }

    } catch (error) {
        console.error('[Recovery] Error:', error);
        alert('Recovery failed: ' + error.message);
    }
}

function listVaultSecrets() {
    /**
     * Debug: List all secrets in vault
     */
    const secrets = SecretVault.listSecrets();
    console.log('[Vault] Stored secrets:', secrets);
    return secrets;
}

// =============================================================================
// NETWORK SWITCHING
// =============================================================================

async function switchNetwork(networkKey) {
    try {
        console.log('[App] Switching to network:', networkKey);

        // Update HTLC module network config
        HTLC.currentNetwork = networkKey;

        // Switch MetaMask to the new network
        await HTLC.switchNetwork();

        // Wait a moment for MetaMask to complete the switch
        await new Promise(resolve => setTimeout(resolve, 500));

        // Recreate provider and signer after network change
        const provider = new ethers.BrowserProvider(window.ethereum);
        const signer = await provider.getSigner();

        // Reinitialize HTLC with new provider/signer
        await HTLC.init(provider, signer);

        // Update UI
        const networkInfo = HTLC.getNetworkInfo();
        document.getElementById('network-name').textContent = networkInfo.name;

        // Refresh balance
        if (State.walletConnected) {
            State.usdcBalance = await HTLC.getUSDCBalance();
            document.getElementById('usdc-balance').textContent = parseFloat(State.usdcBalance).toFixed(2);
        }

        console.log('[App] Switched to', networkInfo.name);

    } catch (error) {
        console.error('[App] Network switch failed:', error);
        // Reset selector to current network
        document.getElementById('network-select').value = HTLC.currentNetwork;
        alert('Failed to switch network: ' + error.message);
    }
}

// Export functions for HTML onclick handlers
window.connectWallet = connectWallet;
window.refreshOrderbook = refreshOrderbook;
window.initiateSwap = initiateSwap;
window.setAmount = setAmount;
window.selectLot = selectLot;
window.saveBathronAddress = saveBathronAddress;
window.loadSwaps = loadSwaps;
window.claimKpiv = claimKpiv;
window.refundUsdc = refundUsdc;
window.recoverSwaps = recoverSwaps;
window.listVaultSecrets = listVaultSecrets;
window.switchNetwork = switchNetwork;
