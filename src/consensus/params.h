// Copyright (c) 2009-2010 Satoshi Nakamoto
// Copyright (c) 2009-2016 The Bitcoin Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BATHRON_CONSENSUS_PARAMS_H
#define BATHRON_CONSENSUS_PARAMS_H

#include "amount.h"
#include "optional.h"
#include "uint256.h"
#include <map>
#include <string>
#include <vector>

namespace Consensus {

/**
 * Genesis Masternode entry for DMN bootstrap.
 * These MNs are injected into the DMN list at block 0 to enable DMM block production.
 *
 * Like ETH2/Cosmos, genesis MNs are defined in the initial state, not via transactions.
 * - No IP address: MNs announce their service address via P2P after launch
 * - No ProRegTx needed: their legitimacy comes from being in the genesis state
 * - Collateral is created at block 1 (premine) to their owner addresses
 */
struct GenesisMN {
    std::string ownerAddress;        // Owner address (receives 10k collateral at block 1)
    std::string operatorPubKey;      // Operator pubkey (hex, 33 bytes compressed ECDSA) - signs blocks
    std::string payoutAddress;       // Payout address (receives MN rewards)
    // Note: votingKey defaults to owner, IP announced via P2P
};

/**
* Index into Params.vUpgrades and NetworkUpgradeInfo
*
* Being array indices, these MUST be numbered consecutively.
*
* The order of these indices MUST match the order of the upgrades on-chain, as
* several functions depend on the enum being sorted.
*/
enum UpgradeIndex : uint32_t {
    BASE_NETWORK,
    UPGRADE_BIP65,
    UPGRADE_V3_4,
    UPGRADE_V4_0,
    UPGRADE_V5_0,
    UPGRADE_V5_2,
    UPGRADE_V5_3,
    UPGRADE_V5_5,
    UPGRADE_V5_6,
    UPGRADE_V6_0,
    UPGRADE_V7_0,        // OP_TEMPLATEVERIFY (CTV-lite covenants)
    UPGRADE_TESTDUMMY,
    // NOTE: Also add new upgrades to NetworkUpgradeInfo in upgrades.cpp
    MAX_NETWORK_UPGRADES
};

struct NetworkUpgrade {
    /**
     * The first protocol version which will understand the new consensus rules
     */
    int nProtocolVersion;

    /**
     * Height of the first block for which the new consensus rules will be active
     */
    int nActivationHeight;

    /**
     * Special value for nActivationHeight indicating that the upgrade is always active.
     * This is useful for testing, as it means tests don't need to deal with the activation
     * process (namely, faking a chain of somewhat-arbitrary length).
     *
     * New blockchains that want to enable upgrade rules from the beginning can also use
     * this value. However, additional care must be taken to ensure the genesis block
     * satisfies the enabled rules.
     */
    static constexpr int ALWAYS_ACTIVE = 0;

    /**
     * Special value for nActivationHeight indicating that the upgrade will never activate.
     * This is useful when adding upgrade code that has a testnet activation height, but
     * should remain disabled on mainnet.
     */
    static constexpr int NO_ACTIVATION_HEIGHT = -1;

    /**
     * The hash of the block at height nActivationHeight, if known. This is set manually
     * after a network upgrade activates.
     *
     * We use this in IsInitialBlockDownload to detect whether we are potentially being
     * fed a fake alternate chain. We use NU activation blocks for this purpose instead of
     * the checkpoint blocks, because network upgrades (should) have significantly more
     * scrutiny than regular releases. nMinimumChainWork MUST be set to at least the chain
     * work of this block, otherwise this detection will have false positives.
     */
    Optional<uint256> hashActivationBlock;
};

/**
 * Parameters that influence chain consensus.
 */
struct Params {
    uint256 hashGenesisBlock;
    // HU: Genesis coinbase maturity (minimal, since block reward = 0)
    // Only affects genesis outputs, no new coinbase after genesis
    static constexpr int HU_COINBASE_MATURITY = 10;
    CAmount nMaxMoneyOut;
    // HU: Masternode collateral amount (network-specific)
    CAmount nMNCollateralAmt;
    // HU: Block reward = 0 (supply from BTC burns only)
    CAmount nMNBlockReward;
    CAmount nNewMNBlockReward;

    // BP30 V6: Block reward = 0 (M0 supply from BTC burns only)

    int64_t nTargetTimespan;
    int64_t nTargetTimespanV2;
    int64_t nTargetSpacing;
    int nTimeSlotLength;

    // ═══════════════════════════════════════════════════════════════════════
    // BP30 Timing Parameters (network-specific)
    // ═══════════════════════════════════════════════════════════════════════

    // Blocks per day (for rate limiting, diagnostics)
    int nBlocksPerDay;

    // ═══════════════════════════════════════════════════════════════════════
    // HU DMM + Finality Parameters (network-specific)
    // ═══════════════════════════════════════════════════════════════════════

    // Block timing (informational, for timeout calculations)
    int nHuBlockTimeSeconds;        // Target block time (60s mainnet)

    // Quorum configuration
    int nHuQuorumSize;              // Number of MNs in HU quorum (12 mainnet)
    int nHuQuorumThreshold;         // Minimum signatures for finality (8 mainnet)
    int nHuQuorumRotationBlocks;    // Quorum rotation interval (12 mainnet)

    // DMM leader timeout
    int nHuLeaderTimeoutSeconds;    // Timeout before fallback to next MN (45s mainnet)
    int nHuFallbackRecoverySeconds; // Recovery window for fallback MNs (15s testnet/mainnet)

    // DMM Bootstrap phase - special rules for cold start
    // During bootstrap (height <= nDMMBootstrapHeight):
    // - Producer = always primary (scores[0]), no fallback slot calculation
    // - nTime = max(prevTime + 1, nNow) instead of slot-aligned time
    // This prevents timestamp issues when syncing a fresh chain from genesis
    int nDMMBootstrapHeight;        // Bootstrap phase height (5 testnet, 10 mainnet)

    // Reorg protection
    int nHuMaxReorgDepth;           // Max reorg depth before finality (12 mainnet)

    // ═══════════════════════════════════════════════════════════════════════
    // Cold Start / Stale Chain Recovery
    // ═══════════════════════════════════════════════════════════════════════
    // SECURITY: If the chain tip is older than this, allow DMM to bypass
    // normal sync requirements and produce blocks (cold start recovery).
    // Mainnet: 3600s (1h) - high security, attacker needs 1h+ network outage
    // Testnet: 600s (10min) - balanced for testing
    // Regtest: 60s - fast for automated tests
    int64_t nStaleChainTimeout;

    // BATHRON: spork system removed - see 03-SPORKS-MODERNIZATION blueprint
    // All features (Sapling, HU finality) are permanently active

    // Map with network updates
    NetworkUpgrade vUpgrades[MAX_NETWORK_UPGRADES];

    // DMN Genesis bootstrap - MNs to inject at block 0 for DMM to work
    std::vector<GenesisMN> genesisMNs;

    // ═══════════════════════════════════════════════════════════════════════
    // BTC SPV & Burn Parameters
    // ═══════════════════════════════════════════════════════════════════════
    // All burns (including pre-launch) detected by burn_claim_daemon.
    // No special genesis files - same flow for all burns.
    //
    // BURN_PREFIX: OP_RETURN prefix identifying BATHRON burns (e.g., "BATHRON1")
    // ═══════════════════════════════════════════════════════════════════════
    std::string burnPrefix;              // OP_RETURN prefix for burn detection (e.g., "BATHRON1")
    uint32_t burnScanVoutMin{0};         // Minimum vout index to scan for OP_RETURN (default: 0)
    uint32_t burnScanVoutMax{2};         // Maximum vout index to scan for OP_RETURN (default: 2)
    uint32_t burnScanBtcHeightStart{0};  // First BTC block height to scan for genesis burns
    uint32_t burnScanBtcHeightEnd{0};    // Last BTC block height to scan for genesis burns (inclusive)

    // Accessors for burn parameters
    const std::string& GetBurnPrefix() const { return burnPrefix; }
    std::pair<uint32_t, uint32_t> GetBurnScanVoutRange() const { return {burnScanVoutMin, burnScanVoutMax}; }
    std::pair<uint32_t, uint32_t> GetBurnScanBtcHeightRange() const { return {burnScanBtcHeightStart, burnScanBtcHeightEnd}; }

    int64_t TargetTimespan(const bool fV2 = true) const { return fV2 ? nTargetTimespanV2 : nTargetTimespan; }
    bool MoneyRange(const CAmount& nValue) const { return (nValue >= 0 && nValue <= nMaxMoneyOut); }
    bool IsTimeProtocolV2(const int nHeight) const { return NetworkUpgradeActive(nHeight, UPGRADE_V4_0); }

    // ═══════════════════════════════════════════════════════════════════════════
    // BATHRON Masternode Collateral Maturity
    // ═══════════════════════════════════════════════════════════════════════════
    // Prevents rapid MN registration/deregistration attacks on quorum
    // Values are set per-network in chainparams.cpp
    // ═══════════════════════════════════════════════════════════════════════════
    int nMasternodeCollateralMinConf{1};  // Default, overridden per network

    int MasternodeCollateralMinConf() const { return nMasternodeCollateralMinConf; }

    // ═══════════════════════════════════════════════════════════════════════════
    // BATHRON Masternode Collateral Maturity for DAO Votes
    // ═══════════════════════════════════════════════════════════════════════════
    // Minimum collateral age (in blocks) before MN can participate in DAO_GRANT votes
    // This prevents "pump & vote" attacks where someone creates MN just before vote
    // Mainnet: 43200 blocks (~30 days) | Testnet: 1440 blocks (~1 day) | Regtest: 10 blocks
    // ═══════════════════════════════════════════════════════════════════════════
    int nMasternodeVoteMaturityBlocks{1};  // Default, overridden per network

    int MasternodeVoteMaturityBlocks() const { return nMasternodeVoteMaturityBlocks; }

    int FutureBlockTimeDrift(const int nHeight) const
    {
        // HU: TimeV2 always active (14 seconds)
        if (IsTimeProtocolV2(nHeight)) return nTimeSlotLength - 1;
        // Fallback (shouldn't be reached in HU genesis chain)
        return nTimeSlotLength - 1;
    }

    bool IsValidBlockTimeStamp(const int64_t nTime, const int nHeight) const
    {
        // Before time protocol V2, blocks can have arbitrary timestamps
        if (!IsTimeProtocolV2(nHeight)) return true;
        // Time protocol v2 requires time in slots
        return (nTime % nTimeSlotLength) == 0;
    }

    /**
     * Returns true if the given network upgrade is active as of the given block
     * height. Caller must check that the height is >= 0 (and handle unknown
     * heights).
     */
    bool NetworkUpgradeActive(int nHeight, Consensus::UpgradeIndex idx) const;
};
} // namespace Consensus

#endif // BATHRON_CONSENSUS_PARAMS_H
