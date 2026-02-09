<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>KPIV DEX - Atomic Swap Exchange</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>💱</text></svg>">
    <script src="https://cdn.jsdelivr.net/npm/ethers@6.9.0/dist/ethers.umd.min.js"></script>
    <link rel="stylesheet" href="css/style.css">
</head>
<body>
    <!-- Header -->
    <header>
        <div class="header-content">
            <div class="logo">
                <span class="logo-icon">💱</span>
                <span class="logo-text">KPIV <span class="highlight">DEX</span></span>
            </div>
            <nav class="nav-tabs">
                <a href="#" class="nav-tab active" data-page="trade">Trade</a>
                <a href="#" class="nav-tab" data-page="portfolio">Portfolio</a>
            </nav>
            <div class="header-right">
                <select id="network-select" class="network-select" onchange="switchNetwork(this.value)">
                    <option value="polygon" selected>🟣 Polygon</option>
                    <option value="worldchain">🌐 World Chain</option>
                    <option value="base">🔵 Base</option>
                </select>
                <div id="network-badge" class="network-badge">
                    <span class="dot"></span>
                    <span id="network-name">Polygon</span>
                </div>
                <button id="connect-btn" class="connect-btn" onclick="connectWallet()">
                    <span class="metamask-icon">🦊</span>
                    <span id="wallet-status">Connect</span>
                </button>
            </div>
        </div>
    </header>

    <!-- Main Content -->
    <main class="container">
        <!-- Trade Page -->
        <div id="trade-page" class="page active">
            <!-- Pair Selector -->
            <div class="pair-selector">
                <button class="pair-btn active" data-pair="KPIV/USDC">KPIV/USDC</button>
                <button class="pair-btn disabled" data-pair="KPIV/BTC" disabled>KPIV/BTC (Soon)</button>
            </div>

            <div class="trade-layout">
                <!-- Orderbook -->
                <div class="orderbook-panel">
                    <div class="panel-header">
                        <h2>Order Book</h2>
                        <div class="orderbook-stats">
                            <span class="stat">
                                <span class="label">Best Ask:</span>
                                <span id="best-ask" class="value ask">-</span>
                            </span>
                            <span class="stat">
                                <span class="label">Best Bid:</span>
                                <span id="best-bid" class="value bid">-</span>
                            </span>
                            <span class="stat">
                                <span class="label">Spread:</span>
                                <span id="spread" class="value">-</span>
                            </span>
                        </div>
                    </div>

                    <div class="orderbook-container">
                        <!-- Asks (Sells) - Red -->
                        <div class="orderbook-section asks">
                            <div class="orderbook-header">
                                <span>Price (USDC)</span>
                                <span>Size (KPIV)</span>
                                <span>Total</span>
                            </div>
                            <div id="asks-list" class="orderbook-rows">
                                <!-- Populated by JS -->
                            </div>
                        </div>

                        <!-- Spread Indicator -->
                        <div id="spread-bar" class="spread-bar">
                            <span id="spread-display">0.00%</span>
                        </div>

                        <!-- Bids (Buys) - Green -->
                        <div class="orderbook-section bids">
                            <div class="orderbook-header">
                                <span>Price (USDC)</span>
                                <span>Size (KPIV)</span>
                                <span>Total</span>
                            </div>
                            <div id="bids-list" class="orderbook-rows">
                                <!-- Populated by JS -->
                            </div>
                        </div>
                    </div>

                    <div class="orderbook-footer">
                        <button onclick="refreshOrderbook()" class="refresh-btn">↻ Refresh</button>
                        <span id="last-update" class="last-update">-</span>
                    </div>
                </div>

                <!-- Swap Panel -->
                <div class="swap-panel">
                    <div class="panel-header">
                        <h2>Buy KPIV</h2>
                        <div class="swap-mode">
                            <span class="mode-badge">Atomic Swap</span>
                        </div>
                    </div>

                    <!-- Wallet Connection Required -->
                    <div id="connect-prompt" class="connect-prompt">
                        <div class="prompt-icon">🦊</div>
                        <h3>Connect MetaMask</h3>
                        <p>Connect your wallet to start trading</p>
                        <button onclick="connectWallet()" class="btn-primary">Connect Wallet</button>
                    </div>

                    <!-- Swap Form (hidden until connected) -->
                    <div id="swap-form" class="swap-form" style="display: none;">
                        <!-- Wallet Info -->
                        <div class="wallet-info">
                            <div class="wallet-address" id="display-address">0x...</div>
                            <div class="wallet-balance">
                                <span id="usdc-balance">0.00</span> USDC
                            </div>
                        </div>

                        <!-- Amount Input -->
                        <div class="input-group">
                            <label>Amount (KPIV)</label>
                            <div class="input-wrapper">
                                <input type="number" id="amount-input" placeholder="0" min="1" step="1" oninput="updatePreview()">
                                <div class="input-buttons">
                                    <button onclick="setAmount(10)">10</button>
                                    <button onclick="setAmount(50)">50</button>
                                    <button onclick="setAmount(100)">100</button>
                                </div>
                            </div>
                        </div>

                        <!-- BATHRON Address -->
                        <div class="input-group">
                            <label>Your BATHRON Address (receive KPIV here)</label>
                            <input type="text" id="bathron-address" placeholder="y..." oninput="saveBathronAddress()">
                            <small class="hint">Testnet address starting with x or y</small>
                        </div>

                        <!-- Preview -->
                        <div class="preview-box">
                            <div class="preview-row">
                                <span>You Pay</span>
                                <span id="preview-pay" class="highlight">0.00 USDC</span>
                            </div>
                            <div class="preview-row">
                                <span>You Receive</span>
                                <span id="preview-receive" class="success">0 KPIV</span>
                            </div>
                            <div class="preview-row">
                                <span>Price</span>
                                <span id="preview-price">-</span>
                            </div>
                            <div class="preview-row">
                                <span>LP Address</span>
                                <span id="preview-lp" class="small">-</span>
                            </div>
                        </div>

                        <!-- Action Button -->
                        <button id="swap-btn" class="btn-swap" onclick="initiateSwap()" disabled>
                            <span class="btn-icon">🔒</span>
                            <span class="btn-text">Lock USDC</span>
                        </button>

                        <!-- Status -->
                        <div id="swap-status" class="swap-status" style="display: none;">
                            <div class="status-icon"></div>
                            <div class="status-text"></div>
                        </div>
                    </div>

                    <!-- How It Works -->
                    <div class="how-it-works">
                        <h4>How 2-HTLC Atomic Swaps Work</h4>
                        <ol>
                            <li><strong>Generate Secret:</strong> A random secret (S) is created locally, hashlock H=SHA256(S)</li>
                            <li><strong>Lock USDC:</strong> Your USDC is locked in an HTLC on Polygon (4h timelock)</li>
                            <li><strong>LP Locks KPIV:</strong> LP detects your lock and creates a KPIV HTLC with same H (2h timelock)</li>
                            <li><strong>Claim KPIV:</strong> You claim KPIV by revealing S on the BATHRON chain</li>
                            <li><strong>LP Claims USDC:</strong> LP extracts S from your claim TX and claims your USDC</li>
                        </ol>
                        <p class="security-note">🔐 Trustless: Your secret S controls both HTLCs. Neither party can grief the other.</p>
                    </div>
                </div>
            </div>
        </div>

        <!-- Portfolio Page -->
        <div id="portfolio-page" class="page">
            <div class="portfolio-header">
                <h2>My Swaps</h2>
                <button onclick="loadSwaps()" class="refresh-btn">↻ Refresh</button>
            </div>

            <div id="swaps-list" class="swaps-list">
                <div class="empty-state">
                    <div class="empty-icon">📭</div>
                    <p>No swaps yet</p>
                    <p class="hint">Start trading to see your swap history</p>
                </div>
            </div>
        </div>
    </main>

    <!-- Footer -->
    <footer>
        <div class="footer-content">
            <span>BATHRON DEX Demo | Powered by BATHRON</span>
            <span class="separator">|</span>
            <a href="http://57.131.33.151:3001/" target="_blank">Block Explorer ↗</a>
        </div>
    </footer>

    <!-- Scripts (cache bust) -->
    <script src="js/vault.js?v=9"></script>
    <script src="js/htlc.js?v=9"></script>
    <script src="js/app.js?v=9"></script>
</body>
</html>
