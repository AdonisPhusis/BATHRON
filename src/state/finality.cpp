// Copyright (c) 2025 The PIVHU Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "state/finality.h"

#include "chain.h"
#include "chainparams.h"
#include "logging.h"
#include "masternode/deterministicmns.h"
#include "state/metrics.h"
#include "masternode/tiertwo_sync_state.h"
#include "utiltime.h"
#include "../validation.h"

#include <boost/filesystem.hpp>
#include <set>

namespace hu {

std::unique_ptr<CFinalityManagerHandler> finalityHandler;
std::unique_ptr<CFinalityManagerDB> pFinalityDB;

// DB key prefix for finality records
static const char DB_HU_FINALITY = 'F';

// ============================================================================
// CFinalityManager Implementation - MN-BASED QUORUM (2/3 of MNs)
// ============================================================================
// Finality is based on MN COUNT (stake), not operator count.
// Each MN signature = 1 vote. This ensures 2/3 of STAKE must sign.
// Operator-Centric model is for IDENTITY only, not finality.
// GetSignatureCount() is defined inline in finality.h
// ============================================================================

/**
 * Get unique operator count (for logging/stats only).
 * Not used for finality threshold - use GetSignatureCount() instead.
 */
size_t CFinalityManager::GetUniqueOperatorCount() const
{
    if (mapSignatures.empty()) {
        return 0;
    }

    std::set<CPubKey> uniqueOperators;

    if (!deterministicMNManager) {
        return mapSignatures.size();
    }

    CDeterministicMNList mnList = deterministicMNManager->GetListAtChainTip();

    for (const auto& [proTxHash, sig] : mapSignatures) {
        auto dmn = mnList.GetMN(proTxHash);
        if (dmn) {
            uniqueOperators.insert(dmn->pdmnState->pubKeyOperator);
        }
    }

    return uniqueOperators.size();
}

/**
 * Check if block has reached finality threshold.
 * Counts MN SIGNATURES (stake-based), not unique operators.
 *
 * @param nThreshold - minimum MN signatures required (e.g., 2/3 testnet, 8/12 mainnet)
 * @return true if signature count >= threshold
 */
bool CFinalityManager::HasFinality(int nThreshold) const
{
    return static_cast<int>(GetSignatureCount()) >= nThreshold;
}

// ============================================================================
// CFinalityManagerDB Implementation
// ============================================================================

CFinalityManagerDB::CFinalityManagerDB(size_t nCacheSize, bool fMemory, bool fWipe)
    : CDBWrapper(GetDataDir() / "finality", nCacheSize, fMemory, fWipe)
{
}

bool CFinalityManagerDB::WriteFinality(const CFinalityManager& finality)
{
    return Write(std::make_pair(DB_HU_FINALITY, finality.blockHash), finality);
}

bool CFinalityManagerDB::ReadFinality(const uint256& blockHash, CFinalityManager& finality) const
{
    return Read(std::make_pair(DB_HU_FINALITY, blockHash), finality);
}

bool CFinalityManagerDB::HasFinality(const uint256& blockHash) const
{
    return Exists(std::make_pair(DB_HU_FINALITY, blockHash));
}

bool CFinalityManagerDB::EraseFinality(const uint256& blockHash)
{
    return Erase(std::make_pair(DB_HU_FINALITY, blockHash));
}

bool CFinalityManagerDB::IsBlockFinal(const uint256& blockHash, int nThreshold) const
{
    CFinalityManager finality;
    if (!ReadFinality(blockHash, finality)) {
        return false;
    }
    return finality.HasFinality(nThreshold);
}

// ============================================================================
// Global Functions
// ============================================================================

void InitHuFinality(size_t nCacheSize, bool fWipe)
{
    const Consensus::Params& consensus = Params().GetConsensus();

    // Initialize in-memory handler
    finalityHandler = std::make_unique<CFinalityManagerHandler>();

    // Initialize LevelDB persistence
    pFinalityDB = std::make_unique<CFinalityManagerDB>(nCacheSize, false, fWipe);

    // ═══════════════════════════════════════════════════════════════════════════
    // I1: RESTORE FINALITY DATA FROM DB ON STARTUP
    // ═══════════════════════════════════════════════════════════════════════════
    // Critical for cold start recovery: reload persisted finality state so that
    // DMM can continue producing blocks without re-collecting all HU signatures.
    // ═══════════════════════════════════════════════════════════════════════════
    if (!fWipe && pFinalityDB) {
        int restoredCount = 0;
        int lastFinalizedHeight = 0;
        uint256 lastFinalizedHash;

        // Iterate over all finality records in DB
        std::unique_ptr<CDBIterator> it(pFinalityDB->NewIterator());
        for (it->Seek(std::make_pair(DB_HU_FINALITY, uint256())); it->Valid(); it->Next()) {
            std::pair<char, uint256> key;
            if (!it->GetKey(key) || key.first != DB_HU_FINALITY) {
                break;
            }

            CFinalityManager finality;
            if (it->GetValue(finality)) {
                // Restore to in-memory handler
                finalityHandler->RestoreFinality(finality);
                restoredCount++;
                g_hu_metrics.dbRestored++;

                // Track the most recent finalized block
                if (finality.HasFinality(consensus.nHuQuorumThreshold) &&
                    finality.nHeight > lastFinalizedHeight) {
                    lastFinalizedHeight = finality.nHeight;
                    lastFinalizedHash = finality.blockHash;
                }
            }
        }

        // Notify sync state of the last finalized block
        if (lastFinalizedHeight > 0) {
            g_tiertwo_sync_state.OnFinalizedBlock(lastFinalizedHeight, GetTime());
            LogPrintf("Quorum Finality: Restored %d records from DB, lastFinalized=%d (%s)\n",
                     restoredCount, lastFinalizedHeight, lastFinalizedHash.ToString().substr(0, 16));
        } else if (restoredCount > 0) {
            LogPrintf("Quorum Finality: Restored %d records from DB (none finalized yet)\n", restoredCount);
        }
    }

    LogPrintf("Quorum Finality: Initialized (quorum=%d/%d, timeout=%ds, maxReorg=%d)\n",
              consensus.nHuQuorumThreshold,
              consensus.nHuQuorumSize,
              consensus.nHuLeaderTimeoutSeconds,
              consensus.nHuMaxReorgDepth);
}

void ShutdownHuFinality()
{
    pFinalityDB.reset();
    finalityHandler.reset();
    LogPrintf("Quorum Finality: Shutdown\n");
}

bool IsBlockHuFinal(const uint256& blockHash)
{
    if (!pFinalityDB) {
        return false;
    }

    const Consensus::Params& consensus = Params().GetConsensus();
    return pFinalityDB->IsBlockFinal(blockHash, consensus.nHuQuorumThreshold);
}

bool WouldViolateHuFinality(const CBlockIndex* pindexNew, const CBlockIndex* pindexFork)
{
    if (!pindexNew || !pindexFork || !pFinalityDB) {
        return false;
    }

    const Consensus::Params& consensus = Params().GetConsensus();

    // Walk from fork point to current tip, checking for finalized blocks
    const CBlockIndex* pindex = chainActive.Tip();
    while (pindex && pindex != pindexFork) {
        if (pFinalityDB->IsBlockFinal(pindex->GetBlockHash(), consensus.nHuQuorumThreshold)) {
            LogPrint(BCLog::STATE, "Quorum Finality: Reorg blocked - block %s at height %d is finalized\n",
                     pindex->GetBlockHash().ToString().substr(0, 16), pindex->nHeight);
            return true;
        }
        pindex = pindex->pprev;
    }

    return false;
}

bool CFinalityManagerHandler::HasFinality(int nHeight, const uint256& blockHash) const
{
    LOCK(cs);

    // Check if we have finality data for this block
    auto it = mapFinality.find(blockHash);
    if (it == mapFinality.end()) {
        return false;
    }

    // Verify height matches
    if (it->second.nHeight != nHeight) {
        LogPrint(BCLog::STATE, "Quorum Finality: Height mismatch for %s (expected %d, got %d)\n",
                 blockHash.ToString().substr(0, 16), nHeight, it->second.nHeight);
        return false;
    }

    return it->second.HasFinality();
}

bool CFinalityManagerHandler::HasConflictingFinality(int nHeight, const uint256& blockHash) const
{
    LOCK(cs);

    // Check if there's a different finalized block at this height
    auto heightIt = mapHeightToBlock.find(nHeight);
    if (heightIt == mapHeightToBlock.end()) {
        return false; // No finalized block at this height
    }

    // If same hash, no conflict
    if (heightIt->second == blockHash) {
        return false;
    }

    // Check if the other block actually has finality
    auto finalityIt = mapFinality.find(heightIt->second);
    if (finalityIt == mapFinality.end()) {
        return false;
    }

    if (finalityIt->second.HasFinality()) {
        LogPrint(BCLog::STATE, "Quorum Finality: Conflicting block at height %d. Finalized: %s, Attempted: %s\n",
                 nHeight,
                 heightIt->second.ToString().substr(0, 16),
                 blockHash.ToString().substr(0, 16));
        return true;
    }

    return false;
}

bool CFinalityManagerHandler::AddSignature(const CHuSignature& sig)
{
    LOCK(cs);

    // Get or create finality entry
    auto& finality = mapFinality[sig.blockHash];
    if (finality.blockHash.IsNull()) {
        finality.blockHash = sig.blockHash;
        // Note: nHeight should be set by caller via MarkBlockFinal or separate method
    }

    // Check if we already have this signature
    if (finality.mapSignatures.count(sig.proTxHash)) {
        LogPrint(BCLog::STATE, "Quorum Finality: Duplicate signature from %s for block %s\n",
                 sig.proTxHash.ToString().substr(0, 16),
                 sig.blockHash.ToString().substr(0, 16));
        return false;
    }

    // Add signature
    finality.mapSignatures[sig.proTxHash] = sig.vchSig;

    const Consensus::Params& consensus = Params().GetConsensus();
    const int nThreshold = consensus.nHuQuorumThreshold;

    // ═══════════════════════════════════════════════════════════════════════════
    // MN-BASED QUORUM: Count MN signatures (stake-based finality)
    // ═══════════════════════════════════════════════════════════════════════════
    // Each MN signature = 1 vote. Finality = 2/3 of MN signatures.
    // Operator-Centric model is for IDENTITY only, not finality.
    // ═══════════════════════════════════════════════════════════════════════════
    size_t sigCount = finality.GetSignatureCount();
    size_t uniqueOps = finality.GetUniqueOperatorCount();  // For logging only

    LogPrint(BCLog::STATE, "Quorum Finality: Added signature %zu/%d (ops=%zu) from %s for block %s\n",
             sigCount, nThreshold, uniqueOps,
             sig.proTxHash.ToString().substr(0, 16),
             sig.blockHash.ToString().substr(0, 16));

    // Get block height from mapBlockIndex if not set
    int nHeight = finality.nHeight;
    if (nHeight <= 0) {
        LOCK(cs_main);
        auto it = mapBlockIndex.find(sig.blockHash);
        if (it != mapBlockIndex.end()) {
            nHeight = it->second->nHeight;
            finality.nHeight = nHeight;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // I1: PERSIST SIGNATURE TO DB
    // ═══════════════════════════════════════════════════════════════════════════
    // Persist after each signature so we don't lose finality data on restart.
    // This is critical for network-wide restarts and cold start recovery.
    // ═══════════════════════════════════════════════════════════════════════════
    if (pFinalityDB) {
        pFinalityDB->WriteFinality(finality);
        LogPrint(BCLog::STATE, "Quorum Finality: Persisted signature to DB for block %s (height=%d, ops=%zu, sigs=%zu)\n",
                 sig.blockHash.ToString().substr(0, 16), nHeight, uniqueOps, finality.mapSignatures.size());
    }

    // Check if we just reached finality (based on MN signature count)
    if (static_cast<int>(sigCount) == nThreshold) {
        // ═══════════════════════════════════════════════════════════════════════════
        // FINALITY DELAY TRACKING (v4.0)
        // ═══════════════════════════════════════════════════════════════════════════
        int64_t blockReceivedTime = g_hu_metrics.lastBlockReceivedTime.load();
        int64_t finalityTime = GetTimeMicros();
        int64_t delayMs = 0;
        if (blockReceivedTime > 0) {
            delayMs = (finalityTime - blockReceivedTime) / 1000;  // Convert to ms
            g_hu_metrics.lastFinalityDelayMs.store(delayMs);
            g_hu_metrics.totalFinalityDelayMs.fetch_add(delayMs);
            g_hu_metrics.finalityDelayCount.fetch_add(1);
        }

        LogPrintf("Quorum Finality: Block %s at height %d reached finality (%zu/%d sigs, %zu ops, delay=%ldms)\n",
                  sig.blockHash.ToString().substr(0, 16), nHeight, sigCount, nThreshold,
                  uniqueOps, delayMs);

        // Update height->block mapping if we have the height
        if (nHeight > 0) {
            mapHeightToBlock[nHeight] = sig.blockHash;

            // BATHRON: Notify sync state that we have a finalized block
            // This is critical for DMM to know it can produce the next block
            g_tiertwo_sync_state.OnFinalizedBlock(nHeight, GetTime());
            LogPrint(BCLog::STATE, "Quorum Finality: Notified sync state of finalized block at height %d\n",
                     nHeight);
        }
    }

    return true;
}

bool CFinalityManagerHandler::GetFinality(const uint256& blockHash, CFinalityManager& finalityOut) const
{
    LOCK(cs);

    auto it = mapFinality.find(blockHash);
    if (it == mapFinality.end()) {
        return false;
    }

    finalityOut = it->second;
    return true;
}

int CFinalityManagerHandler::GetSignatureCount(const uint256& blockHash) const
{
    LOCK(cs);

    auto it = mapFinality.find(blockHash);
    if (it == mapFinality.end()) {
        return 0;
    }

    return static_cast<int>(it->second.mapSignatures.size());
}

void CFinalityManagerHandler::Clear()
{
    LOCK(cs);
    mapFinality.clear();
    mapHeightToBlock.clear();
}

void CFinalityManagerHandler::RestoreFinality(const CFinalityManager& finality)
{
    LOCK(cs);

    // Restore finality entry
    mapFinality[finality.blockHash] = finality;

    // Update height mapping if finalized
    if (finality.nHeight > 0) {
        const Consensus::Params& consensus = Params().GetConsensus();
        if (finality.HasFinality(consensus.nHuQuorumThreshold)) {
            mapHeightToBlock[finality.nHeight] = finality.blockHash;
        }
    }

    LogPrint(BCLog::STATE, "Quorum Finality: Restored block %s height=%d sigs=%zu\n",
             finality.blockHash.ToString().substr(0, 16),
             finality.nHeight,
             finality.mapSignatures.size());
}

bool CFinalityManagerHandler::GetLastFinalized(int& nHeightOut, uint256& hashOut) const
{
    LOCK(cs);

    const Consensus::Params& consensus = Params().GetConsensus();
    int maxHeight = 0;
    uint256 maxHash;

    // Find the highest finalized block
    for (const auto& pair : mapHeightToBlock) {
        auto it = mapFinality.find(pair.second);
        if (it != mapFinality.end() && it->second.HasFinality(consensus.nHuQuorumThreshold)) {
            if (pair.first > maxHeight) {
                maxHeight = pair.first;
                maxHash = pair.second;
            }
        }
    }

    if (maxHeight > 0) {
        nHeightOut = maxHeight;
        hashOut = maxHash;
        return true;
    }

    return false;
}

int CFinalityManagerHandler::GetFinalityLag(int tipHeight) const
{
    int lastFinalizedHeight = 0;
    uint256 lastFinalizedHash;

    if (GetLastFinalized(lastFinalizedHeight, lastFinalizedHash)) {
        return tipHeight - lastFinalizedHeight;
    }

    // No finalized blocks yet - return tip height as lag
    return tipHeight;
}

} // namespace hu
