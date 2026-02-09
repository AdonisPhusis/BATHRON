// Copyright (c) 2025 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "state/signaling.h"

#include "masternode/activemasternode.h"
#include "masternode/blockproducer.h"
#include "chain.h"
#include "chainparams.h"
#include "masternode/deterministicmns.h"
#include "hash.h"
#include "key.h"
#include "logging.h"
#include "netmessagemaker.h"
#include "state/finality.h"
#include "state/metrics.h"
#include "state/quorum.h"
#include "state/slashing.h"
#include "protocol.h"
#include "utilstrencodings.h"
#include "util/system.h"
#include "utiltime.h"
#include "../validation.h"

#include <set>
#include <thread>  // For std::this_thread::sleep_for

namespace hu {

std::unique_ptr<CHuSignalingManager> huSignalingManager;

// ============================================================================
// Initialization
// ============================================================================

void InitHuSignaling()
{
    huSignalingManager = std::make_unique<CHuSignalingManager>();
    LogPrintf("Quorum Signaling: Initialized\n");
}

void ShutdownHuSignaling()
{
    huSignalingManager.reset();
    LogPrintf("Quorum Signaling: Shutdown\n");
}

// ============================================================================
// CHuSignalingManager Implementation
// ============================================================================

bool CHuSignalingManager::OnNewBlock(const CBlockIndex* pindex, CConnman* connman)
{
    if (!pindex || !connman) {
        return false;
    }

    // Only masternodes sign blocks
    if (!fMasterNode || !activeMasternodeManager || !activeMasternodeManager->IsReady()) {
        return false;
    }

    const uint256& blockHash = pindex->GetBlockHash();

    // ═══════════════════════════════════════════════════════════════════════════
    // MN-BASED FINALITY v4.0
    // ═══════════════════════════════════════════════════════════════════════════
    // - DMM: All MNs participate in block production
    // - FINALITY: MNs vote (one vote per MN = stake-based)
    // - EXCLUSION: Only the SPECIFIC producer MN is excluded (not all MNs of same operator)
    // - Security: 2/3 threshold + producer exclusion prevents self-validation
    // ═══════════════════════════════════════════════════════════════════════════
    const Consensus::Params& consensus = Params().GetConsensus();
    CDeterministicMNList mnList = deterministicMNManager->GetListForBlock(pindex->pprev);

    // Step 1: Identify the block producer MN (to exclude from signing)
    uint256 producerProTxHash;
    auto scores = mn_consensus::CalculateBlockProducerScores(pindex->pprev, mnList);
    if (!scores.empty()) {
        producerProTxHash = scores[0].second->proTxHash;
        LogPrint(BCLog::STATE, "MN Finality: Block producer MN %s for block %s\n",
                 producerProTxHash.ToString().substr(0, 16), blockHash.ToString().substr(0, 16));
    }

    // Small delay to ensure block processing is complete
    std::this_thread::sleep_for(std::chrono::milliseconds(100));

    int cycleIndex = GetHuCycleIndex(pindex->nHeight, consensus.nHuQuorumRotationBlocks);
    uint256 prevCycleHash = pindex->pprev ? pindex->pprev->GetBlockHash() : uint256();

    // Get operator-based quorum (NO operator exclusion - we exclude MN instead)
    CPubKey noOperatorExclusion;
    auto quorumOperators = GetHuQuorumOperators(mnList, cycleIndex, prevCycleHash, noOperatorExclusion);

    // Step 2: Check which of our managed MNs can sign (all except producer)
    std::vector<uint256> managedProTxHashes = activeMasternodeManager->GetManagedProTxHashes();

    bool anySigned = false;
    int signedCount = 0;

    for (const uint256& proTxHash : managedProTxHashes) {
        if (proTxHash.IsNull()) continue;

        // EXCLUDE: Skip the producer MN (cannot sign own block)
        if (proTxHash == producerProTxHash) {
            LogPrint(BCLog::STATE, "MN Finality: Skipping producer MN %s (cannot sign own block)\n",
                     proTxHash.ToString().substr(0, 16));
            continue;
        }

        // Get this MN's operator
        auto dmn = mnList.GetMN(proTxHash);
        if (!dmn) continue;

        const CPubKey& myOperator = dmn->pdmnState->pubKeyOperator;

        // Check if this operator is in the quorum
        bool operatorInQuorum = false;
        for (const auto& quorumOp : quorumOperators) {
            if (quorumOp == myOperator) {
                operatorInQuorum = true;
                break;
            }
        }

        if (!operatorInQuorum) {
            LogPrint(BCLog::STATE, "MN Finality: Operator %s not in quorum for block %s\n",
                     HexStr(myOperator).substr(0, 16), blockHash.ToString().substr(0, 16));
            continue;
        }

        {
            LOCK(cs);
            // Already signed this block with THIS specific MN?
            auto it = mapSigCache.find(blockHash);
            if (it != mapSigCache.end() && it->second.count(proTxHash)) {
                continue;  // Already signed with this MN
            }
        }

        // Sign the block with this MN
        CHuSignature sig;
        if (!SignBlockWithMN(blockHash, proTxHash, sig)) {
            LogPrintf("MN Finality: ERROR - Failed to sign block %s with MN %s\n",
                      blockHash.ToString().substr(0, 16), proTxHash.ToString().substr(0, 16));
            continue;
        }

        {
            LOCK(cs);
            mapSigCache[blockHash][sig.proTxHash] = sig.vchSig;
        }

        if (finalityHandler) {
            finalityHandler->AddSignature(sig);
        }

        BroadcastSignature(sig, connman);
        g_hu_metrics.signaturesSent++;
        signedCount++;

        LogPrintf("MN Finality: Signed block %s with MN %s (operator %s)\n",
                  blockHash.ToString().substr(0, 16),
                  proTxHash.ToString().substr(0, 16),
                  HexStr(myOperator).substr(0, 16));

        anySigned = true;
    }

    if (signedCount == 0 && !producerProTxHash.IsNull()) {
        LogPrint(BCLog::STATE, "MN Finality: No signatures sent for block %s (producer=%s)\n",
                 blockHash.ToString().substr(0, 16), producerProTxHash.ToString().substr(0, 16));
        g_hu_metrics.quorumMissed++;
    } else if (anySigned) {
        LogPrintf("MN Finality: Sent %d signatures for block %s at height %d\n",
                  signedCount, blockHash.ToString().substr(0, 16), pindex->nHeight);
    }

    return anySigned;
}

bool CHuSignalingManager::ProcessHuSignature(const CHuSignature& sig, CNode* pfrom, CConnman* connman)
{
    // I5: Track received signatures
    g_hu_metrics.signaturesReceived++;

    // Basic validation
    if (sig.blockHash.IsNull() || sig.proTxHash.IsNull() || sig.vchSig.empty()) {
        LogPrint(BCLog::STATE, "Quorum Signaling: Invalid signature structure\n");
        g_hu_metrics.signaturesInvalid++;
        return false;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // I3: RATE LIMITING - Prevent DoS via signature spam
    // ═══════════════════════════════════════════════════════════════════════════
    // Each peer can submit at most RATE_LIMIT_MAX_SIGS signatures per minute.
    // This prevents an attacker from overwhelming the node with invalid signatures.
    // ═══════════════════════════════════════════════════════════════════════════
    if (pfrom) {
        LOCK(cs);
        int64_t now = GetTime();
        auto& rateLimit = mapPeerRateLimit[pfrom->GetId()];

        // Reset counter if window expired
        if (now - rateLimit.lastResetTime > RATE_LIMIT_WINDOW_SECONDS) {
            rateLimit.count = 0;
            rateLimit.lastResetTime = now;
        }

        // Check rate limit
        if (++rateLimit.count > RATE_LIMIT_MAX_SIGS) {
            int windowSecs = RATE_LIMIT_WINDOW_SECONDS;  // Avoid ODR-use of static constexpr
            LogPrint(BCLog::STATE, "Quorum Signaling: Rate-limit peer %d (%d sigs in %ds)\n",
                     pfrom->GetId(), rateLimit.count, windowSecs);
            g_hu_metrics.signaturesRateLimited++;
            return false;
        }
    }

    // Check if we already have this signature
    {
        LOCK(cs);
        auto it = mapSigCache.find(sig.blockHash);
        if (it != mapSigCache.end() && it->second.count(sig.proTxHash)) {
            // Already have this signature
            return false;
        }
    }

    // Get the block index
    const CBlockIndex* pindex = nullptr;
    {
        LOCK(cs_main);
        auto it = mapBlockIndex.find(sig.blockHash);
        if (it == mapBlockIndex.end()) {
            // Block not known yet - reject signature
            // This shouldn't happen if block producer delays signing properly
            LogPrint(BCLog::STATE, "Quorum Signaling: Unknown block %s for signature (block not received yet)\n",
                     sig.blockHash.ToString().substr(0, 16));
            return false;
        }
        pindex = it->second;
    }

    // Validate the signature
    if (!ValidateSignature(sig, pindex)) {
        LogPrint(BCLog::STATE, "Quorum Signaling: Invalid signature from %s for block %s\n",
                 sig.proTxHash.ToString().substr(0, 16), sig.blockHash.ToString().substr(0, 16));
        g_hu_metrics.signaturesInvalid++;
        return false;
    }

    // I5: Valid signature received
    g_hu_metrics.signaturesValid++;

    // O2: Check for double-signing (slashing)
    int blockHeight = pindex ? pindex->nHeight : 0;
    if (!CheckHuDoubleSign(sig, blockHeight)) {
        LogPrint(BCLog::STATE, "Quorum Signaling: DOUBLE-SIGN detected from %s at height %d - REJECTING\n",
                 sig.proTxHash.ToString().substr(0, 16), blockHeight);
        return false;  // Reject double-signed signatures
    }

    // Add to cache and finality handler
    {
        LOCK(cs);
        mapSigCache[sig.blockHash][sig.proTxHash] = sig.vchSig;
    }

    if (finalityHandler) {
        finalityHandler->AddSignature(sig);
    }

    // Check if we just reached quorum
    const Consensus::Params& consensus = Params().GetConsensus();
    int sigCount = GetSignatureCount(sig.blockHash);
    if (sigCount == consensus.nHuQuorumThreshold) {
        LogPrintf("Quorum Signaling: Block %s reached quorum (%d/%d signatures)\n",
                  sig.blockHash.ToString().substr(0, 16), sigCount, consensus.nHuQuorumSize);

        // I5: Track quorum reached and block finalization
        g_hu_metrics.quorumReached++;
        g_hu_metrics.blocksFinalized++;

        // Update last finalized height
        int blockHeight = pindex ? pindex->nHeight : 0;
        if (blockHeight > g_hu_metrics.lastFinalizedHeight.load()) {
            g_hu_metrics.lastFinalizedHeight.store(blockHeight);
        }
    }

    // Relay to other peers
    BroadcastSignature(sig, connman, pfrom);

    LogPrint(BCLog::STATE, "Quorum Signaling: Accepted signature %d/%d from %s for block %s\n",
             sigCount, consensus.nHuQuorumThreshold,
             sig.proTxHash.ToString().substr(0, 16), sig.blockHash.ToString().substr(0, 16));

    return true;
}

// MULTI-MN: Sign block with a specific MN
bool CHuSignalingManager::SignBlockWithMN(const uint256& blockHash, const uint256& proTxHash, CHuSignature& sigOut)
{
    if (!activeMasternodeManager || !activeMasternodeManager->IsReady()) {
        return false;
    }

    // Get operator key for this specific proTxHash
    CKey operatorKey;
    CDeterministicMNCPtr dmn;
    auto keyResult = activeMasternodeManager->GetOperatorKey(proTxHash, operatorKey, dmn);
    if (!keyResult) {
        LogPrintf("MULTI-MN Quorum: Failed to get operator key for %s: %s\n",
                  proTxHash.ToString().substr(0, 16), keyResult.getError());
        return false;
    }

    // Create message to sign: "HUSIG" || blockHash
    CHashWriter ss(SER_GETHASH, 0);
    ss << std::string("HUSIG");
    ss << blockHash;
    uint256 msgHash = ss.GetHash();

    // Sign with ECDSA
    std::vector<unsigned char> vchSig;
    if (!operatorKey.SignCompact(msgHash, vchSig)) {
        LogPrintf("MULTI-MN Quorum: Failed to sign block hash with MN %s\n",
                  proTxHash.ToString().substr(0, 16));
        return false;
    }

    sigOut.blockHash = blockHash;
    sigOut.proTxHash = proTxHash;
    sigOut.vchSig = vchSig;

    return true;
}

// Legacy: Sign block with first managed MN
bool CHuSignalingManager::SignBlock(const uint256& blockHash, CHuSignature& sigOut)
{
    if (!activeMasternodeManager || !activeMasternodeManager->IsReady()) {
        return false;
    }

    // Use first managed proTxHash
    uint256 proTxHash = activeMasternodeManager->GetProTx();
    if (proTxHash.IsNull()) {
        LogPrintf("Quorum Signaling: No managed MN available for signing\n");
        return false;
    }

    return SignBlockWithMN(blockHash, proTxHash, sigOut);
}

bool CHuSignalingManager::ValidateSignature(const CHuSignature& sig, const CBlockIndex* pindex) const
{
    if (!pindex || !pindex->pprev) {
        return false;
    }

    const Consensus::Params& consensus = Params().GetConsensus();

    // Get the MN list at the block's height
    CDeterministicMNList mnList = deterministicMNManager->GetListForBlock(pindex->pprev);

    // Get the MN's operator pubkey
    CDeterministicMNCPtr dmn = mnList.GetMN(sig.proTxHash);
    if (!dmn) {
        LogPrint(BCLog::STATE, "Quorum Signaling: Unknown MN %s\n", sig.proTxHash.ToString().substr(0, 16));
        return false;
    }

    const CPubKey& signerOperator = dmn->pdmnState->pubKeyOperator;

    // ═══════════════════════════════════════════════════════════════════════════
    // MN-BASED VALIDATION v4.0
    // ═══════════════════════════════════════════════════════════════════════════
    // Check if signer's OPERATOR is in quorum (no exclusion)
    // Security comes from 2/3 threshold, not from excluding producer
    // ═══════════════════════════════════════════════════════════════════════════
    int cycleIndex = GetHuCycleIndex(pindex->nHeight, consensus.nHuQuorumRotationBlocks);
    uint256 prevCycleHash = pindex->pprev->GetBlockHash();

    // Check if signer's operator is in the quorum (NO exclusion)
    CPubKey noExclusion;  // Empty = no exclusion
    if (!IsOperatorInHuQuorum(mnList, cycleIndex, prevCycleHash, signerOperator, noExclusion)) {
        LogPrint(BCLog::STATE, "Quorum Signaling: Operator %s not in quorum for height %d\n",
                 HexStr(signerOperator).substr(0, 16), pindex->nHeight);
        return false;
    }

    // Recreate the message hash
    CHashWriter ss(SER_GETHASH, 0);
    ss << std::string("HUSIG");
    ss << sig.blockHash;
    uint256 msgHash = ss.GetHash();

    // Recover pubkey from compact signature
    CPubKey recoveredPubKey;
    if (!recoveredPubKey.RecoverCompact(msgHash, sig.vchSig)) {
        LogPrint(BCLog::STATE, "Quorum Signaling: Failed to recover pubkey from signature\n");
        return false;
    }

    // Verify it matches the operator pubkey
    if (recoveredPubKey != signerOperator) {
        LogPrint(BCLog::STATE, "Quorum Signaling: Signature pubkey mismatch for operator %s\n",
                 HexStr(signerOperator).substr(0, 16));
        return false;
    }

    return true;
}

void CHuSignalingManager::BroadcastSignature(const CHuSignature& sig, CConnman* connman, CNode* pfrom)
{
    if (!connman) {
        return;
    }

    {
        LOCK(cs);
        // Track relayed signatures to avoid spam
        if (mapRelayedSigs[sig.blockHash].count(sig.proTxHash)) {
            return;  // Already relayed this signature
        }
        mapRelayedSigs[sig.blockHash].insert(sig.proTxHash);
    }

    // Broadcast to all peers except the one we received it from
    connman->ForEachNode([&](CNode* pnode) {
        if (pnode == pfrom) {
            return;  // Don't send back to sender
        }
        if (!pnode->fSuccessfullyConnected || pnode->fDisconnect) {
            return;
        }

        CNetMsgMaker msgMaker(pnode->GetSendVersion());
        connman->PushMessage(pnode, msgMaker.Make(NetMsgType::HUSIG, sig));
    });
}

int CHuSignalingManager::GetSignatureCount(const uint256& blockHash) const
{
    LOCK(cs);
    auto it = mapSigCache.find(blockHash);
    if (it == mapSigCache.end()) {
        return 0;
    }
    return static_cast<int>(it->second.size());
}

bool CHuSignalingManager::HasQuorum(const uint256& blockHash) const
{
    const Consensus::Params& consensus = Params().GetConsensus();

    // ═══════════════════════════════════════════════════════════════════════════
    // SECURITY: Verify minimum quorum size before declaring finality
    // ═══════════════════════════════════════════════════════════════════════════
    // With too few confirmed MNs, an attacker controlling a small number of MNs
    // could reach threshold and finalize malicious blocks.
    // Example: With only 2 MNs and threshold=2, attacker needs only 2 MNs.
    // We require at least nHuQuorumSize confirmed MNs for secure finality.
    // ═══════════════════════════════════════════════════════════════════════════

    // Get the block to determine which MN list to use
    const CBlockIndex* pindex = nullptr;
    {
        LOCK(cs_main);
        auto it = mapBlockIndex.find(blockHash);
        if (it != mapBlockIndex.end()) {
            pindex = it->second;
        }
    }

    if (pindex && pindex->pprev && deterministicMNManager) {
        CDeterministicMNList mnList = deterministicMNManager->GetListForBlock(pindex->pprev);
        size_t confirmedMNs = mnList.GetConfirmedMNsCount();

        if (static_cast<int>(confirmedMNs) < consensus.nHuQuorumSize) {
            LogPrint(BCLog::STATE, "Quorum Finality: Insufficient confirmed MNs (%zu/%d) for block %s\n",
                     confirmedMNs, consensus.nHuQuorumSize, blockHash.ToString().substr(0, 16));
            return false;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // OPERATOR-CENTRIC QUORUM: Use finalityHandler which counts unique operators
    // ═══════════════════════════════════════════════════════════════════════════
    if (finalityHandler) {
        CFinalityManager finality;
        if (finalityHandler->GetFinality(blockHash, finality)) {
            return finality.HasFinality(consensus.nHuQuorumThreshold);
        }
    }
    // Fallback to raw signature count if finalityHandler not available
    return GetSignatureCount(blockHash) >= consensus.nHuQuorumThreshold;
}

void CHuSignalingManager::Cleanup(int nCurrentHeight)
{
    LOCK(cs);

    // Only cleanup every 100 blocks
    if (nCurrentHeight - nLastCleanupHeight < 100) {
        return;
    }
    nLastCleanupHeight = nCurrentHeight;

    // ═══════════════════════════════════════════════════════════════════════════
    // I2: INTELLIGENT CLEANUP - Only remove finalized blocks
    // ═══════════════════════════════════════════════════════════════════════════
    // SECURITY: Never delete signatures for blocks that haven't reached finality.
    // We only clean up blocks that are:
    // 1. Older than KEEP_BLOCKS behind current height
    // 2. Already finalized (have quorum signatures in DB)
    // ═══════════════════════════════════════════════════════════════════════════
    const int KEEP_BLOCKS = 100;
    const Consensus::Params& consensus = Params().GetConsensus();

    std::vector<uint256> toRemove;

    for (const auto& entry : mapSigCache) {
        const uint256& blockHash = entry.first;
        // Get block height
        int blockHeight = -1;
        {
            LOCK(cs_main);
            auto it = mapBlockIndex.find(blockHash);
            if (it != mapBlockIndex.end()) {
                blockHeight = it->second->nHeight;
            }
        }

        // Skip blocks we can't identify or that are too recent
        if (blockHeight < 0 || nCurrentHeight - blockHeight < KEEP_BLOCKS) {
            continue;
        }

        // Only remove if the block is finalized
        bool isFinalized = false;

        // Check in-memory finality handler
        if (finalityHandler) {
            CFinalityManager finality;
            if (finalityHandler->GetFinality(blockHash, finality)) {
                if (finality.HasFinality(consensus.nHuQuorumThreshold)) {
                    isFinalized = true;
                }
            }
        }

        // Also check DB for persisted finality
        if (!isFinalized && pFinalityDB) {
            if (pFinalityDB->IsBlockFinal(blockHash, consensus.nHuQuorumThreshold)) {
                isFinalized = true;
            }
        }

        if (isFinalized) {
            toRemove.push_back(blockHash);
        }
    }

    // Remove finalized old blocks from caches
    int removedCount = 0;
    for (const auto& hash : toRemove) {
        mapSigCache.erase(hash);
        mapRelayedSigs.erase(hash);
        setSignedBlocks.erase(hash);
        removedCount++;
    }

    if (removedCount > 0) {
        LogPrint(BCLog::STATE, "Quorum Signaling: Cleanup removed %d finalized blocks older than %d\n",
                 removedCount, nCurrentHeight - KEEP_BLOCKS);
    }

    LogPrint(BCLog::STATE, "Quorum Signaling: Cleanup complete. Cache sizes: sigs=%zu, relayed=%zu, signed=%zu\n",
             mapSigCache.size(), mapRelayedSigs.size(), setSignedBlocks.size());
}

void CHuSignalingManager::Clear()
{
    LOCK(cs);
    setSignedBlocks.clear();
    mapRelayedSigs.clear();
    mapSigCache.clear();
    nLastCleanupHeight = 0;
}

// ============================================================================
// Global Functions
// ============================================================================

void NotifyBlockConnected(const CBlockIndex* pindex, CConnman* connman)
{
    if (!huSignalingManager) {
        return;
    }

    // Record block received time for finality delay tracking (v4.0)
    g_hu_metrics.lastBlockReceivedTime.store(GetTimeMicros());

    // If we're a MN, sign the block
    huSignalingManager->OnNewBlock(pindex, connman);
    huSignalingManager->Cleanup(pindex->nHeight);
}

// NOTE: Bootstrap height and cold start timeout are now network-specific
// via consensus.nDMMBootstrapHeight and consensus.nStaleChainTimeout

bool PreviousBlockHasQuorum(const CBlockIndex* pindexPrev)
{
    if (!pindexPrev) {
        return true;  // Genesis - no previous block to check
    }

    const Consensus::Params& consensus = Params().GetConsensus();

    // ═══════════════════════════════════════════════════════════════════════════
    // BATHRON Bootstrap Exception: Blocks during bootstrap phase exempt from quorum
    // ═══════════════════════════════════════════════════════════════════════════
    // Uses consensus.nDMMBootstrapHeight (network-specific):
    // - Mainnet/Testnet: 10 blocks
    // - Regtest: 2 blocks
    // During this phase, MNs are being registered and confirmed.
    // ═══════════════════════════════════════════════════════════════════════════
    if (pindexPrev->nHeight <= consensus.nDMMBootstrapHeight) {
        return true;  // Bootstrap blocks exempt - no HU signatures yet
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Cold Start Recovery: If tip is very old, bypass quorum check
    // ═══════════════════════════════════════════════════════════════════════════
    // SECURITY: Uses consensus.nStaleChainTimeout (network-specific):
    // - Mainnet: 3600s (1h) - requires 1h+ outage to exploit
    // - Testnet: 600s (10min) - balanced for testing
    // - Regtest: 60s - fast for automated tests
    //
    // This handles network-wide restarts where:
    // - All nodes have the same stale tip
    // - No recent HU signatures exist (weren't exchanged during reindex)
    // - We need to allow DMM to produce the next block to restart finality
    // ═══════════════════════════════════════════════════════════════════════════
    int64_t tipAge = GetTime() - pindexPrev->GetBlockTime();
    if (tipAge > consensus.nStaleChainTimeout) {
        LogPrintf("Quorum Signaling: COLD START (tip age=%ds, threshold=%ds) - bypassing quorum check\n",
                 (int)tipAge, (int)consensus.nStaleChainTimeout);
        return true;
    }

    // Check if previous block has quorum
    const uint256& prevHash = pindexPrev->GetBlockHash();

    if (huSignalingManager && huSignalingManager->HasQuorum(prevHash)) {
        return true;
    }

    // Also check the finality handler (for persisted data)
    if (finalityHandler) {
        CFinalityManager finality;
        if (finalityHandler->GetFinality(prevHash, finality)) {
            if (finality.HasFinality(consensus.nHuQuorumThreshold)) {
                return true;
            }
        }
    }

    // Check DB for persisted finality
    if (pFinalityDB && pFinalityDB->IsBlockFinal(prevHash, consensus.nHuQuorumThreshold)) {
        return true;
    }

    int sigCount = huSignalingManager ? huSignalingManager->GetSignatureCount(prevHash) : 0;
    LogPrint(BCLog::STATE, "Quorum Signaling: Previous block %s lacks quorum (%d/%d signatures)\n",
             prevHash.ToString().substr(0, 16), sigCount, consensus.nHuQuorumThreshold);

    return false;
}

} // namespace hu
