// Copyright (c) 2025 The PIVHU Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef PIVHU_HU_FINALITY_H
#define PIVHU_HU_FINALITY_H

#include "dbwrapper.h"
#include "serialize.h"
#include "sync.h"
#include "uint256.h"

#include <map>
#include <vector>

class CBlockIndex;

/**
 * HU Finality System - ECDSA-based block finality
 *
 * Quorum configuration per network (from consensus params):
 * - Mainnet: 12/8 (12 MNs, 8 signatures for finality)
 * - Testnet: 3/2 (3 MNs, 2 signatures for finality)
 * - Regtest: 1/1 (1 MN, 1 signature for finality)
 *
 * Parameters are network-specific and read from Consensus::Params:
 * - nHuQuorumSize: Number of MNs in quorum
 * - nHuQuorumThreshold: Minimum signatures for finality
 * - nHuQuorumRotationBlocks: Blocks per quorum cycle
 * - nHuLeaderTimeoutSeconds: DMM leader timeout
 * - nHuMaxReorgDepth: Max reorg depth before finality enforcement
 */

namespace hu {

// NOTE: These legacy constants are kept for backward compatibility
// but all new code should use Consensus::Params from Params().GetConsensus()
// Access via: const Consensus::Params& consensus = Params().GetConsensus();
//             consensus.nHuQuorumSize, consensus.nHuQuorumThreshold, etc.
static const int HU_QUORUM_SIZE_DEFAULT = 12;           // Default for mainnet
static const int HU_FINALITY_THRESHOLD_DEFAULT = 8;     // Default for mainnet
static const int HU_CYCLE_LENGTH_DEFAULT = 12;          // Default rotation
static const int HU_FINALITY_DEPTH_DEFAULT = 12;        // Default max reorg
static const int DMM_LEADER_TIMEOUT_SECONDS_DEFAULT = 45; // Default timeout

/**
 * Single HU signature for a block
 */
struct CHuSignature {
    uint256 blockHash;
    uint256 proTxHash;          // Signing MN's proTxHash
    std::vector<unsigned char> vchSig;  // ECDSA signature

    SERIALIZE_METHODS(CHuSignature, obj)
    {
        READWRITE(obj.blockHash, obj.proTxHash, obj.vchSig);
    }
};

/**
 * HU Finality data for a block
 * Stores all collected signatures
 *
 * IMPORTANT: Quorum threshold is based on UNIQUE OPERATORS, not MN count.
 * A single operator running multiple MNs only counts as ONE signature.
 * This prevents a single operator from reaching quorum alone.
 */
class CFinalityManager {
public:
    uint256 blockHash;
    int nHeight{0};
    std::map<uint256, std::vector<unsigned char>> mapSignatures; // proTxHash -> sig

    CFinalityManager() = default;
    explicit CFinalityManager(const uint256& hash, int height) : blockHash(hash), nHeight(height) {}

    /**
     * Check if block has reached finality threshold
     * @param nThreshold - from consensus.nHuQuorumThreshold (8/2/1 per network)
     *
     * NOTE: This counts UNIQUE OPERATORS, not raw signature count.
     * Use GetUniqueOperatorCount() for the actual operator count.
     */
    bool HasFinality(int nThreshold) const;  // Implemented in finality.cpp

    // Backward compatibility - uses default threshold (mainnet)
    bool HasFinality() const { return HasFinality(HU_FINALITY_THRESHOLD_DEFAULT); }

    size_t GetSignatureCount() const { return mapSignatures.size(); }

    /**
     * Get count of unique operators who have signed
     * Looks up each proTxHash in MN list to get operator pubkey
     */
    size_t GetUniqueOperatorCount() const;  // Implemented in finality.cpp

    SERIALIZE_METHODS(CFinalityManager, obj)
    {
        READWRITE(obj.blockHash, obj.nHeight, obj.mapSignatures);
    }
};

/**
 * HU Finality Handler
 * Manages finality signatures and enforcement
 */
class CFinalityManagerHandler {
private:
    mutable RecursiveMutex cs;
    std::map<uint256, CFinalityManager> mapFinality;  // blockHash -> finality data
    std::map<int, uint256> mapHeightToBlock;     // height -> blockHash (for quick lookup)

public:
    CFinalityManagerHandler() = default;

    /**
     * Check if a block has HU finality (≥8 signatures)
     */
    bool HasFinality(int nHeight, const uint256& blockHash) const;

    /**
     * Check if accepting a block at given height/hash would conflict
     * with an already-finalized block
     */
    bool HasConflictingFinality(int nHeight, const uint256& blockHash) const;

    /**
     * Add a signature to a block's finality data
     * @return true if signature was new and valid
     */
    bool AddSignature(const CHuSignature& sig);

    /**
     * Get finality data for a block
     */
    bool GetFinality(const uint256& blockHash, CFinalityManager& finalityOut) const;

    /**
     * Get signature count for a block
     */
    int GetSignatureCount(const uint256& blockHash) const;

    /**
     * Clear all finality data (for testing)
     */
    void Clear();

    /**
     * Restore finality data from DB (called during init)
     * Used by I1 to restore persisted signatures on restart
     */
    void RestoreFinality(const CFinalityManager& finality);

    /**
     * Get the last finalized block height and hash
     * Used for monitoring finality lag
     */
    bool GetLastFinalized(int& nHeightOut, uint256& hashOut) const;

    /**
     * Get finality status for monitoring
     * @param tipHeight - current chain tip height
     * @return lag = tipHeight - lastFinalizedHeight
     */
    int GetFinalityLag(int tipHeight) const;
};

// Global handler instance
extern std::unique_ptr<CFinalityManagerHandler> finalityHandler;

/**
 * CFinalityManagerDB - LevelDB persistence for HU finality data
 *
 * Stores finality records indexed by blockHash.
 * Separate from block data to keep block hash immutable.
 */
class CFinalityManagerDB : public CDBWrapper {
public:
    CFinalityManagerDB(size_t nCacheSize, bool fMemory = false, bool fWipe = false);

    /**
     * Write finality data for a block
     */
    bool WriteFinality(const CFinalityManager& finality);

    /**
     * Read finality data for a block
     * @return true if found, false otherwise
     */
    bool ReadFinality(const uint256& blockHash, CFinalityManager& finality) const;

    /**
     * Check if finality data exists for a block
     */
    bool HasFinality(const uint256& blockHash) const;

    /**
     * Erase finality data (for reorg handling)
     */
    bool EraseFinality(const uint256& blockHash);

    /**
     * Check if a block is final (exists and meets threshold)
     * @param nThreshold - from consensus.nHuQuorumThreshold
     */
    bool IsBlockFinal(const uint256& blockHash, int nThreshold) const;
};

// Global DB instance
extern std::unique_ptr<CFinalityManagerDB> pFinalityDB;

/**
 * Initialize HU finality system
 * @param nCacheSize - LevelDB cache size
 * @param fWipe - wipe database on init
 */
void InitHuFinality(size_t nCacheSize = (1 << 20), bool fWipe = false);

/**
 * Shutdown HU finality system
 */
void ShutdownHuFinality();

/**
 * Check if a block is HU-final (cannot be reorged)
 * Uses global consensus params for threshold
 */
bool IsBlockHuFinal(const uint256& blockHash);

/**
 * Check if a reorg to newTip would violate HU finality
 * @param pindexNew - proposed new tip
 * @param pindexFork - fork point
 * @return true if reorg is blocked by finality
 */
bool WouldViolateHuFinality(const CBlockIndex* pindexNew, const CBlockIndex* pindexFork);

} // namespace hu

#endif // PIVHU_HU_FINALITY_H
