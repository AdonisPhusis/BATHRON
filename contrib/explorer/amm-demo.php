<?php
/**
 * BATHRON AMM Demo - Educational Simulator
 * Shows how a Pivot Pool AMM would work
 *
 * NOTE: This is a SIMULATION only. No real trades.
 * For educational purposes to understand AMM mechanics.
 */

// Simulated Pivot Pool State
class PivotPoolDemo {
    // Pool state (simulated, persisted in session)
    private $khu_total;
    private $reserves;
    private $swap_history;

    const FEE_BPS = 30;  // 0.30%

    public function __construct() {
        // Initialize from session or defaults
        session_start();

        if (!isset($_SESSION['amm_pool'])) {
            $this->initializePool();
        } else {
            $this->khu_total = $_SESSION['amm_pool']['khu_total'];
            $this->reserves = $_SESSION['amm_pool']['reserves'];
            $this->swap_history = $_SESSION['amm_pool']['history'] ?? [];
        }
    }

    private function initializePool() {
        // Default pool: 100k KHU, seeded with test assets
        $this->khu_total = 100000;
        $this->reserves = [
            'TBTC' => ['reserve' => 2.5, 'weight' => 5000, 'decimals' => 8],    // 50%
            'TUSDC' => ['reserve' => 50000, 'weight' => 5000, 'decimals' => 6], // 50%
        ];
        $this->swap_history = [];
        $this->saveState();
    }

    public function reset() {
        $this->initializePool();
    }

    private function saveState() {
        $_SESSION['amm_pool'] = [
            'khu_total' => $this->khu_total,
            'reserves' => $this->reserves,
            'history' => $this->swap_history
        ];
    }

    public function getVirtualKHU($asset) {
        if (!isset($this->reserves[$asset])) return 0;
        return ($this->khu_total * $this->reserves[$asset]['weight']) / 10000;
    }

    public function getPrice($asset) {
        if (!isset($this->reserves[$asset])) return 0;
        $res = $this->reserves[$asset];
        if ($res['reserve'] == 0) return 0;
        $khu_virtual = $this->getVirtualKHU($asset);
        return $khu_virtual / $res['reserve'];
    }

    public function quote($asset_in, $amount_in, $asset_out) {
        // X → KHU
        if ($asset_out == 'KHU' && isset($this->reserves[$asset_in])) {
            $res = $this->reserves[$asset_in];
            $khu_virtual = $this->getVirtualKHU($asset_in);
            $k = $res['reserve'] * $khu_virtual;
            $new_reserve = $res['reserve'] + $amount_in;
            $new_khu = $k / $new_reserve;
            $khu_out = $khu_virtual - $new_khu;

            $fee = ($khu_out * self::FEE_BPS) / 10000;
            $khu_out_after_fee = $khu_out - $fee;

            $price_before = $this->getPrice($asset_in);
            $price_after = $new_khu / $new_reserve;
            $slippage = abs(1 - ($khu_out_after_fee / ($amount_in * $price_before))) * 100;

            return [
                'amount_out' => $khu_out_after_fee,
                'fee' => $fee,
                'price_before' => $price_before,
                'price_after' => $price_after,
                'slippage' => $slippage,
                'route' => [$asset_in, 'KHU']
            ];
        }

        // KHU → X
        if ($asset_in == 'KHU' && isset($this->reserves[$asset_out])) {
            $res = $this->reserves[$asset_out];
            $khu_virtual = $this->getVirtualKHU($asset_out);
            $k = $res['reserve'] * $khu_virtual;
            $new_khu = $khu_virtual + $amount_in;
            $new_reserve = $k / $new_khu;
            $asset_out_amount = $res['reserve'] - $new_reserve;

            $fee = ($asset_out_amount * self::FEE_BPS) / 10000;
            $out_after_fee = $asset_out_amount - $fee;

            return [
                'amount_out' => $out_after_fee,
                'fee' => $fee,
                'price_before' => 1 / $this->getPrice($asset_out),
                'slippage' => 0,
                'route' => ['KHU', $asset_out]
            ];
        }

        // Cross-swap X → Y
        if (isset($this->reserves[$asset_in]) && isset($this->reserves[$asset_out])) {
            $step1 = $this->quote($asset_in, $amount_in, 'KHU');
            $step2 = $this->quote('KHU', $step1['amount_out'], $asset_out);

            return [
                'amount_out' => $step2['amount_out'],
                'fee' => $step1['fee'] + $step2['fee'],
                'intermediate_khu' => $step1['amount_out'],
                'route' => [$asset_in, 'KHU', $asset_out],
                'slippage' => $step1['slippage']
            ];
        }

        return null;
    }

    public function executeSwap($asset_in, $amount_in, $asset_out) {
        $quote = $this->quote($asset_in, $amount_in, $asset_out);
        if (!$quote) return null;

        // Update reserves
        if ($asset_out == 'KHU' && isset($this->reserves[$asset_in])) {
            $this->reserves[$asset_in]['reserve'] += $amount_in;
        } elseif ($asset_in == 'KHU' && isset($this->reserves[$asset_out])) {
            $this->reserves[$asset_out]['reserve'] -= $quote['amount_out'];
        } elseif (isset($this->reserves[$asset_in]) && isset($this->reserves[$asset_out])) {
            // Cross-swap
            $this->reserves[$asset_in]['reserve'] += $amount_in;
            $this->reserves[$asset_out]['reserve'] -= $quote['amount_out'];
        }

        // Record swap
        $this->swap_history[] = [
            'time' => time(),
            'in' => "$amount_in $asset_in",
            'out' => number_format($quote['amount_out'], 4) . " $asset_out",
            'fee' => $quote['fee']
        ];

        // Keep last 10 swaps
        if (count($this->swap_history) > 10) {
            array_shift($this->swap_history);
        }

        $this->saveState();
        return $quote;
    }

    public function addLiquidity($amount_khu) {
        $this->khu_total += $amount_khu;
        $this->saveState();
    }

    public function getPoolInfo() {
        $reserves_info = [];
        foreach ($this->reserves as $ticker => $res) {
            $reserves_info[$ticker] = [
                'reserve' => $res['reserve'],
                'weight' => $res['weight'] / 100 . '%',
                'virtual_khu' => $this->getVirtualKHU($ticker),
                'price' => $this->getPrice($ticker)
            ];
        }

        return [
            'khu_total' => $this->khu_total,
            'reserves' => $reserves_info,
            'history' => $this->swap_history
        ];
    }
}

// Handle AJAX requests
$pool = new PivotPoolDemo();

if (isset($_GET['action'])) {
    header('Content-Type: application/json');

    switch ($_GET['action']) {
        case 'info':
            echo json_encode($pool->getPoolInfo());
            break;

        case 'quote':
            $result = $pool->quote(
                $_GET['asset_in'] ?? 'TBTC',
                floatval($_GET['amount_in'] ?? 0),
                $_GET['asset_out'] ?? 'KHU'
            );
            echo json_encode($result);
            break;

        case 'swap':
            $result = $pool->executeSwap(
                $_GET['asset_in'] ?? 'TBTC',
                floatval($_GET['amount_in'] ?? 0),
                $_GET['asset_out'] ?? 'KHU'
            );
            echo json_encode(['success' => true, 'result' => $result, 'pool' => $pool->getPoolInfo()]);
            break;

        case 'reset':
            $pool->reset();
            echo json_encode(['success' => true, 'pool' => $pool->getPoolInfo()]);
            break;

        case 'add_liquidity':
            $pool->addLiquidity(floatval($_GET['amount'] ?? 0));
            echo json_encode(['success' => true, 'pool' => $pool->getPoolInfo()]);
            break;
    }
    exit;
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>BATHRON AMM Demo - Educational Simulator</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #eee;
            min-height: 100vh;
            padding: 20px;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 {
            text-align: center;
            margin-bottom: 10px;
            color: #8b5cf6;
        }
        .subtitle {
            text-align: center;
            color: #888;
            margin-bottom: 30px;
            font-size: 14px;
        }
        .warning {
            background: #f59e0b22;
            border: 1px solid #f59e0b;
            padding: 10px 15px;
            border-radius: 8px;
            margin-bottom: 20px;
            text-align: center;
            font-size: 13px;
        }
        .grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
        }
        @media (max-width: 800px) {
            .grid { grid-template-columns: 1fr; }
        }
        .card {
            background: #1e293b;
            border-radius: 12px;
            padding: 20px;
            border: 1px solid #334155;
        }
        .card h2 {
            color: #8b5cf6;
            margin-bottom: 15px;
            font-size: 18px;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .pool-stat {
            display: flex;
            justify-content: space-between;
            padding: 10px 0;
            border-bottom: 1px solid #334155;
        }
        .pool-stat:last-child { border-bottom: none; }
        .pool-stat .label { color: #94a3b8; }
        .pool-stat .value {
            font-weight: bold;
            color: #10b981;
        }
        .reserve-item {
            background: #0f172a;
            border-radius: 8px;
            padding: 12px;
            margin-bottom: 10px;
        }
        .reserve-header {
            display: flex;
            justify-content: space-between;
            margin-bottom: 8px;
        }
        .reserve-ticker {
            font-weight: bold;
            color: #f59e0b;
        }
        .reserve-price {
            color: #10b981;
        }
        .reserve-details {
            font-size: 12px;
            color: #64748b;
        }
        .swap-form {
            display: flex;
            flex-direction: column;
            gap: 15px;
        }
        .form-row {
            display: flex;
            gap: 10px;
            align-items: center;
        }
        input, select {
            background: #0f172a;
            border: 1px solid #334155;
            color: #eee;
            padding: 10px 12px;
            border-radius: 6px;
            font-size: 14px;
        }
        input:focus, select:focus {
            outline: none;
            border-color: #8b5cf6;
        }
        input[type="number"] { flex: 1; }
        select { min-width: 100px; }
        button {
            background: linear-gradient(135deg, #8b5cf6, #6366f1);
            color: white;
            border: none;
            padding: 12px 20px;
            border-radius: 8px;
            cursor: pointer;
            font-weight: bold;
            transition: transform 0.1s, opacity 0.2s;
        }
        button:hover { transform: translateY(-1px); }
        button:active { transform: translateY(0); }
        button.secondary {
            background: #334155;
        }
        .quote-result {
            background: #0f172a;
            border-radius: 8px;
            padding: 15px;
            margin-top: 15px;
        }
        .quote-row {
            display: flex;
            justify-content: space-between;
            padding: 5px 0;
            font-size: 13px;
        }
        .quote-row .label { color: #94a3b8; }
        .quote-row .value { color: #10b981; }
        .quote-row.warning .value { color: #f59e0b; }
        .swap-arrow {
            font-size: 24px;
            color: #8b5cf6;
            text-align: center;
        }
        .history-item {
            background: #0f172a;
            border-radius: 6px;
            padding: 8px 12px;
            margin-bottom: 8px;
            font-size: 12px;
            display: flex;
            justify-content: space-between;
        }
        .history-time { color: #64748b; }
        .formula-box {
            background: #0f172a;
            border-radius: 8px;
            padding: 15px;
            font-family: monospace;
            font-size: 13px;
            color: #94a3b8;
            margin-top: 15px;
        }
        .formula-box code {
            color: #10b981;
        }
        .chart-placeholder {
            height: 150px;
            background: #0f172a;
            border-radius: 8px;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #64748b;
            font-size: 12px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔄 BATHRON Pivot Pool AMM</h1>
        <p class="subtitle">Educational Simulator - Understand AMM Mechanics</p>

        <div class="warning">
            ⚠️ <strong>SIMULATION ONLY</strong> - No real assets are traded.
            This demonstrates how a Pivot Pool AMM would work.
        </div>

        <div class="grid">
            <!-- Pool Status -->
            <div class="card">
                <h2>📊 Pivot Pool Status</h2>
                <div class="pool-stat">
                    <span class="label">Total KHU Liquidity</span>
                    <span class="value" id="khu-total">--</span>
                </div>
                <div class="pool-stat">
                    <span class="label">Fee Rate</span>
                    <span class="value">0.30%</span>
                </div>

                <h3 style="margin: 15px 0 10px; color: #94a3b8; font-size: 14px;">Reserves (Virtual)</h3>
                <div id="reserves-list"></div>

                <div style="margin-top: 15px; display: flex; gap: 10px;">
                    <button class="secondary" onclick="addLiquidity()">+ Add 10k KHU</button>
                    <button class="secondary" onclick="resetPool()">🔄 Reset Pool</button>
                </div>
            </div>

            <!-- Swap Interface -->
            <div class="card">
                <h2>💱 Swap Simulator</h2>
                <div class="swap-form">
                    <div class="form-row">
                        <input type="number" id="amount-in" placeholder="Amount" step="0.0001" value="0.1" oninput="updateQuote()">
                        <select id="asset-in" onchange="updateQuote()">
                            <option value="TBTC">TBTC</option>
                            <option value="TUSDC">TUSDC</option>
                            <option value="KHU">KHU</option>
                        </select>
                    </div>

                    <div class="swap-arrow">↓</div>

                    <div class="form-row">
                        <input type="text" id="amount-out" readonly placeholder="You receive">
                        <select id="asset-out" onchange="updateQuote()">
                            <option value="KHU">KHU</option>
                            <option value="TBTC">TBTC</option>
                            <option value="TUSDC">TUSDC</option>
                        </select>
                    </div>

                    <div class="quote-result" id="quote-result" style="display: none;">
                        <div class="quote-row">
                            <span class="label">Route</span>
                            <span class="value" id="quote-route">--</span>
                        </div>
                        <div class="quote-row">
                            <span class="label">Price</span>
                            <span class="value" id="quote-price">--</span>
                        </div>
                        <div class="quote-row">
                            <span class="label">Fee (0.30%)</span>
                            <span class="value" id="quote-fee">--</span>
                        </div>
                        <div class="quote-row warning">
                            <span class="label">Slippage</span>
                            <span class="value" id="quote-slippage">--</span>
                        </div>
                    </div>

                    <button onclick="executeSwap()">🔄 Execute Swap (Simulated)</button>
                </div>
            </div>

            <!-- Formula Explanation -->
            <div class="card">
                <h2>📐 AMM Formula</h2>
                <div class="formula-box">
                    <strong>Constant Product:</strong><br>
                    <code>x × y = k</code><br><br>

                    <strong>Swap Output:</strong><br>
                    <code>Δy = y × Δx / (x + Δx)</code><br><br>

                    <strong>Price Impact:</strong><br>
                    <code>slippage = Δx / (x + Δx)</code><br><br>

                    <strong>Pivot Pool:</strong><br>
                    <code>KHU_virtual = KHU_total × weight</code>
                </div>

                <div class="formula-box" style="margin-top: 10px;">
                    <strong>Impermanent Loss:</strong><br>
                    <code>IL = 2√(p_ratio) / (1 + p_ratio) - 1</code><br><br>
                    <span style="font-size: 11px;">
                    Price 2x → IL = -5.72%<br>
                    Price 3x → IL = -13.4%
                    </span>
                </div>
            </div>

            <!-- Swap History -->
            <div class="card">
                <h2>📜 Recent Swaps</h2>
                <div id="swap-history">
                    <p style="color: #64748b; font-size: 13px;">No swaps yet. Try the simulator!</p>
                </div>
            </div>
        </div>

        <div style="text-align: center; margin-top: 30px; color: #64748b; font-size: 12px;">
            <p>BATHRON AMM Demo v1.0 - Part of <a href="/" style="color: #8b5cf6;">BATHRON Explorer</a></p>
            <p>Based on Blueprint 20-AMM-PIVOT-POOL.md</p>
        </div>
    </div>

    <script>
        let currentQuote = null;

        async function fetchAPI(action, params = {}) {
            const url = new URL(window.location.href);
            url.searchParams.set('action', action);
            for (const [key, value] of Object.entries(params)) {
                url.searchParams.set(key, value);
            }
            const response = await fetch(url);
            return response.json();
        }

        async function refreshPool() {
            const info = await fetchAPI('info');

            document.getElementById('khu-total').textContent =
                info.khu_total.toLocaleString() + ' KHU';

            const reservesList = document.getElementById('reserves-list');
            reservesList.innerHTML = '';

            for (const [ticker, res] of Object.entries(info.reserves)) {
                const div = document.createElement('div');
                div.className = 'reserve-item';
                div.innerHTML = `
                    <div class="reserve-header">
                        <span class="reserve-ticker">${ticker}</span>
                        <span class="reserve-price">${res.price.toLocaleString(undefined, {maximumFractionDigits: 2})} KHU/${ticker}</span>
                    </div>
                    <div class="reserve-details">
                        Reserve: ${res.reserve.toLocaleString(undefined, {maximumFractionDigits: 4})} |
                        Weight: ${res.weight} |
                        Virtual KHU: ${res.virtual_khu.toLocaleString()}
                    </div>
                `;
                reservesList.appendChild(div);
            }

            // Update history
            const historyDiv = document.getElementById('swap-history');
            if (info.history && info.history.length > 0) {
                historyDiv.innerHTML = info.history.reverse().map(h => `
                    <div class="history-item">
                        <span>${h.in} → ${h.out}</span>
                        <span class="history-time">fee: ${h.fee.toFixed(4)}</span>
                    </div>
                `).join('');
            }
        }

        async function updateQuote() {
            const assetIn = document.getElementById('asset-in').value;
            const assetOut = document.getElementById('asset-out').value;
            const amountIn = parseFloat(document.getElementById('amount-in').value) || 0;

            if (assetIn === assetOut || amountIn <= 0) {
                document.getElementById('quote-result').style.display = 'none';
                document.getElementById('amount-out').value = '';
                return;
            }

            const quote = await fetchAPI('quote', {
                asset_in: assetIn,
                amount_in: amountIn,
                asset_out: assetOut
            });

            if (quote && quote.amount_out) {
                currentQuote = quote;
                document.getElementById('amount-out').value = quote.amount_out.toFixed(6);
                document.getElementById('quote-route').textContent = quote.route.join(' → ');
                document.getElementById('quote-price').textContent =
                    (quote.amount_out / amountIn).toFixed(4) + ' ' + assetOut + '/' + assetIn;
                document.getElementById('quote-fee').textContent = quote.fee.toFixed(6) + ' ' + assetOut;
                document.getElementById('quote-slippage').textContent = (quote.slippage || 0).toFixed(2) + '%';
                document.getElementById('quote-result').style.display = 'block';
            }
        }

        async function executeSwap() {
            const assetIn = document.getElementById('asset-in').value;
            const assetOut = document.getElementById('asset-out').value;
            const amountIn = parseFloat(document.getElementById('amount-in').value) || 0;

            if (assetIn === assetOut || amountIn <= 0) {
                alert('Invalid swap parameters');
                return;
            }

            const result = await fetchAPI('swap', {
                asset_in: assetIn,
                amount_in: amountIn,
                asset_out: assetOut
            });

            if (result.success) {
                await refreshPool();
                await updateQuote();
            }
        }

        async function addLiquidity() {
            await fetchAPI('add_liquidity', { amount: 10000 });
            await refreshPool();
            await updateQuote();
        }

        async function resetPool() {
            if (confirm('Reset pool to initial state?')) {
                await fetchAPI('reset');
                await refreshPool();
                await updateQuote();
            }
        }

        // Initialize
        refreshPool();
        updateQuote();
    </script>
</body>
</html>
