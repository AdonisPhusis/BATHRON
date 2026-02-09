/**
 * HTLC - Multi-Chain HTLC Contract Interactions
 *
 * Handles all interactions with HTLC smart contracts on Polygon and Base.
 * Uses ethers.js v6 for Web3 interactions.
 */

// =============================================================================
// NETWORK CONFIGURATIONS
// =============================================================================

const NETWORKS = {
    polygon: {
        name: 'Polygon',
        chainId: 137,
        chainIdHex: '0x89',
        rpcUrl: 'https://polygon-rpc.com',
        explorer: 'https://polygonscan.com',
        nativeCurrency: { name: 'POL', symbol: 'POL', decimals: 18 },
        htlcAddress: '0x3F1843Bc98C526542d6112448842718adc13fA5F',
        usdcAddress: '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359',
        enabled: true
    },
    worldchain: {
        name: 'World Chain',
        chainId: 480,
        chainIdHex: '0x1e0',
        rpcUrl: 'https://worldchain-mainnet.g.alchemy.com/public',
        explorer: 'https://worldscan.org',
        nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
        htlcAddress: '0x7a8370b79Be8aBB2b9F72afd9Fba31D70D357F0b',
        usdcAddress: '0x79a02482a880bce3f13e09da970dc34db4cd24d1',
        enabled: true
    },
    base: {
        name: 'Base',
        chainId: 8453,
        chainIdHex: '0x2105',
        rpcUrl: 'https://mainnet.base.org',
        explorer: 'https://basescan.org',
        nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
        htlcAddress: '0xd7937b1C7D25239b4c829aDA9D137114fcefD9A8',
        usdcAddress: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
        enabled: true
    }
};

const HTLC = {
    // Current network (default: polygon)
    currentNetwork: 'polygon',

    // Dynamic addresses based on network
    get HTLC_ADDRESS() { return NETWORKS[this.currentNetwork].htlcAddress; },
    get USDC_ADDRESS() { return NETWORKS[this.currentNetwork].usdcAddress; },
    get CHAIN_ID() { return NETWORKS[this.currentNetwork].chainId; },

    // Default timelocks (in seconds)
    DEFAULT_TIMELOCK_USDC: 4 * 60 * 60,  // 4 hours for USDC (Retail locks)
    DEFAULT_TIMELOCK_KPIV: 2 * 60 * 60,  // 2 hours for KPIV (LP locks)

    // Contract ABIs (swapId is FIRST parameter for lock!)
    HTLC_ABI: [
        // Events
        'event Locked(bytes32 indexed swapId, address indexed sender, address indexed recipient, address token, uint256 amount, bytes32 hashlock, uint256 timelock)',
        'event Claimed(bytes32 indexed swapId, bytes32 preimage)',
        'event Refunded(bytes32 indexed swapId)',

        // Functions - NOTE: swapId is generated client-side and passed as first param
        'function lock(bytes32 swapId, address recipient, address token, uint256 amount, bytes32 hashlock, uint256 timelock) external',
        'function claim(bytes32 swapId, bytes32 preimage) external',
        'function refund(bytes32 swapId) external',
        'function swaps(bytes32) view returns (address sender, address recipient, address token, uint256 amount, bytes32 hashlock, uint256 timelock, bool withdrawn, bool refunded)'
    ],

    ERC20_ABI: [
        'function approve(address spender, uint256 amount) external returns (bool)',
        'function allowance(address owner, address spender) external view returns (uint256)',
        'function balanceOf(address account) external view returns (uint256)',
        'function decimals() external view returns (uint8)'
    ],

    provider: null,
    signer: null,
    htlcContract: null,
    usdcContract: null,

    /**
     * Initialize HTLC module with connected wallet
     * @param {object} provider - ethers provider
     * @param {object} signer - ethers signer
     */
    async init(provider, signer) {
        this.provider = provider;
        this.signer = signer;

        this.htlcContract = new ethers.Contract(
            this.HTLC_ADDRESS,
            this.HTLC_ABI,
            this.signer
        );

        this.usdcContract = new ethers.Contract(
            this.USDC_ADDRESS,
            this.ERC20_ABI,
            this.signer
        );

        console.log('[HTLC] Initialized');
        return true;
    },

    /**
     * Get list of available networks
     */
    getAvailableNetworks() {
        return Object.entries(NETWORKS)
            .filter(([_, config]) => config.enabled)
            .map(([key, config]) => ({ key, ...config }));
    },

    /**
     * Set current network
     */
    async setNetwork(networkKey) {
        if (!NETWORKS[networkKey]) {
            throw new Error(`Unknown network: ${networkKey}`);
        }
        if (!NETWORKS[networkKey].enabled) {
            throw new Error(`Network ${networkKey} is not enabled yet`);
        }
        this.currentNetwork = networkKey;
        console.log(`[HTLC] Switched to ${NETWORKS[networkKey].name}`);

        // Reinitialize contracts if already connected
        if (this.signer) {
            await this.initContracts();
        }
        return true;
    },

    /**
     * Initialize contracts for current network
     */
    async initContracts() {
        this.htlcContract = new ethers.Contract(
            this.HTLC_ADDRESS,
            this.HTLC_ABI,
            this.signer
        );

        this.usdcContract = new ethers.Contract(
            this.USDC_ADDRESS,
            this.ERC20_ABI,
            this.signer
        );
    },

    /**
     * Check if connected to current network
     */
    async checkNetwork() {
        const network = await this.provider.getNetwork();
        return Number(network.chainId) === this.CHAIN_ID;
    },

    /**
     * Switch to current network in MetaMask
     */
    async switchNetwork() {
        const config = NETWORKS[this.currentNetwork];
        const chainConfig = {
            chainId: config.chainIdHex,
            chainName: config.name,
            nativeCurrency: config.nativeCurrency,
            rpcUrls: [config.rpcUrl],
            blockExplorerUrls: [config.explorer]
        };

        try {
            // Try to switch first
            await window.ethereum.request({
                method: 'wallet_switchEthereumChain',
                params: [{ chainId: chainConfig.chainId }]
            });
            return true;
        } catch (error) {
            // If chain not added (4902) or unrecognized, add it
            if (error.code === 4902 || error.message.includes('Unrecognized chain')) {
                await window.ethereum.request({
                    method: 'wallet_addEthereumChain',
                    params: [chainConfig]
                });
                return true;
            }
            throw error;
        }
    },

    /**
     * Legacy alias for switchNetwork
     */
    async switchToPolygon() {
        this.currentNetwork = 'polygon';
        return this.switchNetwork();
    },

    /**
     * Get USDC balance
     * @returns {string} Balance in USDC (6 decimals)
     */
    async getUSDCBalance() {
        const address = await this.signer.getAddress();
        const balance = await this.usdcContract.balanceOf(address);
        return ethers.formatUnits(balance, 6);
    },

    /**
     * Get recommended gas settings for Polygon
     * Returns settings that ensure fast confirmation
     */
    async getGasSettings() {
        const feeData = await this.provider.getFeeData();
        // Use at least 50 Gwei, or 1.5x current price
        const minGasPrice = ethers.parseUnits('50', 'gwei');
        const recommendedGasPrice = feeData.gasPrice * 3n / 2n;  // 1.5x
        const gasPrice = recommendedGasPrice > minGasPrice ? recommendedGasPrice : minGasPrice;
        console.log('[HTLC] Gas price:', ethers.formatUnits(gasPrice, 'gwei'), 'Gwei');
        return { gasPrice };
    },

    /**
     * Approve USDC spending for HTLC contract
     * @param {string} amount - Amount in USDC
     */
    async approveUSDC(amount) {
        const amountWei = ethers.parseUnits(amount.toString(), 6);

        // Check current allowance
        const address = await this.signer.getAddress();
        const currentAllowance = await this.usdcContract.allowance(address, this.HTLC_ADDRESS);

        if (currentAllowance >= amountWei) {
            console.log('[HTLC] Already approved');
            return null;  // Already approved
        }

        console.log('[HTLC] Approving USDC...');
        const gasSettings = await this.getGasSettings();
        const tx = await this.usdcContract.approve(this.HTLC_ADDRESS, amountWei, gasSettings);
        const receipt = await tx.wait();
        console.log('[HTLC] Approved:', receipt.hash);
        return receipt;
    },

    /**
     * Lock USDC in HTLC
     *
     * @param {string} lpAddress - LP's Polygon address (recipient)
     * @param {string} amount - USDC amount
     * @param {string} hashlock - SHA256 hashlock (hex, no 0x prefix)
     * @param {number} timelockSeconds - Timelock in seconds (default 4h)
     * @returns {object} { swapId, txHash, receipt }
     */
    async lockUSDC(lpAddress, amount, hashlock, timelockSeconds = null) {
        if (!timelockSeconds) {
            timelockSeconds = this.DEFAULT_TIMELOCK_USDC;
        }

        const amountWei = ethers.parseUnits(amount.toString(), 6);
        const senderAddress = await this.signer.getAddress();

        // Get current block timestamp from chain (not browser time!)
        const block = await this.provider.getBlock('latest');
        const blockTimestamp = Number(block.timestamp);
        const timelock = blockTimestamp + timelockSeconds;

        // Ensure hashlock is properly formatted as bytes32
        const hashlockBytes = '0x' + hashlock.replace('0x', '').padStart(64, '0');

        // Generate swapId client-side (contract requires it as first parameter)
        // swapId = keccak256(abi.encodePacked(recipient, sender, hashlock, nonce))
        const nonce = Math.floor(Date.now() / 1000);
        const swapId = ethers.keccak256(
            ethers.solidityPacked(
                ['address', 'address', 'bytes32', 'uint256'],
                [lpAddress, senderAddress, hashlockBytes, nonce]
            )
        );

        console.log('[HTLC] Locking USDC...');
        console.log('  Sender:', senderAddress);
        console.log('  LP Address:', lpAddress);
        console.log('  Amount:', amount, 'USDC');
        console.log('  AmountWei:', amountWei.toString());
        console.log('  Hashlock:', hashlockBytes.slice(0, 18) + '...');
        console.log('  SwapId:', swapId.slice(0, 18) + '...');
        console.log('  Nonce:', nonce);
        console.log('  Block timestamp:', blockTimestamp);
        console.log('  Timelock delta:', timelockSeconds, 'seconds');
        console.log('  Timelock (unix):', timelock);
        console.log('  Timelock (date):', new Date(timelock * 1000).toISOString());

        // Call lock with swapId as FIRST parameter (contract requirement)
        const gasSettings = await this.getGasSettings();
        const tx = await this.htlcContract.lock(
            swapId,
            lpAddress,
            this.USDC_ADDRESS,
            amountWei,
            hashlockBytes,
            timelock,
            gasSettings
        );

        console.log('[HTLC] TX sent:', tx.hash);
        const receipt = await tx.wait();

        console.log('[HTLC] Locked! SwapId:', swapId);

        return {
            swapId: swapId,
            txHash: receipt.hash,
            receipt: receipt,
            hashlock: hashlockBytes,
            timelock: timelock,
            amount: amount
        };
    },

    /**
     * Claim HTLC with preimage (for LP to claim USDC)
     *
     * @param {string} swapId - The swap ID
     * @param {string} preimage - The secret S (hex)
     * @returns {object} { txHash, receipt }
     */
    async claim(swapId, preimage) {
        // Ensure preimage is properly formatted as bytes32
        const preimageBytes = '0x' + preimage.replace('0x', '').padStart(64, '0');

        console.log('[HTLC] Claiming with preimage...');
        const tx = await this.htlcContract.claim(swapId, preimageBytes);
        const receipt = await tx.wait();

        console.log('[HTLC] Claimed:', receipt.hash);
        return {
            txHash: receipt.hash,
            receipt: receipt
        };
    },

    /**
     * Refund HTLC after timelock expires
     *
     * @param {string} swapId - The swap ID
     * @returns {object} { txHash, receipt }
     */
    async refund(swapId) {
        console.log('[HTLC] Refunding...');
        const tx = await this.htlcContract.refund(swapId);
        const receipt = await tx.wait();

        console.log('[HTLC] Refunded:', receipt.hash);
        return {
            txHash: receipt.hash,
            receipt: receipt
        };
    },

    /**
     * Get HTLC swap state
     *
     * @param {string} swapId - The swap ID
     * @returns {object} Swap state
     */
    async getSwap(swapId) {
        const result = await this.htlcContract.swaps(swapId);

        const state = {
            sender: result[0],
            recipient: result[1],
            token: result[2],
            amount: ethers.formatUnits(result[3], 6),
            amountRaw: result[3],
            hashlock: result[4],
            timelock: Number(result[5]),
            withdrawn: result[6],
            refunded: result[7]
        };

        // Determine status
        if (state.withdrawn) {
            state.status = 'CLAIMED';
        } else if (state.refunded) {
            state.status = 'REFUNDED';
        } else if (state.timelock < Math.floor(Date.now() / 1000)) {
            state.status = 'EXPIRED';
        } else if (state.amount === '0.0') {
            state.status = 'NOT_FOUND';
        } else {
            state.status = 'LOCKED';
        }

        // Calculate time remaining
        const now = Math.floor(Date.now() / 1000);
        state.timeRemaining = Math.max(0, state.timelock - now);
        state.timeRemainingFormatted = this.formatTimeRemaining(state.timeRemaining);

        return state;
    },

    /**
     * Calculate swap ID before locking (for verification)
     */
    async calculateSwapId(sender, recipient, token, amount, hashlock, timelock) {
        const amountWei = ethers.parseUnits(amount.toString(), 6);
        const hashlockBytes = '0x' + hashlock.replace('0x', '').padStart(64, '0');

        return await this.htlcContract.getSwapId(
            sender,
            recipient,
            token,
            amountWei,
            hashlockBytes,
            timelock
        );
    },

    /**
     * Format time remaining as human-readable string
     */
    formatTimeRemaining(seconds) {
        if (seconds <= 0) return 'Expired';

        const hours = Math.floor(seconds / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);

        if (hours > 0) {
            return `${hours}h ${minutes}m`;
        }
        return `${minutes}m`;
    },

    /**
     * Listen for Locked events (for LP watcher)
     */
    onLocked(callback) {
        this.htlcContract.on('Locked', (swapId, sender, recipient, token, amount, hashlock, timelock, event) => {
            callback({
                swapId,
                sender,
                recipient,
                token,
                amount: ethers.formatUnits(amount, 6),
                hashlock,
                timelock: Number(timelock),
                txHash: event.transactionHash
            });
        });
    },

    /**
     * Listen for Claimed events
     */
    onClaimed(callback) {
        this.htlcContract.on('Claimed', (swapId, preimage, event) => {
            callback({
                swapId,
                preimage,
                txHash: event.transactionHash
            });
        });
    },

    /**
     * Get explorer URL for transaction
     */
    getExplorerTxUrl(txHash) {
        const explorer = NETWORKS[this.currentNetwork].explorer;
        return `${explorer}/tx/${txHash}`;
    },

    /**
     * Legacy alias
     */
    getPolygonscanUrl(txHash) {
        return this.getExplorerTxUrl(txHash);
    },

    /**
     * Get explorer URL for HTLC contract
     */
    getContractUrl() {
        const explorer = NETWORKS[this.currentNetwork].explorer;
        return `${explorer}/address/${this.HTLC_ADDRESS}`;
    },

    /**
     * Get current network info
     */
    getNetworkInfo() {
        return NETWORKS[this.currentNetwork];
    }
};

// Export for use in other modules
window.HTLC = HTLC;
window.NETWORKS = NETWORKS;
