<?php
/*
    BATHRON Explorer - Custom Block Explorer for BATHRON
    Based on RPC Ace by Robin Leffmann

    Licensed under CC BY-NC-SA 4.0
*/

// ============ CONFIGURATION ============
const RPC_HOST = '127.0.0.1';
const RPC_PORT = 51475;  // Testnet RPC port (default for testnet)
const RPC_USER = 'bathron';
const RPC_PASS = 'bathron';

const COIN_NAME = 'BATHRON 2.0';
const COIN_TICKER = 'M0';  // Base money (Genesis Clean terminology)
const NETWORK = 'Testnet';
const BLOCKS_PER_LIST = 15;
const REFRESH_TIME = 30;
const MNS_PER_PAGE = 25;

require_once('easybitcoin.php');

// ============ TX TYPE DEFINITIONS (BP30) ============
// Transaction types from primitives/transaction.h
const TX_TYPES = [
    0 => ['name' => 'Standard', 'class' => 'badge-standard', 'desc' => 'Standard transaction'],
    1 => ['name' => 'ProReg', 'class' => 'badge-proreg', 'desc' => 'Masternode registration'],
    2 => ['name' => 'ProUpServ', 'class' => 'badge-proupserv', 'desc' => 'MN service update'],
    3 => ['name' => 'ProUpReg', 'class' => 'badge-proupreg', 'desc' => 'MN registration update'],
    4 => ['name' => 'ProUpRev', 'class' => 'badge-prouprev', 'desc' => 'MN revocation'],
    // BP30 Lock-Based Settlement (M0/M1/M2 model)
    20 => ['name' => 'TX_LOCK', 'class' => 'badge-lock', 'desc' => 'M0 → Vault + M1 Receipt'],
    21 => ['name' => 'TX_UNLOCK', 'class' => 'badge-unlock', 'desc' => 'Vault + M1 → M0'],
    22 => ['name' => 'TX_TRANSFER', 'class' => 'badge-transfer', 'desc' => 'M1 Receipt transfer'],
    23 => ['name' => 'TX_SAVE', 'class' => 'badge-save', 'desc' => 'M1 → M2 (enter savings)'],
    24 => ['name' => 'TX_UNSAVE', 'class' => 'badge-unsave', 'desc' => 'M2 → M1 + yield'],
];

/**
 * Get TX type info from type code
 */
function getTxTypeInfo($type) {
    return TX_TYPES[$type] ?? ['name' => 'Unknown', 'class' => 'badge-unknown', 'desc' => 'Unknown type'];
}

/**
 * Get asset class from asset name (from RPC)
 * RPC now returns asset type directly, this just maps to CSS class
 */
function getAssetClass($asset) {
    switch ($asset) {
        case 'M1': return 'asset-m1';
        case 'Vault': return 'asset-vault';
        case 'Pool': return 'asset-vault';
        default: return 'asset-m0';
    }
}

/**
 * Get TX type badge HTML
 */
function getTxTypeBadge($type, $isCoinbase = false) {
    if ($isCoinbase) {
        return '<span class="badge badge-coinbase" title="Block reward">Coinbase</span>';
    }
    $info = getTxTypeInfo($type);
    return '<span class="badge ' . $info['class'] . '" title="' . htmlspecialchars($info['desc']) . '">' . $info['name'] . '</span>';
}

// ============ RPC CLASS ============
class BATHRONExplorer
{
    private static $rpc = null;

    private static function getRpc()
    {
        if (self::$rpc === null) {
            self::$rpc = new Bitcoin(RPC_USER, RPC_PASS, RPC_HOST, RPC_PORT);
        }
        return self::$rpc;
    }

    public static function getNetworkInfo()
    {
        $rpc = self::getRpc();

        // ========================================
        // Basic blockchain info (always needed)
        // ========================================
        $info = $rpc->getblockchaininfo();
        $netinfo = $rpc->getnetworkinfo();
        $mininginfo = $rpc->getmininginfo();
        $mempool = $rpc->getmempoolinfo();
        $supply = $rpc->gettxoutsetinfo();

        // ========================================
        // Settlement/MN data from getexplorerdata
        // ONE RPC for all BP30 state + MN counts
        // ========================================
        $explorerData = null;
        $stateAvailable = false;
        try {
            $explorerData = @$rpc->getexplorerdata();
            $stateAvailable = is_array($explorerData);
        } catch (Exception $e) {
            // getexplorerdata not available
        }

        // Parse explorer data (single source of truth)
        // ALL values come from RPC - NO PHP calculations on consensus data
        if ($stateAvailable) {
            // Supply from getexplorerdata (consensus values)
            $m0Total = floatval($explorerData['supply']['m0_total'] ?? '0');
            $m0Free = floatval($explorerData['supply']['m0_free'] ?? '0');
            $m0Circulating = floatval($explorerData['supply']['m0_circulating'] ?? '0');
            $m0VaultedActive = floatval($explorerData['supply']['m0_vaulted_active'] ?? '0');
            $m0Savingspool = floatval($explorerData['supply']['m0_savingspool'] ?? '0');
            $m1Supply = floatval($explorerData['supply']['m1_supply'] ?? '0');
            $m2Locked = floatval($explorerData['supply']['m2_supply'] ?? '0');
            $mnCollateral = floatval($explorerData['supply']['mn_collateral'] ?? '0');

            // Shield breakdown (A13 pool isolation)
            $m0ShieldPure = floatval($explorerData['shield']['m0_pure'] ?? '0');  // True ZtoZ

            // Invariants (pre-calculated by RPC)
            // A5: Monetary Conservation (may not exist in older binaries)
            $a5Ok = $explorerData['invariants']['a5_ok'] ?? true;  // Default true if not present
            $a5M0Total = floatval($explorerData['invariants']['a5_m0_total'] ?? $explorerData['supply']['m0_total'] ?? '0');
            $a5Coinbase = floatval($explorerData['invariants']['a5_coinbase'] ?? '0');
            $a5Treasury = floatval($explorerData['invariants']['a5_treasury'] ?? '0');
            $a5Yield = floatval($explorerData['invariants']['a5_yield'] ?? '0');
            $a5Delta = floatval($explorerData['invariants']['a5_delta'] ?? '0');
            $a5Available = isset($explorerData['invariants']['a5_ok']);  // Check if A5 fields exist
            // A6: Settlement Backing
            $a6Left = floatval($explorerData['invariants']['a6_left'] ?? '0');
            $a6Right = floatval($explorerData['invariants']['a6_right'] ?? '0');
            $a6Ok = $explorerData['invariants']['a6_ok'] ?? true;
            $invariantsOk = $a6Ok;  // Only check A6 for now (A5 always OK if block accepted)

            // Network (MN/operators)
            $mnTotal = $explorerData['network']['masternodes'] ?? 0;
            $mnActive = $explorerData['network']['mn_enabled'] ?? 0;
            $operatorCount = $explorerData['network']['operators'] ?? 0;

            // Finality
            $finalityLag = $explorerData['finality']['lag'] ?? 0;
            $finalityStatus = $explorerData['finality']['status'] ?? 'unknown';
            $lastFinalized = $explorerData['finality']['height'] ?? 0;

            // DOMC R%
            $rPercent = floatval($explorerData['domc']['R_annual_pct'] ?? 0);
        } else {
            // Fallback defaults (RPC unavailable)
            $m0Total = 0;
            $m0Free = 0;
            $m0Circulating = 0;
            $m0VaultedActive = 0;
            $m0Savingspool = 0;
            $m1Supply = 0;
            $m2Locked = 0;
            $mnCollateral = 0;
            $m0ShieldPure = 0;
            $rPercent = 0;
            // A5 fallbacks
            $a5Ok = true;
            $a5M0Total = 0;
            $a5Coinbase = 0;
            $a5Treasury = 0;
            $a5Yield = 0;
            $a5Delta = 0;
            $a5Available = false;
            // A6 fallbacks
            $a6Left = 0;
            $a6Right = 0;
            $a6Ok = true;
            $invariantsOk = true;
            $mnTotal = 0;
            $mnActive = 0;
            $operatorCount = 0;
            $finalityLag = 0;
            $finalityStatus = 'unknown';
            $lastFinalized = 0;
        }

        // ========================================
        // ALL VALUES FROM RPC - NO PHP CALCULATIONS
        // ========================================
        // M0_SHIELD (ZtoZ) from getexplorerdata shield.m0_pure
        $m0Shield = $m0ShieldPure;

        // Treasury (not in settlement state yet)
        $treasury = 0;
        $yieldVault = 0;

        return [
            'blocks' => $info['blocks'] ?? 0,
            'difficulty' => $info['difficulty'] ?? 0,
            'chain' => $info['chain'] ?? 'unknown',
            'connections' => $netinfo['connections'] ?? 0,
            'version' => $netinfo['subversion'] ?? '',
            'protocolversion' => $netinfo['protocolversion'] ?? 0,
            'hashrate' => ($mininginfo['networkhashps'] ?? 0) / 1000000,
            'masternodes_active' => $mnActive,
            'masternodes_total' => $mnTotal,
            'operators_count' => $operatorCount,
            'mempool_size' => $mempool['size'] ?? 0,
            'mempool_bytes' => $mempool['bytes'] ?? 0,
            'r_percent' => $rPercent,
            // ========== M0 SUPPLY (all from RPC) ==========
            'm0_total' => $m0Total,
            'm0_free' => $m0Free,
            'm0_circulating' => $m0Circulating,
            'm0_mn_collateral' => $mnCollateral,
            'm0_shield' => $m0Shield,
            // ========== SETTLEMENT LAYER (BP30) ==========
            'm0_vaulted_active' => $m0VaultedActive,
            'm0_savingspool' => $m0Savingspool,
            'm1_supply' => $m1Supply,
            'm2_locked' => $m2Locked,
            // ========== YIELD & TREASURY ==========
            'yield_vault' => $yieldVault,
            'treasury' => $treasury,
            // ========== INVARIANTS A5/A6 ==========
            'invariants_ok' => $invariantsOk,
            'state_available' => $stateAvailable,
            'schema_version' => 'explorer.v1',
            // A5: Monetary Conservation
            'a5_ok' => $a5Ok,
            'a5_available' => $a5Available,
            'a5_m0_total' => $a5M0Total,
            'a5_coinbase' => $a5Coinbase,
            'a5_treasury' => $a5Treasury,
            'a5_yield' => $a5Yield,
            'a5_delta' => $a5Delta,
            // A6: Settlement Backing
            'a6_ok' => $a6Ok,
            'a6_left' => $a6Left,
            'a6_right' => $a6Right,
            // ========== FINALITY ==========
            'finality_lag' => $finalityLag,
            'finality_status' => $finalityStatus,
            'last_finalized' => $lastFinalized,
            'last_finality_delay_ms' => 0,
            'avg_finality_delay_ms' => 0,
        ];
    }

    /**
     * Get staking info for dashboard
     */
    public static function getStakingInfo()
    {
        $rpc = self::getRpc();
        try {
            $staking = $rpc->getstakinginfo();
            if (is_array($staking)) {
                return $staking;
            }
        } catch (Exception $e) {
            // RPC not available
        }
        return [
            'total_staked' => 0,
            'daily_yield_per_100k' => 0,
            'min_lock_blocks' => 4320,
        ];
    }

    /**
     * Get DAO info for grants and treasury
     */
    public static function getDAOInfo()
    {
        $rpc = self::getRpc();
        try {
            $dao = $rpc->getdaoinfo();
            if (is_array($dao)) {
                return $dao;
            }
        } catch (Exception $e) {
            // RPC not available
        }
        return [
            'treasury_balance' => 0,
            'next_payout_block' => 0,
            'total_granted' => 0,
            'total_burned' => 0,
        ];
    }

    /**
     * Get list of DAO grant proposals
     */
    public static function getGrantList()
    {
        $rpc = self::getRpc();
        try {
            $grants = $rpc->daogrant_list();
            if (is_array($grants)) {
                return $grants;
            }
        } catch (Exception $e) {
            // RPC not available
        }
        return [];
    }

    /**
     * Get details of a specific grant
     */
    public static function getGrantDetails($hash)
    {
        $rpc = self::getRpc();
        try {
            $grant = $rpc->daogrant_get($hash);
            if (is_array($grant)) {
                return $grant;
            }
        } catch (Exception $e) {
            // RPC not available
        }
        return null;
    }

    /**
     * Get DOMC (Yield Rate) info from getdomcstatus RPC
     */
    public static function getDOMCInfo()
    {
        $rpc = self::getRpc();

        // Use getdomcstatus - the authoritative source for DOMC data
        $domc = null;
        try {
            $domc = $rpc->getdomcstatus();
        } catch (Exception $e) {}

        if (!is_array($domc)) {
            return [
                'current_r' => 0,
                'next_r' => 0,
                'r_min' => 7,
                'r_max' => 40,
                'cycle' => 0,
                'phase' => 'unknown',
                'phase_end_block' => 0,
                'blocks_to_commit_end' => 0,
                'blocks_to_reveal_end' => 0,
                'blocks_to_cycle_end' => 0,
                'height' => 0,
            ];
        }

        // R values are in basis points (500 = 5%)
        $currentR = ($domc['R_annual'] ?? 0) / 100;
        $nextR = ($domc['R_next'] ?? $domc['R_annual'] ?? 0) / 100;

        // Determine phase and blocks remaining
        $phase = strtolower($domc['phase'] ?? 'unknown');
        $height = $domc['height'] ?? 0;

        // Calculate phase end block based on current phase
        $phaseEndBlock = 0;
        if ($phase === 'commit' || $phase === 'active') {
            $phaseEndBlock = $height + ($domc['blocks_to_commit_end'] ?? 0);
        } elseif ($phase === 'reveal') {
            $phaseEndBlock = $height + ($domc['blocks_to_reveal_end'] ?? 0);
        } elseif ($phase === 'adapt' || $phase === 'finalize') {
            $phaseEndBlock = $height + ($domc['blocks_to_finalize'] ?? 0);
        } elseif ($phase === 'execute' || $phase === 'activate') {
            $phaseEndBlock = $height + ($domc['blocks_to_activate'] ?? 0);
        }

        // Cycle info from RPC
        $cycleStart = $domc['cycle_start'] ?? 0;
        $blocksToEnd = $domc['blocks_to_cycle_end'] ?? 0;
        $cycleLength = $height - $cycleStart + $blocksToEnd;  // Calculate from actual data
        if ($cycleLength <= 0) $cycleLength = 360;  // Fallback
        $cycle = $cycleStart > 0 ? floor($cycleStart / $cycleLength) + 1 : 1;

        // R% votable range: 0% to current ceiling
        // Ceiling starts at 40% (nRInitial) and decays 1%/year until 7% (nRFloor)
        $rMin = 0;  // MNs can vote for 0% yield
        $rMax = ($domc['R_ceiling'] ?? 4000) / 100;  // Current ceiling (dynamic)
        $rFloor = ($domc['R_floor_ceiling'] ?? 700) / 100;   // Final floor (7%)
        $rInitial = ($domc['R_initial'] ?? 4000) / 100;
        $rDecay = ($domc['R_decay_per_year'] ?? 100) / 100;

        // Calculate blocks to COMMIT start (only meaningful in ACTIVE phase)
        // COMMIT phase duration = 60 blocks (testnet: 240->300)
        $commitDuration = round($cycleLength * 60 / 360);
        $blocksToCommitStart = max(0, ($domc['blocks_to_commit_end'] ?? 0) - $commitDuration);

        // Vote statistics
        $commitsCount = $domc['commits_count'] ?? 0;
        $revealsCount = $domc['reveals_count'] ?? 0;
        $totalMNs = $domc['total_mns'] ?? 0;

        return [
            'current_r' => $currentR,
            'next_r' => $nextR,
            'r_min' => $rMin,
            'r_max' => $rMax,
            'r_floor' => $rFloor,  // Final ceiling floor (7%)
            'r_initial' => $rInitial,
            'r_decay' => $rDecay,
            'cycle' => $cycle,
            'cycle_start' => $cycleStart,
            'cycle_length' => $cycleLength,
            'phase' => $phase,
            'phase_end_block' => $phaseEndBlock,
            'blocks_to_commit_start' => $blocksToCommitStart,
            'blocks_to_commit_end' => $domc['blocks_to_commit_end'] ?? 0,
            'blocks_to_reveal_end' => $domc['blocks_to_reveal_end'] ?? 0,
            'blocks_to_finalize' => $domc['blocks_to_finalize'] ?? 0,
            'blocks_to_activate' => $domc['blocks_to_activate'] ?? 0,
            'blocks_to_cycle_end' => $blocksToEnd,
            'height' => $height,
            'pending_votes' => $domc['pending_votes'] ?? [],
            'commits_count' => $commitsCount,
            'reveals_count' => $revealsCount,
            'total_mns' => $totalMNs,
        ];
    }

    /**
     * Get rotation check for fairness
     */
    public static function getRotationCheck()
    {
        $rpc = self::getRpc();
        try {
            $rotation = $rpc->checkrotation();
            if (is_array($rotation)) {
                return $rotation;
            }
        } catch (Exception $e) {
            // RPC not available
        }
        return [
            'fairness_score' => 0,
            'status' => 'unknown',
        ];
    }

    public static function getBlockList($offset = null, $count = BLOCKS_PER_LIST)
    {
        $rpc = self::getRpc();
        $info = $rpc->getblockchaininfo();
        if (!is_array($info)) {
            throw new Exception("RPC connection failed - cannot get blockchain info");
        }
        $height = $info['blocks'] ?? 0;

        $start = $offset === null ? $height : min($offset, $height);
        $blocks = [];

        for ($i = $start; $i >= 0 && count($blocks) < $count; $i--) {
            $hash = $rpc->getblockhash($i);
            if (!$hash) continue;
            $block = $rpc->getblock($hash);
            if (!is_array($block)) continue;

            $txCount = count($block['tx'] ?? []);
            $totalOut = 0;

            foreach (($block['tx'] ?? []) as $txid) {
                $tx = $rpc->getrawtransaction($txid, 1);
                if ($tx && is_array($tx)) {
                    foreach (($tx['vout'] ?? []) as $vout) {
                        $totalOut += $vout['value'] ?? 0;
                    }
                }
            }

            $blocks[] = [
                'height' => $block['height'],
                'hash' => $block['hash'],
                'time' => $block['time'],
                'txcount' => $txCount,
                'size' => $block['size'],
                'total_out' => $totalOut,
            ];
        }

        return ['blocks' => $blocks, 'height' => $height, 'start' => $start];
    }

    public static function getBlock($hash)
    {
        $rpc = self::getRpc();
        // Use verbosity=2 to get full transaction data
        $block = $rpc->getblock($hash, 2);
        if (!$block) return null;

        $transactions = [];
        foreach ($block['tx'] as $tx) {
            // With verbosity=2, tx is already an object with full data
            $outputs = [];
            $inputs = [];
            $totalOut = 0;
            $totalIn = 0;
            $isCoinbase = isset($tx['vin'][0]['coinbase']);

            // Process inputs
            foreach ($tx['vin'] as $vin) {
                if (isset($vin['coinbase'])) {
                    $inputs[] = ['coinbase' => $vin['coinbase']];
                } else {
                    $inputs[] = [
                        'txid' => $vin['txid'] ?? '',
                        'vout' => $vin['vout'] ?? 0,
                    ];
                }
            }

            // Process outputs - asset type comes from RPC (BP30)
            foreach ($tx['vout'] as $vout) {
                $value = $vout['value'] ?? 0;
                $address = $vout['scriptPubKey']['addresses'][0] ?? ($vout['scriptPubKey']['type'] ?? 'unknown');
                $scriptType = $vout['scriptPubKey']['type'] ?? 'unknown';
                $asset = $vout['asset'] ?? 'M0';  // RPC now returns asset type
                $outputs[] = [
                    'n' => $vout['n'],
                    'value' => $value,
                    'address' => $address,
                    'type' => $scriptType,
                    'asset' => $asset,
                    'asset_class' => getAssetClass($asset),
                ];
                $totalOut += $value;
            }

            $transactions[] = [
                'txid' => $tx['txid'],
                'size' => $tx['size'] ?? 0,
                'type' => $tx['type'] ?? 0,
                'type_name' => $tx['tx_type_name'] ?? null,
                'tx_flow' => $tx['tx_flow'] ?? null,
                'inputs' => $inputs,
                'outputs' => $outputs,
                'total' => $totalOut,
                'coinbase' => $isCoinbase,
            ];
        }

        return [
            'height' => $block['height'],
            'hash' => $block['hash'],
            'prevhash' => $block['previousblockhash'] ?? null,
            'nexthash' => $block['nextblockhash'] ?? null,
            'time' => $block['time'],
            'size' => $block['size'],
            'merkleroot' => $block['merkleroot'],
            'nonce' => $block['nonce'],
            'bits' => $block['bits'],
            'difficulty' => $block['difficulty'],
            'confirmations' => $block['confirmations'],
            'transactions' => $transactions,
        ];
    }

    /**
     * Get address information by scanning recent blocks
     * Since we don't have addressindex, we scan the blockchain
     */
    public static function getAddress($address, $maxBlocks = 100)
    {
        $rpc = self::getRpc();

        // Validate address first
        $valid = $rpc->validateaddress($address);
        if (!$valid || !($valid['isvalid'] ?? false)) {
            return null;
        }

        $info = $rpc->getblockchaininfo();
        $height = $info['blocks'];

        $transactions = [];
        $totalReceived = 0;
        $totalSent = 0;

        // Scan recent blocks for transactions involving this address
        $startBlock = max(0, $height - $maxBlocks);
        for ($i = $height; $i >= $startBlock && count($transactions) < 50; $i--) {
            $hash = $rpc->getblockhash($i);
            $block = $rpc->getblock($hash, 2); // verbosity 2 for full tx

            if (!$block || !isset($block['tx'])) continue;

            foreach ($block['tx'] as $tx) {
                $found = false;
                $txReceived = 0;
                $txSent = 0;

                // Check outputs (received)
                foreach ($tx['vout'] as $vout) {
                    $outAddr = $vout['scriptPubKey']['addresses'][0] ?? '';
                    if ($outAddr === $address) {
                        $found = true;
                        $txReceived += $vout['value'];
                        $totalReceived += $vout['value'];
                    }
                }

                // Check inputs (sent) - need to look up previous tx
                foreach ($tx['vin'] as $vin) {
                    if (isset($vin['txid'])) {
                        $prevTx = $rpc->getrawtransaction($vin['txid'], 1);
                        if ($prevTx && isset($prevTx['vout'][$vin['vout']])) {
                            $prevOut = $prevTx['vout'][$vin['vout']];
                            $inAddr = $prevOut['scriptPubKey']['addresses'][0] ?? '';
                            if ($inAddr === $address) {
                                $found = true;
                                $txSent += $prevOut['value'];
                                $totalSent += $prevOut['value'];
                            }
                        }
                    }
                }

                if ($found) {
                    $transactions[] = [
                        'txid' => $tx['txid'],
                        'height' => $block['height'],
                        'time' => $block['time'],
                        'received' => $txReceived,
                        'sent' => $txSent,
                        'net' => $txReceived - $txSent,
                    ];
                }
            }
        }

        return [
            'address' => $address,
            'isvalid' => true,
            'transactions' => $transactions,
            'total_received' => $totalReceived,
            'total_sent' => $totalSent,
            'balance' => $totalReceived - $totalSent,
            'tx_count' => count($transactions),
            'blocks_scanned' => min($maxBlocks, $height),
        ];
    }

    public static function getTransaction($txid)
    {
        $rpc = self::getRpc();
        $tx = $rpc->getrawtransaction($txid, 1);
        if (!$tx) return null;

        // Get block info if confirmed
        $blockInfo = null;
        if (isset($tx['blockhash'])) {
            $block = $rpc->getblock($tx['blockhash']);
            $blockInfo = [
                'hash' => $block['hash'],
                'height' => $block['height'],
                'time' => $block['time'],
            ];
        }

        // Process inputs
        $inputs = [];
        $totalIn = 0;
        $isCoinbase = false;

        foreach ($tx['vin'] as $vin) {
            if (isset($vin['coinbase'])) {
                $isCoinbase = true;
                $inputs[] = [
                    'coinbase' => $vin['coinbase'],
                    'sequence' => $vin['sequence'],
                ];
            } else {
                // Get the previous transaction to find the value
                $prevTx = $rpc->getrawtransaction($vin['txid'], 1);
                $prevOut = $prevTx['vout'][$vin['vout']] ?? null;
                $value = $prevOut['value'] ?? 0;
                $address = $prevOut['scriptPubKey']['addresses'][0] ?? 'unknown';
                $totalIn += $value;

                $inputs[] = [
                    'txid' => $vin['txid'],
                    'vout' => $vin['vout'],
                    'address' => $address,
                    'value' => $value,
                ];
            }
        }

        // Process outputs
        $outputs = [];
        $totalOut = 0;

        foreach ($tx['vout'] as $vout) {
            $address = $vout['scriptPubKey']['addresses'][0] ?? ($vout['scriptPubKey']['type'] ?? 'unknown');
            $asset = $vout['asset'] ?? 'M0';
            $outputs[] = [
                'n' => $vout['n'],
                'value' => $vout['value'],
                'address' => $address,
                'type' => $vout['scriptPubKey']['type'] ?? 'unknown',
                'asset' => $asset,
                'asset_class' => getAssetClass($asset),
            ];
            $totalOut += $vout['value'];
        }

        // Calculate fee (only for non-coinbase)
        $fee = $isCoinbase ? 0 : ($totalIn - $totalOut);

        return [
            'txid' => $tx['txid'],
            'size' => $tx['size'] ?? 0,
            'vsize' => $tx['vsize'] ?? $tx['size'] ?? 0,
            'version' => $tx['version'],
            'type' => $tx['type'] ?? 0,
            'locktime' => $tx['locktime'],
            'blockhash' => $tx['blockhash'] ?? null,
            'confirmations' => $tx['confirmations'] ?? 0,
            'time' => $tx['time'] ?? null,
            'blockinfo' => $blockInfo,
            'coinbase' => $isCoinbase,
            'inputs' => $inputs,
            'outputs' => $outputs,
            'total_in' => $totalIn,
            'total_out' => $totalOut,
            'fee' => $fee,
        ];
    }

    public static function getMasternodeList()
    {
        $rpc = self::getRpc();
        $mnlist = $rpc->protx_list();
        $blockchainInfo = $rpc->getblockchaininfo();
        $currentHeight = $blockchainInfo['blocks'] ?? 0;

        if (!is_array($mnlist)) {
            return [];
        }

        $masternodes = [];
        foreach ($mnlist as $mn) {
            $state = $mn['dmnstate'] ?? [];
            $meta = $mn['metaInfo'] ?? [];
            $collateral = $mn['collateralHash'] ?? '';
            $collateralIndex = $mn['collateralIndex'] ?? 0;

            // Status based on PoSeBanHeight
            $banHeight = $state['PoSeBanHeight'] ?? -1;
            $posePenalty = $state['PoSePenalty'] ?? 0;

            // Determine status
            if ($banHeight != -1) {
                $status = 'POSE_BANNED';
            } elseif ($posePenalty > 0) {
                $status = 'POSE_PENALTY';
            } else {
                $status = 'ENABLED';
            }

            // Registered height
            $registeredHeight = $state['registeredHeight'] ?? 0;

            // Calculate score (higher = better priority for next payment)
            // Score based on: blocks since last paid (more = higher score)
            $lastPaidHeight = $state['lastPaidHeight'] ?? 0;
            $blocksSinceLastPaid = ($lastPaidHeight > 0) ? ($currentHeight - $lastPaidHeight) : $currentHeight;

            // Online = not PoSe banned (PoSe system auto-bans offline nodes)
            $isOnline = ($status === 'ENABLED' || $status === 'POSE_PENALTY');
            $score = $blocksSinceLastPaid;

            // Reduce score if banned or has penalty
            if ($status === 'POSE_BANNED') {
                $score = -1;
            } elseif ($status === 'POSE_PENALTY') {
                $score = $score - ($posePenalty * 10);
            }

            $masternodes[] = [
                'proTxHash' => $mn['proTxHash'] ?? '',
                'collateralHash' => $collateral,
                'collateralIndex' => $collateralIndex,
                'collateralAddress' => $mn['collateralAddress'] ?? '',
                'operatorPubKey' => $state['operatorPubKey'] ?? '',
                'votingAddress' => $state['votingAddress'] ?? '',
                'payoutAddress' => $state['payoutAddress'] ?? '',
                'ownerAddress' => $state['ownerAddress'] ?? '',
                'service' => $state['service'] ?? '',
                'status' => $status,
                'poseBanHeight' => $banHeight,
                'posePenalty' => $posePenalty,
                'lastPaidHeight' => $lastPaidHeight,
                'registeredHeight' => $registeredHeight,
                'isOnline' => $isOnline,
                'blocksSinceLastPaid' => $blocksSinceLastPaid,
                'score' => $score,
            ];
        }

        // Sort by score (highest first = next to be paid)
        usort($masternodes, function($a, $b) {
            return $b['score'] - $a['score'];
        });

        return $masternodes;
    }

    /**
     * Get operators list - Groups MNs by operator public key
     * This is the v4.0 Operator-Centric view
     * Includes score, badges, and proposals stats from operator_score RPC
     */
    public static function getOperatorList()
    {
        $rpc = self::getRpc();
        $mnlist = $rpc->protx_list();
        $blockchainInfo = $rpc->getblockchaininfo();
        $currentHeight = $blockchainInfo['blocks'] ?? 0;

        if (!is_array($mnlist)) {
            return [];
        }

        // Group MNs by operator public key
        $operatorMap = [];

        foreach ($mnlist as $mn) {
            $state = $mn['dmnstate'] ?? [];
            $meta = $mn['metaInfo'] ?? [];
            $operatorPubKey = $state['operatorPubKey'] ?? '';

            if (empty($operatorPubKey)) continue;

            // Initialize operator entry if not exists
            if (!isset($operatorMap[$operatorPubKey])) {
                $operatorMap[$operatorPubKey] = [
                    'operatorPubKey' => $operatorPubKey,
                    'masternodes' => [],
                    'totalMNs' => 0,
                    'activeMNs' => 0,
                    'bannedMNs' => 0,
                    'onlineMNs' => 0,
                    'totalScore' => 0,
                    'oldestRegistration' => PHP_INT_MAX,
                    'services' => [],
                    // v4.0 Score/Badge/Proposal fields (populated later)
                    'badges' => [],
                    'grantsPublished' => 0,
                    'grantsAccepted' => 0,
                    'domcVotes' => 0,
                    'grantVotes' => 0,
                    'blocksProduced' => 0,
                ];
            }

            // Status based on PoSeBanHeight
            $banHeight = $state['PoSeBanHeight'] ?? -1;
            $posePenalty = $state['PoSePenalty'] ?? 0;

            if ($banHeight != -1) {
                $status = 'POSE_BANNED';
                $operatorMap[$operatorPubKey]['bannedMNs']++;
            } elseif ($posePenalty > 0) {
                $status = 'POSE_PENALTY';
                $operatorMap[$operatorPubKey]['activeMNs']++;
            } else {
                $status = 'ENABLED';
                $operatorMap[$operatorPubKey]['activeMNs']++;
            }

            // Online = not PoSe banned (PoSe system auto-bans offline nodes)
            // Scales to any number of MNs
            $isOnline = ($status === 'ENABLED' || $status === 'POSE_PENALTY');
            if ($isOnline) {
                $operatorMap[$operatorPubKey]['onlineMNs']++;
            }

            // Registration height
            $registeredHeight = $state['registeredHeight'] ?? 0;
            if ($registeredHeight > 0 && $registeredHeight < $operatorMap[$operatorPubKey]['oldestRegistration']) {
                $operatorMap[$operatorPubKey]['oldestRegistration'] = $registeredHeight;
            }

            // Score
            $lastPaidHeight = $state['lastPaidHeight'] ?? 0;
            $blocksSinceLastPaid = ($lastPaidHeight > 0) ? ($currentHeight - $lastPaidHeight) : $currentHeight;
            $score = $blocksSinceLastPaid;
            if ($status === 'POSE_BANNED') {
                $score = -1;
            } elseif ($status === 'POSE_PENALTY') {
                $score = $score - ($posePenalty * 10);
            }
            $operatorMap[$operatorPubKey]['totalScore'] += max(0, $score);

            // Service IP
            $service = $state['service'] ?? '';
            if ($service && !in_array($service, $operatorMap[$operatorPubKey]['services'])) {
                $operatorMap[$operatorPubKey]['services'][] = $service;
            }

            // Add MN to operator
            $operatorMap[$operatorPubKey]['masternodes'][] = [
                'proTxHash' => $mn['proTxHash'] ?? '',
                'collateralHash' => $mn['collateralHash'] ?? '',
                'collateralIndex' => $mn['collateralIndex'] ?? 0,
                'service' => $service,
                'status' => $status,
                'isOnline' => $isOnline,
                'registeredHeight' => $registeredHeight,
                'lastPaidHeight' => $lastPaidHeight,
                'score' => $score,
            ];

            $operatorMap[$operatorPubKey]['totalMNs']++;
        }

        // Convert to array and sort by total MNs (descending)
        $operators = array_values($operatorMap);
        usort($operators, function($a, $b) {
            // First by active MNs, then by total score
            if ($b['activeMNs'] != $a['activeMNs']) {
                return $b['activeMNs'] - $a['activeMNs'];
            }
            return $b['totalScore'] - $a['totalScore'];
        });

        // Fix oldestRegistration for genesis MNs and fetch detailed score
        foreach ($operators as &$op) {
            if ($op['oldestRegistration'] == PHP_INT_MAX) {
                $op['oldestRegistration'] = 0; // Genesis
            }
            // Calculate anciennete (days since registration)
            $blocksSinceReg = $currentHeight - $op['oldestRegistration'];
            $op['ancienneteDays'] = floor($blocksSinceReg / 1440); // ~1440 blocks per day

            // Fetch detailed score from operator_score RPC
            try {
                $scoreData = $rpc->operator_score($op['operatorPubKey']);
                if (is_array($scoreData)) {
                    $op['totalScore'] = $scoreData['total_score'] ?? $op['totalScore'];
                    $op['badges'] = $scoreData['badges'] ?? [];
                    $stats = $scoreData['stats'] ?? [];
                    $op['grantsPublished'] = $stats['grants_published'] ?? 0;
                    $op['grantsAccepted'] = $stats['grants_accepted'] ?? 0;
                    $op['domcVotes'] = $stats['domc_vote_count'] ?? 0;
                    $op['grantVotes'] = $stats['grant_vote_count'] ?? 0;
                    $op['blocksProduced'] = $stats['blocks_produced'] ?? 0;
                }
            } catch (Exception $e) {
                // RPC not available or operator not found - use defaults
            }
        }

        return $operators;
    }
}

// DEX API endpoints removed - DEX moved to separate SDK demo site

// ============ ROUTING ============
$query = $_GET['q'] ?? '';
$query = substr($query, 0, 64);
$tab = $_GET['tab'] ?? '';

$page = 'dashboard';
$data = [];

// Helper function to detect if query looks like an address
function isAddress($q) {
    // BATHRON testnet addresses start with x or y (pubkey) or 8 (script), mainnet with D or S
    // Shield addresses start with ptestsapling (testnet) or ps (mainnet)
    if (strlen($q) >= 26 && strlen($q) <= 35) {
        return preg_match('/^[xyYD8S][a-km-zA-HJ-NP-Z1-9]+$/', $q);
    }
    if (strlen($q) > 60 && strpos($q, 'ptestsapling') === 0) {
        return true; // Testnet shield address
    }
    if (strlen($q) > 60 && strpos($q, 'ps') === 0) {
        return true; // Mainnet shield address
    }
    return false;
}

try {
    // SEARCH QUERIES take priority over tab navigation
    // This ensures the search bar works from any tab
    if (strlen($query) == 64) {
        // Try transaction first, then block (64-char hash)
        $tx = BATHRONExplorer::getTransaction($query);
        if ($tx) {
            $page = 'tx';
            $data = $tx;
        } else {
            $block = BATHRONExplorer::getBlock($query);
            if ($block) {
                $page = 'block';
                $data = $block;
            } else {
                $data['error'] = 'Hash not found: ' . htmlspecialchars($query);
                $data['network'] = BATHRONExplorer::getNetworkInfo();
            }
        }
    } elseif (isAddress($query)) {
        // Address query
        $addr = BATHRONExplorer::getAddress($query);
        if ($addr) {
            $page = 'address';
            $data = $addr;
        } else {
            $data['error'] = 'Invalid address: ' . htmlspecialchars($query);
            $data['network'] = BATHRONExplorer::getNetworkInfo();
        }
    } elseif (is_numeric($query) && $query > 0) {
        // Block height query - show block list from that height
        $page = 'blocks';
        $data = BATHRONExplorer::getBlockList((int)$query);
        $data['network'] = BATHRONExplorer::getNetworkInfo();
    // TAB NAVIGATION (when no search query)
    } elseif ($tab === 'blocks' || $query === 'blocks') {
        // Blocks list page
        $page = 'blocks';
        $offset = isset($_GET['offset']) ? (int)$_GET['offset'] : null;
        $data = BATHRONExplorer::getBlockList($offset);
        $data['network'] = BATHRONExplorer::getNetworkInfo();
    } elseif ($tab === 'operators' || $query === 'operators') {
        // Operators page (v4.0 Operator-Centric view)
        $page = 'operators';
        $data['operators'] = BATHRONExplorer::getOperatorList();
        $data['network'] = BATHRONExplorer::getNetworkInfo();
        $data['rotation'] = BATHRONExplorer::getRotationCheck();
    } elseif ($tab === 'masternodes' || $query === 'masternodes') {
        // Masternodes page (individual MNs)
        $page = 'masternodes';
        $data['masternodes'] = BATHRONExplorer::getMasternodeList();
        $data['network'] = BATHRONExplorer::getNetworkInfo();
    } elseif ($tab === 'grants' || $query === 'grants') {
        // DAO Grants page
        $page = 'grants';
        $data['grants'] = BATHRONExplorer::getGrantList();
        $data['dao'] = BATHRONExplorer::getDAOInfo();
        $data['network'] = BATHRONExplorer::getNetworkInfo();
    } elseif ($tab === 'domc' || $query === 'domc') {
        // DOMC (Yield Rate) page
        $page = 'domc';
        $data['domc'] = BATHRONExplorer::getDOMCInfo();
        $data['network'] = BATHRONExplorer::getNetworkInfo();
    // DEX tab now links to external site http://162.19.251.75:3002/
    } else {
        // Default: Dashboard
        $page = 'dashboard';
        $data['network'] = BATHRONExplorer::getNetworkInfo();
        $data['staking'] = BATHRONExplorer::getStakingInfo();
        // Get recent blocks for dashboard
        $blockData = BATHRONExplorer::getBlockList(null, 5);
        $data['recent_blocks'] = $blockData['blocks'];
    }
} catch (Exception $e) {
    $data['error'] = $e->getMessage();
}

// ============ HTML OUTPUT ============
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><?= COIN_NAME ?> <?= NETWORK ?> Explorer</title>
    <link rel="icon" type="image/png" href="favicon.png">
    <?php if ($page === 'dashboard'): ?>
    <meta http-equiv="refresh" content="<?= REFRESH_TIME ?>">
    <?php endif; ?>
    <style>
        :root {
            --bg-primary: #0d1117;
            --bg-secondary: #161b22;
            --bg-tertiary: #21262d;
            --border: #30363d;
            --text-primary: #e6edf3;
            --text-secondary: #8b949e;
            --accent: #7c3aed;
            --accent-light: #a78bfa;
            --success: #3fb950;
            --warning: #d29922;
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
            min-height: 100vh;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }

        /* Header */
        header {
            background: var(--bg-secondary);
            border-bottom: 1px solid var(--border);
            padding: 15px 0;
            margin-bottom: 30px;
        }

        header .container {
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .logo {
            font-size: 24px;
            font-weight: bold;
            color: var(--accent-light);
            text-decoration: none;
        }

        .logo span {
            color: var(--text-secondary);
            font-weight: normal;
            font-size: 14px;
            margin-left: 10px;
            padding: 3px 8px;
            background: var(--bg-tertiary);
            border-radius: 4px;
        }

        /* Search Container (centered below header) */
        .search-container {
            max-width: 700px;
            margin: 0 auto 20px auto;
            padding: 0 20px;
        }

        .search-box {
            display: flex;
            gap: 10px;
            width: 100%;
        }

        .search-box input {
            flex: 1;
            padding: 12px 18px;
            border: 1px solid var(--border);
            border-radius: 8px;
            background: var(--bg-secondary);
            color: var(--text-primary);
            font-size: 14px;
        }

        .search-box input:focus {
            outline: none;
            border-color: var(--accent);
            box-shadow: 0 0 0 3px rgba(124, 58, 237, 0.2);
        }

        .search-box input::placeholder {
            color: var(--text-secondary);
        }

        .search-box button {
            padding: 12px 24px;
            background: var(--accent);
            color: white;
            border: none;
            border-radius: 8px;
            cursor: pointer;
            font-weight: 500;
            transition: background 0.2s;
        }

        .search-box button:hover {
            background: var(--accent-light);
        }

        /* Stats Grid */
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 30px;
        }

        .stat-card {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 20px;
        }

        .stat-card .label {
            color: var(--text-secondary);
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            margin-bottom: 5px;
        }

        .stat-card .value {
            font-size: 24px;
            font-weight: bold;
            color: var(--text-primary);
        }

        .stat-card .value.accent {
            color: var(--accent-light);
        }

        /* Tables */
        .card {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 8px;
            overflow: hidden;
            margin-bottom: 20px;
        }

        .card-header {
            padding: 15px 20px;
            border-bottom: 1px solid var(--border);
            font-weight: 600;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        table {
            width: 100%;
            border-collapse: collapse;
        }

        th, td {
            padding: 12px 20px;
            text-align: left;
            border-bottom: 1px solid var(--border);
        }

        th {
            background: var(--bg-tertiary);
            color: var(--text-secondary);
            font-weight: 500;
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        tr:hover {
            background: var(--bg-tertiary);
        }

        tr:last-child td {
            border-bottom: none;
        }

        a {
            color: var(--accent-light);
            text-decoration: none;
        }

        a:hover {
            text-decoration: underline;
        }

        .hash {
            font-family: 'SFMono-Regular', Consolas, monospace;
            font-size: 13px;
        }

        .truncate {
            max-width: 200px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        /* Block Details */
        .detail-grid {
            display: grid;
            grid-template-columns: 180px 1fr;
            gap: 1px;
            background: var(--border);
        }

        .detail-grid > div {
            padding: 12px 20px;
            background: var(--bg-secondary);
        }

        .detail-grid .label {
            background: var(--bg-tertiary);
            color: var(--text-secondary);
            font-weight: 500;
        }

        .detail-grid .value {
            word-break: break-all;
            font-family: 'SFMono-Regular', Consolas, monospace;
            font-size: 13px;
        }

        /* Pagination */
        .pagination {
            display: flex;
            justify-content: center;
            gap: 10px;
            margin-top: 20px;
        }

        .pagination a, .pagination span {
            padding: 10px 20px;
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 6px;
            color: var(--text-primary);
        }

        .pagination a:hover {
            background: var(--bg-tertiary);
            text-decoration: none;
        }

        .pagination span {
            color: var(--text-secondary);
        }

        /* TX Badge */
        .badge {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: 500;
        }

        .badge-coinbase {
            background: var(--success);
            color: white;
        }

        .badge-tx {
            background: var(--accent);
            color: white;
        }

        /* TX Type Badges (BP30) */
        .badge-standard {
            background: #6b7280;
            color: white;
        }

        .badge-proreg {
            background: #3b82f6;
            color: white;
        }

        .badge-proupserv, .badge-proupreg, .badge-prouprev {
            background: #6366f1;
            color: white;
        }

        .badge-lock {
            background: #10b981;
            color: white;
        }

        .badge-unlock {
            background: #f59e0b;
            color: white;
        }

        .badge-transfer {
            background: #8b5cf6;
            color: white;
        }

        .badge-save {
            background: #06b6d4;
            color: white;
        }

        .badge-unsave {
            background: #ec4899;
            color: white;
        }

        .badge-unknown {
            background: #374151;
            color: white;
        }

        /* Asset Type Indicators (M0/M1/Vault) */
        .asset-badge {
            display: inline-block;
            padding: 1px 6px;
            border-radius: 3px;
            font-size: 10px;
            font-weight: 600;
            margin-left: 5px;
        }

        .asset-m0 {
            background: rgba(59, 130, 246, 0.2);
            color: #60a5fa;
            border: 1px solid rgba(59, 130, 246, 0.3);
        }

        .asset-m1 {
            background: rgba(139, 92, 246, 0.2);
            color: #a78bfa;
            border: 1px solid rgba(139, 92, 246, 0.3);
        }

        .asset-vault {
            background: rgba(16, 185, 129, 0.2);
            color: #34d399;
            border: 1px solid rgba(16, 185, 129, 0.3);
        }

        /* TX Flow indicator */
        .tx-flow {
            display: inline-block;
            padding: 2px 8px;
            border-radius: 4px;
            font-size: 11px;
            font-weight: 500;
            margin-left: 8px;
        }

        .tx-flow-lock {
            background: rgba(16, 185, 129, 0.15);
            color: #10b981;
        }

        .tx-flow-unlock {
            background: rgba(245, 158, 11, 0.15);
            color: #f59e0b;
        }

        .tx-flow-transfer {
            background: rgba(139, 92, 246, 0.15);
            color: #8b5cf6;
        }

        /* Navigation Tabs */
        .nav-tabs {
            display: flex;
            gap: 5px;
        }

        .nav-tab {
            padding: 8px 16px;
            border-radius: 6px;
            color: var(--text-secondary);
            text-decoration: none;
            font-weight: 500;
            transition: all 0.2s;
        }

        .nav-tab:hover {
            background: var(--bg-tertiary);
            color: var(--text-primary);
            text-decoration: none;
        }

        .nav-tab.active {
            background: var(--accent);
            color: white;
        }

        /* Status badges */
        .status-enabled {
            color: var(--success);
            font-weight: 500;
        }

        .status-penalty {
            color: var(--warning);
            font-weight: 500;
        }

        .status-banned {
            color: #f85149;
            font-weight: 500;
        }

        .badge-online {
            background: var(--success);
            color: white;
            padding: 2px 6px;
            border-radius: 3px;
            font-size: 10px;
            font-weight: 500;
        }

        .badge-offline {
            background: var(--text-secondary);
            color: white;
            padding: 2px 6px;
            border-radius: 3px;
            font-size: 10px;
            font-weight: 500;
        }

        /* Sortable table */
        th.sortable {
            cursor: pointer;
            user-select: none;
        }

        th.sortable:hover {
            background: var(--bg-secondary);
        }

        th.sortable::after {
            content: ' ⇅';
            opacity: 0.3;
        }

        th.sortable.sort-asc::after {
            content: ' ↑';
            opacity: 1;
        }

        th.sortable.sort-desc::after {
            content: ' ↓';
            opacity: 1;
        }

        /* Footer */
        footer {
            margin-top: 50px;
            padding: 20px 0;
            border-top: 1px solid var(--border);
            text-align: center;
            color: var(--text-secondary);
            font-size: 14px;
        }

        /* ============ BP30 CANONICAL DASHBOARD ============ */

        /* Pyramid - Total Supply */
        .bp30-pyramid {
            background: linear-gradient(135deg, var(--bg-secondary) 0%, var(--bg-tertiary) 100%);
            border: 2px solid var(--accent);
            border-radius: 12px;
            padding: 30px;
            text-align: center;
            margin-bottom: 25px;
            position: relative;
            overflow: hidden;
        }

        .bp30-pyramid::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            right: 0;
            height: 4px;
            background: linear-gradient(90deg, var(--accent), var(--success), var(--accent));
        }

        .bp30-pyramid .pyramid-label {
            color: var(--accent-light);
            font-size: 14px;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 2px;
            margin-bottom: 10px;
        }

        .bp30-pyramid .pyramid-value {
            font-size: 42px;
            font-weight: 700;
            color: var(--text-primary);
            font-family: 'SFMono-Regular', Consolas, monospace;
        }

        .bp30-pyramid .pyramid-unit {
            color: var(--accent-light);
            font-size: 20px;
            margin-left: 8px;
        }

        .bp30-pyramid .pyramid-status {
            margin-top: 12px;
            font-size: 13px;
            color: var(--success);
            font-weight: 500;
        }

        /* Monetary Table - 3 Columns */
        .bp30-monetary-table {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 0;
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 12px;
            overflow: hidden;
            margin-bottom: 25px;
        }

        .bp30-column {
            border-right: 1px solid var(--border);
            display: flex;
            flex-direction: column;
        }

        .bp30-column:last-child {
            border-right: none;
        }

        .bp30-column-header {
            background: var(--bg-tertiary);
            padding: 15px 20px;
            text-align: center;
            border-bottom: 1px solid var(--border);
        }

        .bp30-column-header .title {
            font-size: 14px;
            font-weight: 700;
            color: var(--text-primary);
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        .bp30-column-header .subtitle {
            font-size: 11px;
            color: var(--text-secondary);
            margin-top: 3px;
        }

        /* Column colors */
        .bp30-column.m0 .bp30-column-header { border-top: 3px solid #10b981; }
        .bp30-column.m1 .bp30-column-header { border-top: 3px solid #8b5cf6; }
        .bp30-column.m2 .bp30-column-header { border-top: 3px solid #ec4899; }

        .bp30-column-body {
            padding: 15px 20px;
            flex: 1;
        }

        .bp30-item {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 10px 0;
            border-bottom: 1px dashed var(--border);
        }

        .bp30-item:last-child {
            border-bottom: none;
        }

        .bp30-item .item-label {
            font-size: 12px;
            color: var(--text-secondary);
            font-family: 'SFMono-Regular', Consolas, monospace;
        }

        .bp30-item .item-value {
            font-size: 14px;
            font-weight: 600;
            color: var(--text-primary);
            font-family: 'SFMono-Regular', Consolas, monospace;
        }

        .bp30-item.outside-invariant {
            opacity: 0.6;
            font-style: italic;
        }

        .bp30-item.outside-invariant .item-label::after {
            content: ' *';
            color: var(--text-secondary);
        }

        .bp30-separator {
            border-top: 2px solid var(--border);
            margin: 10px 0;
        }

        .bp30-column-total {
            background: var(--bg-tertiary);
            padding: 12px 20px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-top: 2px solid var(--border);
        }

        .bp30-column-total .total-label {
            font-size: 12px;
            font-weight: 700;
            text-transform: uppercase;
            color: var(--text-secondary);
        }

        .bp30-column-total .total-value {
            font-size: 16px;
            font-weight: 700;
            font-family: 'SFMono-Regular', Consolas, monospace;
        }

        .bp30-column.m0 .total-value { color: #10b981; }
        .bp30-column.m1 .total-value { color: #8b5cf6; }
        .bp30-column.m2 .total-value { color: #ec4899; }

        /* Invariant A6 Box */
        .bp30-invariant {
            background: var(--bg-secondary);
            border: 2px solid var(--success);
            border-radius: 12px;
            padding: 25px;
            margin-bottom: 25px;
            text-align: center;
        }

        .bp30-invariant.broken {
            border-color: #f85149;
        }

        .bp30-invariant .invariant-header {
            font-size: 14px;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 2px;
            margin-bottom: 15px;
        }

        .bp30-invariant .invariant-header .icon {
            font-size: 18px;
            margin-right: 8px;
        }

        .bp30-invariant .invariant-equation {
            font-family: 'SFMono-Regular', Consolas, monospace;
            font-size: 15px;
            color: var(--text-secondary);
            margin-bottom: 12px;
            padding: 12px;
            background: var(--bg-tertiary);
            border-radius: 8px;
        }

        .bp30-invariant .invariant-values {
            font-family: 'SFMono-Regular', Consolas, monospace;
            font-size: 16px;
            color: var(--text-primary);
            margin-bottom: 8px;
        }

        .bp30-invariant .invariant-sum {
            font-family: 'SFMono-Regular', Consolas, monospace;
            font-size: 20px;
            font-weight: 700;
            margin-bottom: 15px;
        }

        .bp30-invariant .invariant-sum .left { color: #10b981; }
        .bp30-invariant .invariant-sum .equals { color: var(--success); margin: 0 15px; }
        .bp30-invariant .invariant-sum .right { color: #8b5cf6; }

        .bp30-invariant.broken .invariant-sum .equals { color: #f85149; }

        .bp30-invariant .invariant-status {
            display: inline-flex;
            align-items: center;
            gap: 8px;
            padding: 8px 20px;
            border-radius: 20px;
            font-size: 14px;
            font-weight: 600;
        }

        .bp30-invariant .invariant-status.ok {
            background: rgba(16, 185, 129, 0.15);
            color: var(--success);
        }

        .bp30-invariant .invariant-status.broken {
            background: rgba(248, 81, 73, 0.15);
            color: #f85149;
        }

        /* Axioms Table */
        .bp30-axioms {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 12px;
            overflow: hidden;
            margin-bottom: 25px;
        }

        .bp30-axioms .axioms-header {
            background: var(--bg-tertiary);
            padding: 12px 20px;
            font-size: 13px;
            font-weight: 600;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 1px;
            border-bottom: 1px solid var(--border);
        }

        .bp30-axiom-row {
            display: grid;
            grid-template-columns: 50px 1fr 60px;
            padding: 10px 20px;
            border-bottom: 1px solid var(--border);
            font-size: 13px;
            align-items: center;
        }

        .bp30-axiom-row:last-child {
            border-bottom: none;
        }

        .bp30-axiom-row:hover {
            background: var(--bg-tertiary);
        }

        .bp30-axiom-row .axiom-id {
            font-weight: 700;
            color: var(--accent-light);
        }

        .bp30-axiom-row .axiom-text {
            font-family: 'SFMono-Regular', Consolas, monospace;
            color: var(--text-secondary);
        }

        .bp30-axiom-row .axiom-status {
            text-align: center;
            color: var(--success);
            font-size: 16px;
        }

        .bp30-axiom-row.highlight {
            background: rgba(16, 185, 129, 0.08);
        }

        .bp30-axiom-row.highlight .axiom-id {
            color: var(--success);
        }

        /* Yield Panel */
        .bp30-yield {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 20px;
            margin-bottom: 25px;
        }

        .bp30-yield .yield-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
        }

        .bp30-yield .yield-title {
            font-size: 13px;
            font-weight: 600;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        .bp30-yield .yield-note {
            font-size: 11px;
            color: var(--warning);
            background: rgba(245, 158, 11, 0.1);
            padding: 4px 10px;
            border-radius: 4px;
        }

        .bp30-yield .yield-grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 20px;
        }

        .bp30-yield .yield-item {
            text-align: center;
        }

        .bp30-yield .yield-item .value {
            font-size: 22px;
            font-weight: 700;
            color: var(--text-primary);
            font-family: 'SFMono-Regular', Consolas, monospace;
        }

        .bp30-yield .yield-item .label {
            font-size: 11px;
            color: var(--text-secondary);
            margin-top: 5px;
        }

        /* Quick Stats Row */
        .bp30-quick-stats {
            display: grid;
            grid-template-columns: repeat(5, 1fr);
            gap: 12px;
            margin-bottom: 25px;
        }

        .bp30-quick-stat {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 15px;
            text-align: center;
        }

        .bp30-quick-stat .label {
            font-size: 11px;
            color: var(--text-secondary);
            text-transform: uppercase;
            margin-bottom: 5px;
        }

        .bp30-quick-stat .value {
            font-size: 18px;
            font-weight: 700;
            color: var(--text-primary);
        }

        .bp30-quick-stat .value.accent {
            color: var(--accent-light);
        }

        /* Responsive */
        @media (max-width: 768px) {
            header .container {
                flex-direction: column;
                gap: 15px;
            }

            .search-box input {
                width: 250px;
            }

            .stats-grid {
                grid-template-columns: repeat(2, 1fr);
            }

            .detail-grid {
                grid-template-columns: 1fr;
            }

            .bp30-monetary-table {
                grid-template-columns: 1fr;
            }

            .bp30-column {
                border-right: none;
                border-bottom: 1px solid var(--border);
            }

            .bp30-column:last-child {
                border-bottom: none;
            }

            .bp30-quick-stats {
                grid-template-columns: repeat(2, 1fr);
            }

            .bp30-yield .yield-grid {
                grid-template-columns: 1fr;
                gap: 15px;
            }

            .bp30-axiom-row {
                grid-template-columns: 40px 1fr 40px;
                font-size: 11px;
            }
        }
    </style>
</head>
<body>
    <header>
        <div class="container">
            <a href="./" class="logo">
                BATHRON 2.0 <span><?= NETWORK ?></span>
            </a>
            <nav class="nav-tabs">
                <a href="./" class="nav-tab <?= $page === 'dashboard' ? 'active' : '' ?>">Dashboard</a>
                <a href="?tab=blocks" class="nav-tab <?= $page === 'blocks' ? 'active' : '' ?>">Blocks</a>
                <a href="?tab=operators" class="nav-tab <?= $page === 'operators' ? 'active' : '' ?>">Operators</a>
                <a href="?tab=masternodes" class="nav-tab <?= $page === 'masternodes' ? 'active' : '' ?>">Masternodes</a>
                <a href="?tab=domc" class="nav-tab <?= $page === 'domc' ? 'active' : '' ?>">DOMC</a>
                <a href="?tab=grants" class="nav-tab <?= $page === 'grants' ? 'active' : '' ?>">DAO Grants</a>
                <a href="http://162.19.251.75:3002/" class="nav-tab" target="_blank" style="color: var(--accent);">DEX ↗</a>
            </nav>
        </div>
    </header>

    <!-- Search Bar (centered below header) -->
    <div class="search-container">
        <form class="search-box" method="get">
            <?php if ($tab): ?><input type="hidden" name="tab" value="<?= htmlspecialchars($tab) ?>"><?php endif; ?>
            <input type="text" name="q" placeholder="Search block hash, height, transaction, or address..." value="<?= htmlspecialchars($query) ?>">
            <button type="submit">Search</button>
        </form>
    </div>

    <main class="container">
        <?php if (isset($data['error'])): ?>
            <div class="card">
                <div class="card-header">Error</div>
                <div style="padding: 20px; color: #f85149;">
                    <?= htmlspecialchars($data['error']) ?>
                </div>
            </div>
        <?php elseif ($page === 'dashboard'): ?>
            <!-- ============ BP30 CANONICAL DASHBOARD ============ -->
            <?php
            // ALL values from RPC - NO PHP calculations
            $m0Total = $data['network']['m0_total'];
            $m0Free = $data['network']['m0_free'];  // From RPC
            $m0VaultedActive = $data['network']['m0_vaulted_active'];
            $m0Savingspool = $data['network']['m0_savingspool'];
            $m0MnCollateral = $data['network']['m0_mn_collateral'];
            $m0Shield = $data['network']['m0_shield'];
            $m1Supply = $data['network']['m1_supply'];
            $m2Locked = $data['network']['m2_locked'];
            $yieldVault = $data['network']['yield_vault'];
            $rPercent = $data['network']['r_percent'];
            $invariantsOk = $data['network']['invariants_ok'];
            $stateAvailable = $data['network']['state_available'];
            // A5: Monetary Conservation
            $a5Ok = $data['network']['a5_ok'] ?? true;
            $a5Available = $data['network']['a5_available'] ?? false;
            $a5M0Total = $data['network']['a5_m0_total'] ?? 0;
            $a5Coinbase = $data['network']['a5_coinbase'] ?? 0;
            $a5Treasury = $data['network']['a5_treasury'] ?? 0;
            $a5Yield = $data['network']['a5_yield'] ?? 0;
            $a5Delta = $data['network']['a5_delta'] ?? 0;
            // A6: Settlement Backing
            $a6Ok = $data['network']['a6_ok'] ?? true;
            $a6Left = $data['network']['a6_left'];   // From RPC
            $a6Right = $data['network']['a6_right']; // From RPC
            ?>

            <!-- 1️⃣ PYRAMID - TOTAL SUPPLY -->
            <div class="bp30-pyramid">
                <div class="pyramid-label">Total Supply (M0)</div>
                <div class="pyramid-value">
                    <?= number_format($m0Total, 2) ?><span class="pyramid-unit">M0</span>
                </div>
                <div class="pyramid-status">CONSERVED (Consensus Enforced)</div>
            </div>

            <!-- Quick Stats Row -->
            <div class="bp30-quick-stats">
                <div class="bp30-quick-stat">
                    <div class="label">Block</div>
                    <div class="value accent"><?= number_format($data['network']['blocks']) ?></div>
                </div>
                <div class="bp30-quick-stat">
                    <div class="label">Finality</div>
                    <div class="value" style="color: <?= $data['network']['finality_status'] === 'healthy' ? 'var(--success)' : 'var(--warning)' ?>;">
                        <?= strtoupper($data['network']['finality_status']) ?>
                    </div>
                </div>
                <div class="bp30-quick-stat">
                    <div class="label">MNs</div>
                    <div class="value"><?= $data['network']['masternodes_active'] ?>/<?= $data['network']['masternodes_total'] ?></div>
                </div>
                <div class="bp30-quick-stat">
                    <div class="label">Operators</div>
                    <div class="value"><?= $data['network']['operators_count'] ?></div>
                </div>
                <div class="bp30-quick-stat">
                    <div class="label">R% Annual</div>
                    <div class="value accent"><?= number_format($rPercent, 2) ?>%</div>
                </div>
            </div>

            <!-- 2️⃣ MONETARY TABLE - 3 COLUMNS -->
            <div class="bp30-monetary-table">
                <!-- M0 Column -->
                <div class="bp30-column m0">
                    <div class="bp30-column-header">
                        <div class="title">Total M0</div>
                        <div class="subtitle">Base Money</div>
                    </div>
                    <div class="bp30-column-body">
                        <div class="bp30-item">
                            <span class="item-label">M0_FREE</span>
                            <span class="item-value"><?= number_format($m0Free, 2) ?></span>
                        </div>
                        <div class="bp30-item outside-invariant">
                            <span class="item-label">M0_SHIELD</span>
                            <span class="item-value"><?= number_format($m0Shield, 2) ?></span>
                        </div>
                        <div class="bp30-item">
                            <span class="item-label">M0_VAULTED</span>
                            <span class="item-value"><?= number_format($m0VaultedActive, 2) ?></span>
                        </div>
                        <div class="bp30-item">
                            <span class="item-label">M0_SAVINGS_SHIELD</span>
                            <span class="item-value"><?= number_format($m0Savingspool, 2) ?></span>
                        </div>
                        <div class="bp30-separator"></div>
                        <div class="bp30-item">
                            <span class="item-label">M0_MN_COLLATERAL</span>
                            <span class="item-value"><?= number_format($m0MnCollateral, 2) ?></span>
                        </div>
                    </div>
                    <div class="bp30-column-total">
                        <span class="total-label">Total</span>
                        <span class="total-value"><?= number_format($m0Total, 2) ?></span>
                    </div>
                </div>

                <!-- M1 Column -->
                <div class="bp30-column m1">
                    <div class="bp30-column-header">
                        <div class="title">Total M1</div>
                        <div class="subtitle">Receipt Tokens</div>
                    </div>
                    <div class="bp30-column-body">
                        <div class="bp30-item" style="visibility: hidden;">
                            <span class="item-label">&nbsp;</span>
                            <span class="item-value">&nbsp;</span>
                        </div>
                        <div class="bp30-item" style="visibility: hidden;">
                            <span class="item-label">&nbsp;</span>
                            <span class="item-value">&nbsp;</span>
                        </div>
                        <div class="bp30-item">
                            <span class="item-label">M1_SUPPLY</span>
                            <span class="item-value"><?= number_format($m1Supply, 2) ?></span>
                        </div>
                        <div style="flex: 1;"></div>
                        <div style="font-size: 11px; color: var(--text-secondary); padding: 10px 0;">
                            Transferable claim on vaulted M0
                        </div>
                    </div>
                    <div class="bp30-column-total">
                        <span class="total-label">Total</span>
                        <span class="total-value"><?= number_format($m1Supply, 2) ?></span>
                    </div>
                </div>

                <!-- M2 Column -->
                <div class="bp30-column m2">
                    <div class="bp30-column-header">
                        <div class="title">Total M2</div>
                        <div class="subtitle">Savings Rights</div>
                    </div>
                    <div class="bp30-column-body">
                        <div class="bp30-item" style="visibility: hidden;">
                            <span class="item-label">&nbsp;</span>
                            <span class="item-value">&nbsp;</span>
                        </div>
                        <div class="bp30-item" style="visibility: hidden;">
                            <span class="item-label">&nbsp;</span>
                            <span class="item-value">&nbsp;</span>
                        </div>
                        <div class="bp30-item" style="visibility: hidden;">
                            <span class="item-label">&nbsp;</span>
                            <span class="item-value">&nbsp;</span>
                        </div>
                        <div class="bp30-item">
                            <span class="item-label">M2_LOCKED</span>
                            <span class="item-value"><?= number_format($m2Locked, 2) ?></span>
                        </div>
                        <div style="flex: 1;"></div>
                        <div style="font-size: 11px; color: var(--text-secondary); padding: 10px 0;">
                            Non-transferable savings earning yield
                        </div>
                    </div>
                    <div class="bp30-column-total">
                        <span class="total-label">Total</span>
                        <span class="total-value"><?= number_format($m2Locked, 2) ?></span>
                    </div>
                </div>
            </div>

            <!-- 3️⃣ CONSENSUS INVARIANTS -->
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 20px;">

                <!-- A5: INFLATION CONTROL -->
                <div class="bp30-invariant <?= $a5Ok ? '' : 'broken' ?>">
                    <div class="invariant-header">
                        <span class="icon">&#9878;</span>INVARIANT A5 — INFLATION CONTROL
                    </div>
                    <div class="invariant-equation">
                        M0_TOTAL(N) = M0_TOTAL(N-1) + Coinbase - T - Y
                    </div>
                    <?php if ($a5Available): ?>
                    <div class="invariant-values">
                        Block delta: +<?= number_format($a5Coinbase, 2) ?> CB
                        <?php if ($a5Treasury > 0): ?> -<?= number_format($a5Treasury, 2) ?> T<?php endif; ?>
                        <?php if ($a5Yield > 0): ?> -<?= number_format($a5Yield, 2) ?> Y<?php endif; ?>
                    </div>
                    <div class="invariant-sum">
                        <span class="left">M0_TOTAL</span>
                        <span class="equals">=</span>
                        <span class="right"><?= number_format($a5M0Total, 2) ?></span>
                    </div>
                    <div class="invariant-status <?= $a5Ok ? 'ok' : 'broken' ?>">
                        <?= $a5Ok ? '&#10004; VERIFIED' : '&#10006; BROKEN' ?>
                    </div>
                    <?php else: ?>
                    <div class="invariant-values" style="color: var(--text-secondary);">
                        M0_TOTAL: <?= number_format($a5M0Total, 2) ?>
                    </div>
                    <div class="invariant-status ok" style="background: rgba(255, 193, 7, 0.15); color: #ffc107;">
                        &#8987; PENDING NODE UPDATE
                    </div>
                    <?php endif; ?>
                    <div style="font-size: 10px; color: var(--text-secondary); margin-top: 8px; text-align: center;">
                        Anti-inflation: blocks M0 creation even if 90% MNs compromised
                    </div>
                </div>

                <!-- A6: CORE TRUTH -->
                <div class="bp30-invariant <?= $a6Ok ? '' : 'broken' ?>">
                    <div class="invariant-header">
                        <span class="icon">&#9878;</span>INVARIANT A6 — CORE TRUTH
                    </div>
                    <div class="invariant-equation">
                        M0_VAULTED + M0_SAVINGS == M1 + M2
                    </div>
                    <div class="invariant-values">
                        <?= number_format($m0VaultedActive, 2) ?> + <?= number_format($m0Savingspool, 2) ?>
                        &nbsp;&nbsp;==&nbsp;&nbsp;
                        <?= number_format($m1Supply, 2) ?> + <?= number_format($m2Locked, 2) ?>
                    </div>
                    <div class="invariant-sum">
                        <span class="left"><?= number_format($a6Left, 2) ?></span>
                        <span class="equals"><?= $a6Ok ? '==' : '!=' ?></span>
                        <span class="right"><?= number_format($a6Right, 2) ?></span>
                    </div>
                    <div class="invariant-status <?= $a6Ok ? 'ok' : 'broken' ?>">
                        <?= $a6Ok ? '&#10004; VERIFIED' : '&#10006; BROKEN' ?>
                    </div>
                    <div style="font-size: 10px; color: var(--text-secondary); margin-top: 8px; text-align: center;">
                        Settlement backing: all M1/M2 fully backed by vaulted M0
                    </div>
                </div>

            </div>

            <!-- 4️⃣ YIELD SYSTEM - Annual Inflation Estimates -->
            <?php
            // Yield calculations (estimates based on current state)
            $rDecimal = $rPercent / 100;
            $yieldForSavers = $m0Savingspool * $rDecimal;           // M2 holders earn this
            $treasuryCut = $m1Supply * $rDecimal * 0.20;            // 20% of M1 backing yield → Treasury
            $totalNewM0 = $yieldForSavers + $treasuryCut;           // Total annual inflation
            $inflationRate = $m0Total > 0 ? ($totalNewM0 / $m0Total) * 100 : 0;
            ?>
            <div class="bp30-yield">
                <div class="yield-header">
                    <span class="yield-title">Yield System</span>
                    <span class="yield-note">Annual Estimates (Outside A6)</span>
                </div>

                <!-- Input Parameters -->
                <div style="background: var(--bg-tertiary); border-radius: 8px; padding: 15px; margin-bottom: 15px;">
                    <div style="font-size: 11px; color: var(--text-secondary); margin-bottom: 10px; text-transform: uppercase; letter-spacing: 1px;">Input Parameters</div>
                    <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; text-align: center;">
                        <div>
                            <div style="font-size: 18px; font-weight: 600; color: var(--accent-light);"><?= number_format($m0Savingspool, 0) ?></div>
                            <div style="font-size: 11px; color: var(--text-secondary);">M0_SAVINGS_SHIELD</div>
                        </div>
                        <div>
                            <div style="font-size: 18px; font-weight: 600; color: var(--accent-light);"><?= number_format($m1Supply, 0) ?></div>
                            <div style="font-size: 11px; color: var(--text-secondary);">M1_SUPPLY</div>
                        </div>
                        <div>
                            <div style="font-size: 18px; font-weight: 600; color: var(--success);"><?= number_format($rPercent, 2) ?>%</div>
                            <div style="font-size: 11px; color: var(--text-secondary);">R% (DOMC)</div>
                        </div>
                    </div>
                </div>

                <!-- Yield Formulas & Results -->
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 15px; margin-bottom: 15px;">
                    <!-- Yield for M2 Savers -->
                    <div style="background: var(--bg-tertiary); border-radius: 8px; padding: 15px; border-left: 3px solid #ec4899;">
                        <div style="font-size: 11px; color: var(--text-secondary); margin-bottom: 8px;">YIELD FOR M2 SAVERS</div>
                        <div style="font-family: monospace; font-size: 12px; color: var(--text-secondary); margin-bottom: 10px;">
                            M0_SAVINGS_SHIELD × R%
                        </div>
                        <div style="font-family: monospace; font-size: 11px; color: var(--text-secondary); margin-bottom: 10px;">
                            <?= number_format($m0Savingspool, 0) ?> × <?= number_format($rPercent, 2) ?>%
                        </div>
                        <div style="font-size: 22px; font-weight: 700; color: #ec4899;">
                            +<?= number_format($yieldForSavers, 2) ?> <span style="font-size: 12px; font-weight: 400;">M0/year</span>
                        </div>
                    </div>

                    <!-- Treasury Cut -->
                    <div style="background: var(--bg-tertiary); border-radius: 8px; padding: 15px; border-left: 3px solid #f59e0b;">
                        <div style="font-size: 11px; color: var(--text-secondary); margin-bottom: 8px;">DAO TREASURY (T)</div>
                        <div style="font-family: monospace; font-size: 12px; color: var(--text-secondary); margin-bottom: 10px;">
                            M1_SUPPLY × R% × 20%
                        </div>
                        <div style="font-family: monospace; font-size: 11px; color: var(--text-secondary); margin-bottom: 10px;">
                            <?= number_format($m1Supply, 0) ?> × <?= number_format($rPercent, 2) ?>% × 20%
                        </div>
                        <div style="font-size: 22px; font-weight: 700; color: #f59e0b;">
                            +<?= number_format($treasuryCut, 2) ?> <span style="font-size: 12px; font-weight: 400;">M0/year</span>
                        </div>
                    </div>
                </div>

                <!-- Total Inflation Summary -->
                <div style="background: linear-gradient(135deg, var(--bg-tertiary) 0%, rgba(124, 58, 237, 0.1) 100%); border-radius: 8px; padding: 20px; border: 1px solid var(--border);">
                    <div style="display: grid; grid-template-columns: 1fr auto 1fr; gap: 20px; align-items: center;">
                        <div style="text-align: center;">
                            <div style="font-size: 11px; color: var(--text-secondary); margin-bottom: 5px;">TOTAL NEW M0 / YEAR</div>
                            <div style="font-size: 24px; font-weight: 700; color: var(--text-primary);">
                                +<?= number_format($totalNewM0, 2) ?>
                            </div>
                            <div style="font-size: 11px; color: var(--text-secondary);">
                                (<?= number_format($yieldForSavers, 0) ?> + <?= number_format($treasuryCut, 0) ?>)
                            </div>
                        </div>
                        <div style="font-size: 24px; color: var(--text-secondary);">÷</div>
                        <div style="text-align: center;">
                            <div style="font-size: 11px; color: var(--text-secondary); margin-bottom: 5px;">M0_TOTAL</div>
                            <div style="font-size: 24px; font-weight: 700; color: var(--text-primary);">
                                <?= number_format($m0Total, 0) ?>
                            </div>
                        </div>
                    </div>
                    <div style="text-align: center; margin-top: 20px; padding-top: 15px; border-top: 1px solid var(--border);">
                        <div style="font-size: 11px; color: var(--text-secondary); margin-bottom: 5px;">ESTIMATED ANNUAL INFLATION</div>
                        <div style="font-size: 32px; font-weight: 700; color: var(--success);">
                            <?= number_format($inflationRate, 4) ?>%
                        </div>
                        <div style="font-size: 11px; color: var(--text-secondary); margin-top: 5px;">
                            Based on current R% and settlement state
                        </div>
                    </div>
                </div>

                <!-- DAO Treasury Note -->
                <div style="margin-top: 15px; padding: 12px; background: rgba(245, 158, 11, 0.1); border-radius: 6px; border-left: 3px solid #f59e0b;">
                    <div style="font-size: 11px; color: #f59e0b;">
                        <strong>DAO Treasury:</strong> Not yet implemented in consensus. Values shown are estimates.
                    </div>
                </div>
            </div>

            <!-- Recent Blocks Preview -->
            <div class="card">
                <div class="card-header">
                    <span>Recent Blocks</span>
                    <a href="?tab=blocks" style="font-weight: normal; font-size: 14px;">View all &rarr;</a>
                </div>
                <table>
                    <thead>
                        <tr>
                            <th>Height</th>
                            <th>Hash</th>
                            <th>Time</th>
                            <th>Txs</th>
                            <th>Size</th>
                        </tr>
                    </thead>
                    <tbody>
                        <?php foreach ($data['recent_blocks'] as $block): ?>
                        <tr>
                            <td><a href="?q=<?= $block['hash'] ?>"><?= number_format($block['height']) ?></a></td>
                            <td class="hash truncate"><a href="?q=<?= $block['hash'] ?>"><?= substr($block['hash'], 0, 16) ?>...</a></td>
                            <td><?= date('H:i:s', $block['time']) ?></td>
                            <td><?= $block['txcount'] ?></td>
                            <td><?= number_format($block['size']) ?> B</td>
                        </tr>
                        <?php endforeach; ?>
                    </tbody>
                </table>
            </div>

        <?php elseif ($page === 'blocks'): ?>
            <!-- BLOCKS LIST -->
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="label">Block Height</div>
                    <div class="value accent"><?= number_format($data['network']['blocks']) ?></div>
                </div>
                <div class="stat-card">
                    <div class="label">Last Finalized</div>
                    <div class="value"><?= number_format($data['network']['last_finalized']) ?></div>
                </div>
                <div class="stat-card">
                    <div class="label">Finality Status</div>
                    <div class="value" style="color: <?= $data['network']['finality_status'] === 'healthy' ? 'var(--success)' : 'var(--warning)' ?>;">
                        <?= strtoupper($data['network']['finality_status']) ?>
                    </div>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <span>Blocks</span>
                    <span style="color: var(--text-secondary); font-weight: normal; font-size: 14px;">
                        Auto-refresh: <?= REFRESH_TIME ?>s
                    </span>
                </div>
                <table>
                    <thead>
                        <tr>
                            <th>Height</th>
                            <th>Hash</th>
                            <th>Time</th>
                            <th>Txs</th>
                            <th>Size</th>
                            <th>Value</th>
                            <th>Final</th>
                        </tr>
                    </thead>
                    <tbody>
                        <?php foreach ($data['blocks'] as $block): ?>
                        <tr>
                            <td><a href="?q=<?= $block['hash'] ?>"><?= number_format($block['height']) ?></a></td>
                            <td class="hash truncate"><a href="?q=<?= $block['hash'] ?>"><?= substr($block['hash'], 0, 16) ?>...</a></td>
                            <td><?= date('Y-m-d H:i:s', $block['time']) ?></td>
                            <td><?= $block['txcount'] ?></td>
                            <td><?= number_format($block['size']) ?> B</td>
                            <td><?= number_format($block['total_out'], 2) ?> M</td>
                            <td style="color: <?= $block['height'] <= $data['network']['last_finalized'] ? 'var(--success)' : 'var(--text-secondary)' ?>;">
                                <?= $block['height'] <= $data['network']['last_finalized'] ? '✓' : '' ?>
                            </td>
                        </tr>
                        <?php endforeach; ?>
                    </tbody>
                </table>
            </div>

            <!-- Pagination -->
            <div class="pagination">
                <?php if ($data['start'] < $data['height']): ?>
                    <a href="?tab=blocks&offset=<?= min($data['start'] + BLOCKS_PER_LIST, $data['height']) ?>">&larr; Newer</a>
                <?php else: ?>
                    <span>&larr; Newer</span>
                <?php endif; ?>

                <span>Block <?= number_format($data['start']) ?></span>

                <?php if ($data['start'] - BLOCKS_PER_LIST >= 0): ?>
                    <a href="?tab=blocks&offset=<?= $data['start'] - BLOCKS_PER_LIST ?>">Older &rarr;</a>
                <?php else: ?>
                    <span>Older &rarr;</span>
                <?php endif; ?>
            </div>

        <?php elseif ($page === 'block'): ?>
            <!-- Block Details -->
            <div class="card">
                <div class="card-header">Block #<?= number_format($data['height']) ?></div>
                <div class="detail-grid">
                    <div class="label">Hash</div>
                    <div class="value"><?= $data['hash'] ?></div>

                    <div class="label">Confirmations</div>
                    <div class="value"><?= number_format($data['confirmations']) ?></div>

                    <div class="label">Timestamp</div>
                    <div class="value"><?= date('Y-m-d H:i:s', $data['time']) ?> UTC</div>

                    <div class="label">Size</div>
                    <div class="value"><?= number_format($data['size']) ?> bytes</div>

                    <div class="label">Difficulty</div>
                    <div class="value"><?= $data['difficulty'] ?></div>

                    <div class="label">Merkle Root</div>
                    <div class="value"><?= $data['merkleroot'] ?></div>

                    <div class="label">Nonce</div>
                    <div class="value"><?= $data['nonce'] ?></div>

                    <div class="label">Bits</div>
                    <div class="value"><?= $data['bits'] ?></div>

                    <?php if ($data['prevhash']): ?>
                    <div class="label">Previous Block</div>
                    <div class="value"><a href="?<?= $data['prevhash'] ?>"><?= $data['prevhash'] ?></a></div>
                    <?php endif; ?>

                    <?php if ($data['nexthash']): ?>
                    <div class="label">Next Block</div>
                    <div class="value"><a href="?<?= $data['nexthash'] ?>"><?= $data['nexthash'] ?></a></div>
                    <?php endif; ?>
                </div>
            </div>

            <!-- Transactions -->
            <div class="card">
                <div class="card-header">Transactions (<?= count($data['transactions']) ?>)</div>
                <?php foreach ($data['transactions'] as $tx): ?>
                <div style="border-bottom: 1px solid var(--border); padding: 15px 20px;">
                    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;">
                        <div>
                            <a href="?<?= $tx['txid'] ?>" class="hash" style="font-size: 14px;"><?= $tx['txid'] ?></a>
                            <span style="margin-left: 10px;"><?= getTxTypeBadge($tx['type'] ?? 0, $tx['coinbase']) ?></span>
                            <?php if (!empty($tx['tx_flow'])): ?>
                                <span class="tx-flow tx-flow-<?= strtolower(str_replace('TX_', '', $tx['type_name'] ?? 'standard')) ?>"><?= $tx['tx_flow'] ?></span>
                            <?php endif; ?>
                        </div>
                        <div style="color: var(--text-secondary); font-size: 13px;">
                            <?= number_format($tx['total'], 8) ?> M
                        </div>
                    </div>
                    <div style="display: grid; grid-template-columns: 1fr auto 1fr; gap: 10px; font-size: 13px;">
                        <!-- Inputs -->
                        <div>
                            <?php foreach ($tx['inputs'] as $input): ?>
                                <?php if (isset($input['coinbase'])): ?>
                                    <div style="padding: 5px; background: var(--bg-tertiary); border-radius: 4px; margin-bottom: 5px;">
                                        <span class="badge badge-coinbase">Coinbase</span>
                                    </div>
                                <?php else: ?>
                                    <div style="padding: 5px; background: var(--bg-tertiary); border-radius: 4px; margin-bottom: 5px;">
                                        <div class="hash truncate" style="max-width: 250px;"><?= substr($input['txid'], 0, 16) ?>...:<?= $input['vout'] ?></div>
                                    </div>
                                <?php endif; ?>
                            <?php endforeach; ?>
                        </div>
                        <!-- Arrow -->
                        <div style="display: flex; align-items: center; color: var(--accent-light); font-size: 20px;">
                            &rarr;
                        </div>
                        <!-- Outputs with asset badges -->
                        <div>
                            <?php foreach ($tx['outputs'] as $output): ?>
                                <div style="padding: 5px; background: var(--bg-tertiary); border-radius: 4px; margin-bottom: 5px; display: flex; justify-content: space-between; align-items: center;">
                                    <div style="display: flex; align-items: center;">
                                        <?php if (isAddress($output['address'])): ?>
                                            <a href="?<?= $output['address'] ?>" class="hash truncate" style="max-width: 160px;"><?= $output['address'] ?></a>
                                        <?php else: ?>
                                            <span class="hash truncate" style="max-width: 160px;"><?= $output['address'] ?></span>
                                        <?php endif; ?>
                                    </div>
                                    <div style="display: flex; align-items: center; gap: 8px;">
                                        <span style="color: var(--success);"><?= number_format($output['value'], 8) ?></span>
                                        <span class="asset-badge <?= $output['asset_class'] ?? 'asset-m0' ?>"><?= $output['asset'] ?? 'M0' ?></span>
                                    </div>
                                </div>
                            <?php endforeach; ?>
                        </div>
                    </div>
                </div>
                <?php endforeach; ?>
            </div>

            <div class="pagination">
                <a href="./">&larr; Back to blocks</a>
            </div>

        <?php elseif ($page === 'tx'): ?>
            <!-- Transaction Details -->
            <div class="card">
                <div class="card-header">
                    Transaction Details
                    <?= getTxTypeBadge($data['type'] ?? 0, $data['coinbase']) ?>
                </div>
                <div class="detail-grid">
                    <div class="label">TxID</div>
                    <div class="value"><?= $data['txid'] ?></div>

                    <div class="label">Status</div>
                    <div class="value">
                        <?php if ($data['confirmations'] > 0): ?>
                            <span style="color: var(--success);">Confirmed</span> (<?= number_format($data['confirmations']) ?> confirmations)
                        <?php else: ?>
                            <span style="color: var(--warning);">Unconfirmed</span>
                        <?php endif; ?>
                    </div>

                    <?php if ($data['blockinfo']): ?>
                    <div class="label">Block</div>
                    <div class="value">
                        <a href="?<?= $data['blockinfo']['hash'] ?>">#<?= number_format($data['blockinfo']['height']) ?></a>
                        (<?= date('Y-m-d H:i:s', $data['blockinfo']['time']) ?> UTC)
                    </div>
                    <?php endif; ?>

                    <div class="label">Size</div>
                    <div class="value"><?= number_format($data['size']) ?> bytes</div>

                    <div class="label">Type</div>
                    <div class="value">
                        <?= getTxTypeBadge($data['type'] ?? 0, $data['coinbase']) ?>
                        <span style="color: var(--text-secondary); margin-left: 10px; font-family: inherit;">
                            <?php $typeInfo = getTxTypeInfo($data['type'] ?? 0); ?>
                            <?= htmlspecialchars($typeInfo['desc']) ?>
                        </span>
                    </div>

                    <?php if (!$data['coinbase']): ?>
                    <div class="label">Fee</div>
                    <div class="value"><?= number_format($data['fee'], 8) ?> <?= COIN_TICKER ?></div>
                    <?php endif; ?>

                    <div class="label">Version</div>
                    <div class="value"><?= $data['version'] ?></div>

                    <div class="label">Lock Time</div>
                    <div class="value"><?= $data['locktime'] ?></div>
                </div>
            </div>

            <!-- Inputs & Outputs -->
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 20px;">
                <!-- Inputs -->
                <div class="card">
                    <div class="card-header">Inputs (<?= count($data['inputs']) ?>)</div>
                    <table>
                        <thead>
                            <tr>
                                <th>From</th>
                                <th>Value</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php foreach ($data['inputs'] as $input): ?>
                            <tr>
                                <?php if (isset($input['coinbase'])): ?>
                                <td class="hash" colspan="2">
                                    <span class="badge badge-coinbase">Coinbase</span>
                                    <span style="color: var(--text-secondary); font-size: 12px; margin-left: 10px;">
                                        <?= substr($input['coinbase'], 0, 40) ?>...
                                    </span>
                                </td>
                                <?php else: ?>
                                <td>
                                    <div class="hash truncate" style="max-width: 180px;">
                                        <?php if (isAddress($input['address'])): ?>
                                            <a href="?<?= $input['address'] ?>"><?= $input['address'] ?></a>
                                        <?php else: ?>
                                            <?= $input['address'] ?>
                                        <?php endif; ?>
                                    </div>
                                    <div style="font-size: 11px; color: var(--text-secondary);">
                                        <a href="?<?= $input['txid'] ?>"><?= substr($input['txid'], 0, 16) ?>...</a>:<?= $input['vout'] ?>
                                    </div>
                                </td>
                                <td><?= number_format($input['value'], 8) ?> <?= COIN_TICKER ?></td>
                                <?php endif; ?>
                            </tr>
                            <?php endforeach; ?>
                            <?php if (!$data['coinbase']): ?>
                            <tr style="background: var(--bg-tertiary);">
                                <td><strong>Total</strong></td>
                                <td><strong><?= number_format($data['total_in'], 8) ?> <?= COIN_TICKER ?></strong></td>
                            </tr>
                            <?php endif; ?>
                        </tbody>
                    </table>
                </div>

                <!-- Outputs -->
                <div class="card">
                    <div class="card-header">Outputs (<?= count($data['outputs']) ?>)</div>
                    <table>
                        <thead>
                            <tr>
                                <th>To</th>
                                <th>Value</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php foreach ($data['outputs'] as $output): ?>
                            <tr>
                                <td>
                                    <div class="hash truncate" style="max-width: 180px;">
                                        <?php if (isAddress($output['address'])): ?>
                                            <a href="?<?= $output['address'] ?>"><?= $output['address'] ?></a>
                                        <?php else: ?>
                                            <?= $output['address'] ?>
                                        <?php endif; ?>
                                    </div>
                                    <div style="font-size: 11px; color: var(--text-secondary);">
                                        #<?= $output['n'] ?> (<?= $output['type'] ?>)
                                    </div>
                                </td>
                                <td style="text-align: right;">
                                    <?= number_format($output['value'], 8) ?>
                                    <span class="asset-badge <?= $output['asset_class'] ?? 'asset-m0' ?>"><?= $output['asset'] ?? 'M0' ?></span>
                                </td>
                            </tr>
                            <?php endforeach; ?>
                            <tr style="background: var(--bg-tertiary);">
                                <td><strong>Total</strong></td>
                                <td><strong><?= number_format($data['total_out'], 8) ?> <?= COIN_TICKER ?></strong></td>
                            </tr>
                        </tbody>
                    </table>
                </div>
            </div>

            <div class="pagination">
                <?php if ($data['blockinfo']): ?>
                    <a href="?<?= $data['blockinfo']['hash'] ?>">&larr; Back to Block #<?= $data['blockinfo']['height'] ?></a>
                <?php endif; ?>
                <a href="./">&larr; Back to blocks</a>
            </div>

        <?php elseif ($page === 'address'): ?>
            <!-- Address Details -->
            <div class="card">
                <div class="card-header">Address Details</div>
                <div class="detail-grid">
                    <div class="label">Address</div>
                    <div class="value"><?= htmlspecialchars($data['address']) ?></div>

                    <div class="label">Balance (last <?= $data['blocks_scanned'] ?> blocks)</div>
                    <div class="value" style="color: var(--success);"><?= number_format($data['balance'], 8) ?> <?= COIN_TICKER ?></div>

                    <div class="label">Total Received</div>
                    <div class="value"><?= number_format($data['total_received'], 8) ?> <?= COIN_TICKER ?></div>

                    <div class="label">Total Sent</div>
                    <div class="value"><?= number_format($data['total_sent'], 8) ?> <?= COIN_TICKER ?></div>

                    <div class="label">Transactions</div>
                    <div class="value"><?= $data['tx_count'] ?></div>
                </div>
            </div>

            <!-- Transaction History -->
            <div class="card">
                <div class="card-header">
                    Recent Transactions (<?= count($data['transactions']) ?>)
                    <span style="color: var(--text-secondary); font-weight: normal; font-size: 12px;">
                        Scanned last <?= $data['blocks_scanned'] ?> blocks
                    </span>
                </div>
                <?php if (empty($data['transactions'])): ?>
                    <div style="padding: 20px; color: var(--text-secondary);">
                        No transactions found in the last <?= $data['blocks_scanned'] ?> blocks.
                    </div>
                <?php else: ?>
                    <table>
                        <thead>
                            <tr>
                                <th>Transaction</th>
                                <th>Block</th>
                                <th>Time</th>
                                <th>Received</th>
                                <th>Sent</th>
                                <th>Net</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php foreach ($data['transactions'] as $tx): ?>
                            <tr>
                                <td class="hash truncate" style="max-width: 150px;">
                                    <a href="?<?= $tx['txid'] ?>"><?= substr($tx['txid'], 0, 16) ?>...</a>
                                </td>
                                <td><?= number_format($tx['height']) ?></td>
                                <td><?= date('Y-m-d H:i', $tx['time']) ?></td>
                                <td style="color: var(--success);">
                                    <?php if ($tx['received'] > 0): ?>
                                        +<?= number_format($tx['received'], 8) ?>
                                    <?php else: ?>
                                        -
                                    <?php endif; ?>
                                </td>
                                <td style="color: #f85149;">
                                    <?php if ($tx['sent'] > 0): ?>
                                        -<?= number_format($tx['sent'], 8) ?>
                                    <?php else: ?>
                                        -
                                    <?php endif; ?>
                                </td>
                                <td style="color: <?= $tx['net'] >= 0 ? 'var(--success)' : '#f85149' ?>;">
                                    <?= $tx['net'] >= 0 ? '+' : '' ?><?= number_format($tx['net'], 8) ?>
                                </td>
                            </tr>
                            <?php endforeach; ?>
                        </tbody>
                    </table>
                <?php endif; ?>
            </div>

            <div class="pagination">
                <a href="./">&larr; Back to blocks</a>
            </div>

        <?php elseif ($page === 'operators'): ?>
            <!-- Operators Stats -->
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="label">Total Operators</div>
                    <div class="value accent"><?= count($data['operators']) ?></div>
                </div>
                <div class="stat-card">
                    <div class="label">Active MNs</div>
                    <div class="value"><?= $data['network']['masternodes_active'] ?></div>
                </div>
                <div class="stat-card">
                    <div class="label">Total MNs</div>
                    <div class="value"><?= $data['network']['masternodes_total'] ?></div>
                </div>
                <div class="stat-card">
                    <div class="label">Block Height</div>
                    <div class="value"><?= number_format($data['network']['blocks']) ?></div>
                </div>
            </div>

            <!-- Operator List -->
            <div class="card">
                <div class="card-header">
                    <span>Operator List (v4.0 Operator-Centric)</span>
                    <span style="color: var(--text-secondary); font-weight: normal; font-size: 14px;">
                        <?= count($data['operators']) ?> operators managing <?= $data['network']['masternodes_total'] ?> MNs
                    </span>
                </div>
                <?php if (empty($data['operators'])): ?>
                    <div style="padding: 20px; color: var(--text-secondary);">
                        No operators registered.
                    </div>
                <?php else: ?>
                    <table id="op-table">
                        <thead>
                            <tr>
                                <th class="sortable" data-sort="rank">#</th>
                                <th>Operator Key</th>
                                <th class="sortable sort-desc" data-sort="mns">MNs</th>
                                <th class="sortable" data-sort="online">Online</th>
                                <th>Badges</th>
                                <th class="sortable" data-sort="grants">Grants</th>
                                <th class="sortable" data-sort="votes">Votes</th>
                                <th class="sortable" data-sort="anciennete">Ancienneté</th>
                                <th class="sortable" data-sort="score">Score</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php $i = 1; foreach ($data['operators'] as $op): ?>
                            <tr data-rank="<?= $i ?>" data-mns="<?= $op['activeMNs'] ?>" data-online="<?= $op['onlineMNs'] ?>" data-grants="<?= $op['grantsAccepted'] ?>" data-votes="<?= $op['domcVotes'] + $op['grantVotes'] ?>" data-anciennete="<?= $op['ancienneteDays'] ?>" data-score="<?= $op['totalScore'] ?>">
                                <td><?= $i++ ?></td>
                                <td class="hash truncate" style="max-width: 140px;" title="<?= $op['operatorPubKey'] ?>">
                                    <?= substr($op['operatorPubKey'], 0, 12) ?>...<?= substr($op['operatorPubKey'], -6) ?>
                                </td>
                                <td style="text-align: center;">
                                    <span style="color: var(--success); font-weight: 600;"><?= $op['activeMNs'] ?></span>
                                    <?php if ($op['bannedMNs'] > 0): ?>
                                        <span style="color: #f85149; font-size: 10px;">+<?= $op['bannedMNs'] ?>ban</span>
                                    <?php endif; ?>
                                </td>
                                <td style="text-align: center;">
                                    <?php if ($op['onlineMNs'] == $op['activeMNs'] && $op['onlineMNs'] > 0): ?>
                                        <span class="badge-online"><?= $op['onlineMNs'] ?>/<?= $op['activeMNs'] ?></span>
                                    <?php elseif ($op['onlineMNs'] > 0): ?>
                                        <span style="color: var(--warning);"><?= $op['onlineMNs'] ?>/<?= $op['activeMNs'] ?></span>
                                    <?php else: ?>
                                        <span class="badge-offline">0/<?= $op['activeMNs'] ?></span>
                                    <?php endif; ?>
                                </td>
                                <td style="font-size: 10px;">
                                    <?php if (!empty($op['badges'])): ?>
                                        <?php foreach ($op['badges'] as $badge): ?>
                                            <span class="badge badge-<?= strtolower(str_replace('_', '-', $badge)) ?>" style="background: var(--accent); color: white; margin: 1px;"><?= htmlspecialchars($badge) ?></span>
                                        <?php endforeach; ?>
                                    <?php else: ?>
                                        <span style="color: var(--text-secondary);">-</span>
                                    <?php endif; ?>
                                </td>
                                <td style="text-align: center; font-size: 12px;">
                                    <?php if ($op['grantsPublished'] > 0 || $op['grantsAccepted'] > 0): ?>
                                        <span style="color: var(--success);" title="Accepted"><?= $op['grantsAccepted'] ?></span>/<span title="Published"><?= $op['grantsPublished'] ?></span>
                                    <?php else: ?>
                                        <span style="color: var(--text-secondary);">0</span>
                                    <?php endif; ?>
                                </td>
                                <td style="text-align: center; font-size: 12px;">
                                    <?php $totalVotes = $op['domcVotes'] + $op['grantVotes']; ?>
                                    <?php if ($totalVotes > 0): ?>
                                        <span title="DOMC: <?= $op['domcVotes'] ?>, Grants: <?= $op['grantVotes'] ?>"><?= $totalVotes ?></span>
                                    <?php else: ?>
                                        <span style="color: var(--text-secondary);">0</span>
                                    <?php endif; ?>
                                </td>
                                <td style="font-size: 12px;">
                                    <?php if ($op['ancienneteDays'] > 0): ?>
                                        <?= $op['ancienneteDays'] ?>j
                                    <?php else: ?>
                                        <span style="color: var(--text-secondary);">Genesis</span>
                                    <?php endif; ?>
                                </td>
                                <td style="text-align: center;">
                                    <span style="color: var(--accent-light); font-weight: 600;">
                                        <?= number_format($op['totalScore']) ?>
                                    </span>
                                </td>
                            </tr>
                            <?php endforeach; ?>
                        </tbody>
                    </table>
                <?php endif; ?>
            </div>

            <!-- Note about operator-centric model -->
            <div class="card" style="margin-top: 20px;">
                <div class="card-header">About Operator-Centric Model (v4.0)</div>
                <div style="padding: 20px; color: var(--text-secondary); font-size: 14px; line-height: 1.8;">
                    <p><strong>Identity = Operator Public Key</strong></p>
                    <p>In BATHRON v4.0, operators are the primary identity for governance:</p>
                    <ul style="margin-left: 20px; margin-top: 10px;">
                        <li><strong>1 Operator = 1 Vote</strong> - Regardless of how many MNs they manage</li>
                        <li><strong>Batch Voting</strong> - 1 signature covers all MNs for consensus weight</li>
                        <li><strong>Score per Operator</strong> - Small operators can catch up to large ones</li>
                        <li><strong>Multi-MN Daemon</strong> - Run multiple MNs on a single server</li>
                    </ul>
                </div>
            </div>

        <?php elseif ($page === 'masternodes'): ?>
            <!-- MASTERNODES LIST (Individual MNs) -->
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="label">Active MNs</div>
                    <div class="value accent"><?= $data['network']['masternodes_active'] ?></div>
                </div>
                <div class="stat-card">
                    <div class="label">Total MNs</div>
                    <div class="value"><?= $data['network']['masternodes_total'] ?></div>
                </div>
                <div class="stat-card">
                    <div class="label">Total Collateral</div>
                    <div class="value"><?= number_format($data['network']['masternodes_total'] * 10000) ?> PIV</div>
                </div>
                <div class="stat-card">
                    <div class="label">Block Height</div>
                    <div class="value"><?= number_format($data['network']['blocks']) ?></div>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <span>Masternode List</span>
                    <span style="color: var(--text-secondary); font-weight: normal; font-size: 14px;">
                        Individual masternodes (see <a href="?tab=operators">Operators</a> for grouped view)
                    </span>
                </div>
                <?php if (empty($data['masternodes'])): ?>
                    <div style="padding: 20px; color: var(--text-secondary);">
                        No masternodes registered.
                    </div>
                <?php else: ?>
                    <table id="mn-table">
                        <thead>
                            <tr>
                                <th>#</th>
                                <th>Collateral</th>
                                <th>Operator</th>
                                <th>Service IP</th>
                                <th>Status</th>
                                <th>Last Paid</th>
                                <th>Ancienneté</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php $i = 1; foreach ($data['masternodes'] as $mn):
                                $anciennete = $data['network']['blocks'] - $mn['registeredHeight'];
                            ?>
                            <tr>
                                <td><?= $i++ ?></td>
                                <td class="hash truncate" style="max-width: 120px;" title="<?= $mn['collateralAddress'] ?>">
                                    <a href="?q=<?= $mn['collateralAddress'] ?>"><?= substr($mn['collateralAddress'], 0, 12) ?>...</a>
                                </td>
                                <td class="hash truncate" style="max-width: 100px;" title="<?= $mn['operatorPubKey'] ?>">
                                    <?= substr($mn['operatorPubKey'], 0, 10) ?>...
                                </td>
                                <td style="font-size: 12px;"><?= htmlspecialchars($mn['service']) ?></td>
                                <td>
                                    <?php if ($mn['status'] === 'ENABLED'): ?>
                                        <span class="status-enabled"><?= $mn['status'] ?></span>
                                    <?php elseif ($mn['status'] === 'POSE_PENALTY'): ?>
                                        <span class="status-penalty"><?= $mn['status'] ?></span>
                                    <?php else: ?>
                                        <span class="status-banned"><?= $mn['status'] ?></span>
                                    <?php endif; ?>
                                </td>
                                <td style="font-size: 12px;">
                                    <?php if ($mn['lastPaidHeight'] > 0): ?>
                                        Block <?= number_format($mn['lastPaidHeight']) ?>
                                    <?php else: ?>
                                        <span style="color: var(--text-secondary);">Never</span>
                                    <?php endif; ?>
                                </td>
                                <td style="text-align: center;">
                                    <span style="color: var(--text-secondary);">
                                        <?= number_format($anciennete) ?> blocs
                                    </span>
                                </td>
                            </tr>
                            <?php endforeach; ?>
                        </tbody>
                    </table>
                <?php endif; ?>
            </div>

        <?php elseif ($page === 'grants'): ?>
            <!-- DAO GRANTS -->
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="label">Treasury Balance</div>
                    <div class="value accent"><?= number_format($data['dao']['treasury_balance'] ?? 0, 2) ?> PIV</div>
                </div>
                <div class="stat-card">
                    <div class="label">Next Payout</div>
                    <div class="value">Block <?= number_format($data['dao']['next_payout_block'] ?? 0) ?></div>
                </div>
                <div class="stat-card">
                    <div class="label">Total Granted</div>
                    <div class="value"><?= number_format($data['dao']['total_granted'] ?? 0, 2) ?> PIV</div>
                </div>
                <div class="stat-card">
                    <div class="label">Total Burned</div>
                    <div class="value"><?= number_format($data['dao']['total_burned'] ?? 0, 2) ?> PIV</div>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <span>Grant Proposals</span>
                    <span style="color: var(--text-secondary); font-weight: normal; font-size: 14px;">
                        DAO Treasury funded by <?= $data['network']['state_t'] ?? 0 ?> PIV
                    </span>
                </div>
                <?php if (empty($data['grants'])): ?>
                    <div style="padding: 20px; color: var(--text-secondary);">
                        No grant proposals found. Submit one with <code>daogrant_submit</code> RPC.
                    </div>
                <?php else: ?>
                    <table>
                        <thead>
                            <tr>
                                <th>#</th>
                                <th>Proposal</th>
                                <th>Amount</th>
                                <th>Commits</th>
                                <th>Quorum</th>
                                <th>Status</th>
                                <th>Prediction</th>
                                <th>Timeline</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php $i = 1; foreach ($data['grants'] as $grant): ?>
                            <?php
                                // Parse amount (remove " PIV" suffix if present)
                                $amountStr = $grant['amount'] ?? '0';
                                $amount = floatval(str_replace([',', ' PIV'], '', $amountStr));

                                // Get status and set color
                                $status = strtoupper($grant['status'] ?? 'unknown');
                                $statusColor = $status === 'APPROVED' ? 'var(--success)' :
                                              ($status === 'REJECTED' ? '#f85149' :
                                              ($status === 'COMMIT' ? 'var(--accent)' : 'var(--warning)'));

                                // Get commits and quorum info (from enhanced RPC)
                                $commits = $grant['commits'] ?? 0;  // Operators count
                                $committedMNs = $grant['committedMNs'] ?? 0;  // Total MNs count
                                $quorumRequired = $grant['quorumRequired'] ?? 1;
                                $matureMnCount = $grant['matureMnCount'] ?? 8;
                                $quorumMet = $grant['quorumMet'] ?? false;
                                $blocksRemaining = $grant['blocksRemaining'] ?? 0;

                                // Get vote results (after finalization)
                                $yesVotes = $grant['yesVotes'] ?? 0;
                                $noVotes = $grant['noVotes'] ?? 0;
                                $totalVotes = $grant['totalVotes'] ?? 0;
                                $reveals = $grant['reveals'] ?? 0;
                                $isFinalized = in_array($status, ['APPROVED', 'REJECTED']);

                                // Get prediction
                                $prediction = $grant['prediction'] ?? 'pending';
                                $predictionColors = [
                                    'passed' => 'var(--success)',
                                    'likely_pass' => 'var(--success)',
                                    'rejected' => '#f85149',
                                    'likely_fail' => '#f85149',
                                    'needs_quorum' => 'var(--warning)',
                                    'awaiting_reveal' => 'var(--accent)',  // Quorum met, waiting
                                    'voting' => 'var(--text-primary)',     // Still collecting votes
                                    'pending' => 'var(--text-secondary)'
                                ];
                                $predictionLabels = [
                                    'passed' => 'PASSED',
                                    'rejected' => 'REJECTED',
                                    'likely_pass' => 'Likely Pass',
                                    'likely_fail' => 'Likely Fail',
                                    'needs_quorum' => 'Needs Quorum',
                                    'awaiting_reveal' => 'Awaiting Reveal',
                                    'voting' => 'Voting...',
                                    'pending' => 'Pending'
                                ];
                                $predictionColor = $predictionColors[$prediction] ?? 'var(--text-secondary)';
                                $predictionLabel = $predictionLabels[$prediction] ?? 'Pending';

                                // Get URL and create display title
                                $url = $grant['proposalUrl'] ?? '';
                                $displayTitle = $url ? basename(parse_url($url, PHP_URL_PATH)) : substr($grant['hash'] ?? '', 0, 12) . '...';
                            ?>
                            <tr>
                                <td><?= $i++ ?></td>
                                <td>
                                    <?php if ($url): ?>
                                        <a href="<?= htmlspecialchars($url) ?>" target="_blank" rel="noopener"
                                           style="color: var(--accent); text-decoration: none;"
                                           title="<?= htmlspecialchars($url) ?>">
                                            <?= htmlspecialchars($displayTitle) ?>
                                        </a>
                                    <?php else: ?>
                                        <span title="<?= htmlspecialchars($grant['hash'] ?? '') ?>">
                                            <?= htmlspecialchars($displayTitle) ?>
                                        </span>
                                    <?php endif; ?>
                                </td>
                                <td><strong><?= number_format($amount, 2) ?></strong> PIV</td>
                                <td style="text-align: center;" title="<?= $commits ?> operator(s), <?= $committedMNs ?> MN(s)">
                                    <?php if ($isFinalized): ?>
                                        <!-- After finalization: show YES/NO vote results -->
                                        <span style="color: var(--success); font-weight: bold;"><?= $yesVotes ?> YES</span>
                                        <span style="color: var(--text-secondary);"> / </span>
                                        <span style="color: #f85149; font-weight: bold;"><?= $noVotes ?> NO</span>
                                    <?php else: ?>
                                        <!-- During voting: show commit count -->
                                        <span style="color: <?= $committedMNs > 0 ? 'var(--success)' : 'var(--text-primary)' ?>;">
                                            <?= $committedMNs ?> MNs
                                        </span>
                                        <span style="color: var(--text-secondary); font-size: 11px;">
                                            (<?= $commits ?> ops)
                                        </span>
                                    <?php endif; ?>
                                </td>
                                <td style="text-align: center; font-size: 12px;">
                                    <?php if ($isFinalized): ?>
                                        <!-- After finalization: show total votes and pass % -->
                                        <?php $passPercent = $totalVotes > 0 ? round(($yesVotes / $totalVotes) * 100) : 0; ?>
                                        <span style="color: <?= $passPercent > 50 ? 'var(--success)' : '#f85149' ?>; font-weight: bold;">
                                            <?= $passPercent ?>%
                                        </span>
                                        <span style="color: var(--text-secondary);"> (<?= $totalVotes ?> votes)</span>
                                    <?php elseif ($quorumMet): ?>
                                        <span style="color: var(--success);">&#10003; <?= $committedMNs ?>/<?= $matureMnCount ?></span>
                                    <?php else: ?>
                                        <span style="color: var(--warning);"><?= $committedMNs ?>/<?= $quorumRequired ?></span>
                                        <span style="color: var(--text-secondary);"> (10%)</span>
                                    <?php endif; ?>
                                </td>
                                <td>
                                    <span style="color: <?= $statusColor ?>; font-weight: bold;"><?= $status ?></span>
                                </td>
                                <td style="text-align: center;">
                                    <span style="color: <?= $predictionColor ?>; font-weight: bold; font-size: 12px;">
                                        <?= $predictionLabel ?>
                                    </span>
                                </td>
                                <td style="font-size: 12px; color: var(--text-secondary);">
                                    <?php
                                    $currentHeight = $grant['currentHeight'] ?? 0;
                                    $revealHeight = $grant['nRevealHeight'] ?? 0;
                                    $paymentHeight = $grant['nPaymentHeight'] ?? 0;
                                    $finalizeHeight = $revealHeight + 10; // Reveal window is 10 blocks

                                    if ($status === 'COMMIT'):
                                        if ($currentHeight >= $revealHeight && $currentHeight < $finalizeHeight):
                                            // In reveal window
                                            $blocksToFinalize = $finalizeHeight - $currentHeight;
                                    ?>
                                            <span style="color: var(--accent);">REVEAL WINDOW</span>
                                            <span style="font-size: 10px;">(<?= $blocksToFinalize ?> blocs)</span>
                                        <?php elseif ($blocksRemaining > 0): ?>
                                            <?= number_format($blocksRemaining) ?> blocs
                                            <span style="font-size: 10px;">(~<?= round($blocksRemaining / 60, 1) ?>h)</span>
                                        <?php else: ?>
                                            Finalize @ <?= number_format($finalizeHeight) ?>
                                        <?php endif; ?>
                                    <?php elseif ($status === 'APPROVED'): ?>
                                        <span style="color: var(--success);">&#10003;</span> Paid @ <?= number_format($paymentHeight) ?>
                                    <?php elseif ($status === 'REJECTED'): ?>
                                        <span style="color: #f85149;">&#10007;</span> Finalized @ <?= number_format($finalizeHeight) ?>
                                    <?php else: ?>
                                        Ended
                                    <?php endif; ?>
                                </td>
                            </tr>
                            <?php endforeach; ?>
                        </tbody>
                    </table>
                <?php endif; ?>
            </div>

            <!-- DAO Info -->
            <div class="card" style="margin-top: 20px;">
                <div class="card-header">About DAO Grants</div>
                <div style="padding: 20px; color: var(--text-secondary); font-size: 14px; line-height: 1.8;">
                    <p><strong>Decentralized Treasury System</strong></p>
                    <p>The BATHRON 2.0 DAO allows masternode operators to propose and vote on funding:</p>
                    <ul style="margin-left: 20px; margin-top: 10px;">
                        <li><strong>Fee:</strong> 50 PIV to submit (refunded if approved)</li>
                        <li><strong>Quorum:</strong> 10% of mature MNs must vote</li>
                        <li><strong>Threshold:</strong> >50% approval to pass</li>
                        <li><strong>Voting:</strong> Commit/Reveal system (hidden votes via OP_RETURN)</li>
                        <li><strong>Timeline:</strong> COMMIT (1440 blocs) → REVEAL (10 blocs) → PAYMENT</li>
                        <li><strong>1 MN = 1 Vote</strong> (Multi-MN operators vote in batch)</li>
                    </ul>
                    <p style="margin-top: 15px;"><strong>Timeline (Testnet)</strong></p>
                    <ul style="margin-left: 20px; margin-top: 5px;">
                        <li><strong>COMMIT phase:</strong> ~1 day (1,440 blocks)</li>
                        <li><strong>REVEAL instant:</strong> Votes counted at reveal height</li>
                        <li><strong>PAYMENT:</strong> 1 block after reveal if approved</li>
                    </ul>
                </div>
            </div>

        <?php elseif ($page === 'domc'): ?>
            <!-- DOMC (Yield Rate Governance) -->
            <?php
            $domc = $data['domc'];
            $phase = $domc['phase'];
            $isActive = $phase === 'active';
            $isCommit = $phase === 'commit';
            $isReveal = $phase === 'reveal';
            $isAdapt = in_array($phase, ['adapt', 'finalize']);
            $isExecute = in_array($phase, ['execute', 'activate']);
            $isVoting = $isCommit || $isReveal;  // Vote en cours
            ?>
            <div class="stats-grid">
                <div class="stat-card">
                    <div class="label">Current R%</div>
                    <div class="value accent"><?= number_format($domc['current_r'], 2) ?>%</div>
                </div>
                <div class="stat-card">
                    <div class="label">Next R%</div>
                    <?php if ($isVoting): ?>
                        <div class="value" style="color: var(--text-secondary);">?</div>
                        <div style="font-size: 11px; color: var(--text-secondary);">Vote en cours</div>
                    <?php else: ?>
                        <div class="value"><?= number_format($domc['next_r'], 2) ?>%</div>
                        <div style="font-size: 10px; color: var(--text-secondary);">si aucun vote ce cycle</div>
                    <?php endif; ?>
                </div>
                <div class="stat-card">
                    <div class="label">R% Votable</div>
                    <div class="value"><?= $domc['r_min'] ?>% - <?= $domc['r_max'] ?>%</div>
                    <div style="font-size: 10px; color: var(--text-secondary);">Max -1%/an → <?= $domc['r_floor'] ?>%</div>
                </div>
                <div class="stat-card">
                    <div class="label">Cycle Length</div>
                    <div class="value"><?= number_format($domc['cycle_length']) ?> blocs</div>
                    <div style="font-size: 10px; color: var(--text-secondary);">~<?= round($domc['cycle_length'] / 60, 1) ?> heures</div>
                </div>
            </div>

            <div class="card">
                <div class="card-header">
                    <span>Current DOMC Cycle</span>
                    <span style="color: var(--text-secondary); font-weight: normal; font-size: 14px;">
                        Phase: <?= strtoupper($phase) ?>
                    </span>
                </div>
                <div style="padding: 15px 20px; background: var(--bg-tertiary); border-bottom: 1px solid var(--border-color); display: flex; justify-content: space-between; align-items: center;">
                    <div>
                        <span style="color: var(--text-secondary);">Bloc actuel:</span>
                        <span style="font-weight: 600; color: var(--accent); margin-left: 8px;"><?= number_format($domc['height']) ?></span>
                    </div>
                    <div>
                        <span style="color: var(--text-secondary);">Fin du cycle:</span>
                        <span style="font-weight: 600; margin-left: 8px;"><?= number_format($domc['height'] + $domc['blocks_to_cycle_end']) ?></span>
                    </div>
                </div>
                <?php
                // Calculations
                $commitOffset = round($domc['cycle_length'] * 240 / 360);
                $blocksToNextCommit = $domc['blocks_to_cycle_end'] + $commitOffset;
                $cycleLength = $domc['cycle_length'];
                $progress = max(0, min(100, (($cycleLength - $domc['blocks_to_cycle_end']) / $cycleLength) * 100));
                $activeBlocks = round($cycleLength * 240 / 360);
                $commitBlocks = round($cycleLength * 60 / 360);
                $revealBlocks = round($cycleLength * 50 / 360);
                // Target block numbers for single-block events
                $cycleStart = $domc['height'] - ($cycleLength - $domc['blocks_to_cycle_end'] - 1);
                $finalizeBlock = $domc['height'] + $domc['blocks_to_reveal_end'];
                $activateBlock = $domc['height'] + $domc['blocks_to_activate'];
                ?>
                <div style="display: flex;">
                    <!-- Main content (left) -->
                    <div style="flex: 1; padding: 20px; border-right: 1px solid var(--border-color);">
                        <!-- Row 1: Countdowns -->
                        <div style="display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px; margin-bottom: 10px;">
                            <div style="text-align: center; padding: 12px 8px; background: var(--bg-tertiary); border-radius: 8px; <?= $isActive ? 'border: 2px solid var(--text-secondary);' : '' ?>">
                                <?php if ($isActive): ?>
                                <div style="font-size: 20px; font-weight: 700; color: var(--text-secondary);">EN COURS</div>
                                <div style="font-size: 10px; color: var(--text-secondary);"><?= number_format($domc['blocks_to_commit_start']) ?> → COMMIT</div>
                                <?php else: ?>
                                <div style="font-size: 24px; font-weight: 700; color: var(--text-secondary);">✓</div>
                                <div style="font-size: 10px; color: var(--text-secondary);">terminé</div>
                                <?php endif; ?>
                            </div>
                            <div style="text-align: center; padding: 12px 8px; background: var(--bg-tertiary); border-radius: 8px; <?= $isCommit ? 'border: 2px solid var(--accent);' : '' ?>">
                                <div style="font-size: 24px; font-weight: 700; color: var(--accent);"><?= number_format($domc['blocks_to_commit_start']) ?></div>
                                <div style="font-size: 10px; color: var(--text-secondary);">→ COMMIT</div>
                            </div>
                            <div style="text-align: center; padding: 12px 8px; background: var(--bg-tertiary); border-radius: 8px; <?= $isReveal ? 'border: 2px solid var(--accent-light);' : '' ?>">
                                <div style="font-size: 24px; font-weight: 700; color: var(--accent-light);"><?= number_format($domc['blocks_to_commit_end']) ?></div>
                                <div style="font-size: 10px; color: var(--text-secondary);">→ REVEAL</div>
                            </div>
                            <div style="text-align: center; padding: 12px 8px; background: var(--bg-tertiary); border-radius: 8px; <?= $isAdapt ? 'border: 2px solid var(--success);' : '' ?>">
                                <div style="font-size: 24px; font-weight: 700; color: var(--success);"><?= number_format($domc['blocks_to_reveal_end']) ?></div>
                                <div style="font-size: 10px; color: var(--text-secondary);">→ FINALIZE</div>
                            </div>
                            <div style="text-align: center; padding: 12px 8px; background: var(--bg-tertiary); border-radius: 8px; <?= $isExecute ? 'border: 2px solid var(--warning);' : '' ?>">
                                <div style="font-size: 24px; font-weight: 700; color: var(--warning);"><?= number_format($domc['blocks_to_activate']) ?></div>
                                <div style="font-size: 10px; color: var(--text-secondary);">→ ACTIVATE</div>
                            </div>
                        </div>

                        <!-- Progress bar in middle -->
                        <div style="margin-bottom: 10px;">
                            <div style="background: var(--bg-tertiary); border-radius: 4px; height: 8px; overflow: hidden;">
                                <div style="background: linear-gradient(90deg, var(--text-secondary) 0%, var(--accent) 67%, var(--accent-light) 83%, var(--success) 97%, var(--warning) 100%); width: <?= $progress ?>%; height: 100%;"></div>
                            </div>
                            <div style="font-size: 11px; color: var(--text-secondary); text-align: center; margin-top: 4px;"><?= number_format($progress, 1) ?>% du cycle</div>
                        </div>

                        <!-- Row 2: Phase names -->
                        <div style="display: grid; grid-template-columns: repeat(5, 1fr); gap: 8px;">
                            <div style="text-align: center; padding: 8px; background: var(--bg-tertiary); border-radius: 8px; <?= $isActive ? 'border: 2px solid var(--text-secondary);' : '' ?>">
                                <div style="font-weight: 600; font-size: 12px; color: var(--text-secondary);">0. ACTIVE</div>
                                <div style="font-size: 10px; color: var(--text-secondary);">~<?= $activeBlocks ?> blocs</div>
                            </div>
                            <div style="text-align: center; padding: 8px; background: var(--bg-tertiary); border-radius: 8px; <?= $isCommit ? 'border: 2px solid var(--accent);' : '' ?>">
                                <div style="font-weight: 600; font-size: 12px; color: var(--accent);">1. COMMIT</div>
                                <div style="font-size: 10px; color: var(--text-secondary);">~<?= $commitBlocks ?> blocs</div>
                            </div>
                            <div style="text-align: center; padding: 8px; background: var(--bg-tertiary); border-radius: 8px; <?= $isReveal ? 'border: 2px solid var(--accent-light);' : '' ?>">
                                <div style="font-weight: 600; font-size: 12px; color: var(--accent-light);">2. REVEAL</div>
                                <div style="font-size: 10px; color: var(--text-secondary);">~<?= $revealBlocks ?> blocs</div>
                            </div>
                            <div style="text-align: center; padding: 8px; background: var(--bg-tertiary); border-radius: 8px; <?= $isAdapt ? 'border: 2px solid var(--success);' : '' ?>">
                                <div style="font-weight: 600; font-size: 12px; color: var(--success);">3. FINALIZE</div>
                                <div style="font-size: 10px; color: var(--text-secondary);">@bloc <?= number_format($finalizeBlock) ?></div>
                            </div>
                            <div style="text-align: center; padding: 8px; background: var(--bg-tertiary); border-radius: 8px; <?= $isExecute ? 'border: 2px solid var(--warning);' : '' ?>">
                                <div style="font-weight: 600; font-size: 12px; color: var(--warning);">4. ACTIVATE</div>
                                <div style="font-size: 10px; color: var(--text-secondary);">@bloc <?= number_format($activateBlock) ?></div>
                            </div>
                        </div>

                    </div>

                    <!-- Next cycle sidebar (right) -->
                    <div style="width: 100px; padding: 20px 15px; display: flex; flex-direction: column; justify-content: center; align-items: center; background: var(--bg-tertiary);">
                        <div style="font-size: 28px; font-weight: 700; color: var(--accent);"><?= number_format($blocksToNextCommit) ?></div>
                        <div style="font-size: 11px; color: var(--text-secondary); text-align: center; margin-top: 5px;">→ COMMIT</div>
                        <div style="font-size: 10px; color: var(--text-secondary); opacity: 0.7;">cycle +1</div>
                    </div>
                </div>

                <!-- COMMIT Status Banner -->
                <div style="padding: 15px 20px; background: <?= $isCommit ? 'var(--accent)' : 'var(--bg-tertiary)' ?>; border-top: 1px solid var(--border-color); text-align: center;">
                    <?php if ($isCommit): ?>
                    <div style="font-size: 18px; font-weight: 700; color: var(--bg-primary);">🗳️ COMMIT en cours — Votez !</div>
                    <div style="font-size: 12px; color: var(--bg-secondary); margin-top: 4px;">
                        <?= number_format($domc['blocks_to_commit_end']) ?> blocs restants
                        <?php if ($domc['total_mns'] > 0): ?>
                        — <strong><?= $domc['commits_count'] ?>/<?= $domc['total_mns'] ?></strong> MNs ont voté
                        <?php endif; ?>
                    </div>
                    <?php else: ?>
                    <div style="font-size: 16px; font-weight: 600; color: var(--text-secondary);">COMMIT dans <span style="color: var(--accent); font-size: 20px;"><?= number_format($domc['blocks_to_commit_start']) ?></span> blocs</div>
                    <div style="font-size: 11px; color: var(--text-secondary); opacity: 0.7; margin-top: 4px;">~<?= round($domc['blocks_to_commit_start'] / 60, 1) ?>h (testnet)</div>
                    <?php endif; ?>
                </div>
            </div>

            <!-- DOMC Info -->
            <div class="card" style="margin-top: 20px;">
                <div class="card-header">About DOMC (Deterministic Operator Median Consensus)</div>
                <div style="padding: 20px; color: var(--text-secondary); font-size: 14px; line-height: 1.8;">
                    <p><strong>Decentralized Yield Rate Governance</strong></p>
                    <p>DOMC allows masternode operators to vote on the annual yield rate (R%):</p>
                    <ul style="margin-left: 20px; margin-top: 10px;">
                        <li><strong>R% Range:</strong> <?= $domc['r_min'] ?>% - <?= $domc['r_max'] ?>% (ceiling décroît <?= $domc['r_decay'] ?>%/an → <?= $domc['r_floor'] ?>%)</li>
                        <li><strong>Cycle (testnet):</strong> ~<?= round($domc['cycle_length'] / 60, 1) ?>h (<?= number_format($domc['cycle_length']) ?> blocs)</li>
                        <li><strong>Commit-Reveal:</strong> Prevents vote copying</li>
                        <li><strong>Median Vote:</strong> Resistant to manipulation</li>
                        <li><strong>Impact:</strong> Higher R% = more yield for M2 savers</li>
                    </ul>

                    <p style="margin-top: 20px;"><strong>Mainnet Parameters (prévus)</strong></p>
                    <ul style="margin-left: 20px; margin-top: 10px;">
                        <li><strong>Cycle:</strong> ~120 jours (172,800 blocs)</li>
                        <li><strong>ACTIVE:</strong> ~105 jours (151,200 blocs) - pas de vote</li>
                        <li><strong>COMMIT:</strong> ~10 jours (14,400 blocs) - votes chiffrés</li>
                        <li><strong>REVEAL:</strong> ~5 jours (7,100 blocs) - révélation</li>
                        <li><strong>FINALIZE/ACTIVATE:</strong> 50 derniers blocs</li>
                    </ul>

                    <p style="margin-top: 20px;"><strong>R% Ceiling Timeline (mainnet)</strong></p>
                    <ul style="margin-left: 20px; margin-top: 10px;">
                        <li><strong>Année 0:</strong> 40% max</li>
                        <li><strong>Année 10:</strong> 30% max</li>
                        <li><strong>Année 20:</strong> 20% max</li>
                        <li><strong>Année 33+:</strong> 7% max (plancher atteint)</li>
                    </ul>
                </div>
            </div>

        <?php endif; ?>
    </main>

    <footer>
        <div class="container">
            <?= COIN_NAME ?> Explorer | Powered by BATHRON 2.0 Core
        </div>
    </footer>

    <?php if ($page === 'operators'): ?>
    <script>
    // Sortable table for operators
    document.addEventListener('DOMContentLoaded', function() {
        const table = document.getElementById('op-table');
        if (!table) return;

        const headers = table.querySelectorAll('th.sortable');
        const tbody = table.querySelector('tbody');

        headers.forEach(header => {
            header.addEventListener('click', function() {
                const sortKey = this.dataset.sort;
                const isAsc = this.classList.contains('sort-asc');

                // Remove sort classes from all headers
                headers.forEach(h => h.classList.remove('sort-asc', 'sort-desc'));

                // Toggle sort direction
                this.classList.add(isAsc ? 'sort-desc' : 'sort-asc');

                // Sort rows
                const rows = Array.from(tbody.querySelectorAll('tr'));
                rows.sort((a, b) => {
                    let aVal = a.dataset[sortKey];
                    let bVal = b.dataset[sortKey];

                    // Numeric sort for these columns
                    if (['rank', 'mns', 'online', 'anciennete', 'score'].includes(sortKey)) {
                        aVal = parseFloat(aVal) || 0;
                        bVal = parseFloat(bVal) || 0;
                        return isAsc ? bVal - aVal : aVal - bVal;
                    }

                    // String sort
                    return isAsc ? bVal.localeCompare(aVal) : aVal.localeCompare(bVal);
                });

                // Re-append rows in new order
                rows.forEach(row => tbody.appendChild(row));
            });
        });
    });
    </script>
    <?php endif; ?>

</body>
</html>
