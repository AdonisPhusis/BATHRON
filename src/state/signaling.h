// Copyright (c) 2025 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BATHRON_SIGNALING_H
#define BATHRON_SIGNALING_H

#include "state/finality.h"
#include "net/net.h"
#include "sync.h"
#include "uint256.h"

#include <map>
#include <set>
#include <memory>

class CBlockIndex;
class CConnman;
class CNode;

namespace hu {

/**
 * HU Signaling Manager
 *
 * Handles the automatic signing and propagation of HU finality signatures.
 * When a MN in the quorum receives a valid block, it signs and broadcasts.
 * When enough signatures (2/3) are collected, the block is final.
 */
class CHuSignalingManager {
private:
    mutable RecursiveMutex cs;

    // Track which blocks we've already signed (to avoid duplicate signatures)
    std::set<uint256> setSignedBlocks;

    // Track which signatures we've already relayed (to avoid spam)
    std::map<uint256, std::set<uint256>> mapRelayedSigs;  // blockHash -> set of proTxHashes

    // Signature cache: blockHash -> (proTxHash -> signature)
    std::map<uint256, std::map<uint256, std::vector<unsigned char>>> mapSigCache;

    // Height tracking for cleanup
    int nLastCleanupHeight{0};

    // ═══════════════════════════════════════════════════════════════════════════
    // I3: Rate limiting per peer (DoS protection)
    // ═══════════════════════════════════════════════════════════════════════════
    struct PeerRateLimit {
        int count{0};
        int64_t lastResetTime{0};
    };
    std::map<NodeId, PeerRateLimit> mapPeerRateLimit;
    static constexpr int RATE_LIMIT_MAX_SIGS = 100;      // Max signatures per minute per peer
    static constexpr int RATE_LIMIT_WINDOW_SECONDS = 60;  // Rate limit window

public:
    CHuSignalingManager() = default;

    /**
     * Called when we receive a new valid block.
     * If we're a MN in the quorum for this block, sign it and broadcast.
     *
     * @param pindex The block index of the new block
     * @param connman Connection manager for broadcasting
     * @return true if we signed and broadcast
     */
    bool OnNewBlock(const CBlockIndex* pindex, CConnman* connman);

    /**
     * Process a received HU signature from the network.
     * Validates the signature and adds it to the finality handler.
     * Relays to other peers if valid and new.
     *
     * @param sig The received signature
     * @param pfrom The peer that sent it
     * @param connman Connection manager for relaying
     * @return true if signature was valid and new
     */
    bool ProcessHuSignature(const CHuSignature& sig, CNode* pfrom, CConnman* connman);

    /**
     * Get the number of signatures for a block
     */
    int GetSignatureCount(const uint256& blockHash) const;

    /**
     * Check if a block has reached quorum (2/3 signatures)
     */
    bool HasQuorum(const uint256& blockHash) const;

    /**
     * Cleanup old data for blocks that are now deeply buried
     */
    void Cleanup(int nCurrentHeight);

    /**
     * Clear all state (for testing)
     */
    void Clear();

private:
    /**
     * MULTI-MN: Sign a block with a specific MN's operator key
     * @param blockHash The block to sign
     * @param proTxHash The proTxHash of the MN to sign with
     * @param sigOut Output signature
     * @return true if signing succeeded
     */
    bool SignBlockWithMN(const uint256& blockHash, const uint256& proTxHash, CHuSignature& sigOut);

    /**
     * Sign a block with first managed MN's operator key (legacy)
     * @return true if signing succeeded
     */
    bool SignBlock(const uint256& blockHash, CHuSignature& sigOut);

    /**
     * Validate a signature against the quorum for the block
     * @return true if signature is from a valid quorum member
     */
    bool ValidateSignature(const CHuSignature& sig, const CBlockIndex* pindex) const;

    /**
     * Broadcast a signature to all peers
     */
    void BroadcastSignature(const CHuSignature& sig, CConnman* connman, CNode* pfrom = nullptr);
};

// Global signaling manager instance
extern std::unique_ptr<CHuSignalingManager> huSignalingManager;

/**
 * Initialize the HU signaling system
 */
void InitHuSignaling();

/**
 * Shutdown the HU signaling system
 */
void ShutdownHuSignaling();

/**
 * Called from validation when a new block is connected.
 * Triggers signature if we're in the quorum.
 */
void NotifyBlockConnected(const CBlockIndex* pindex, CConnman* connman);

/**
 * Check if the previous block has reached quorum.
 * Used by DMM to decide if we can produce the next block.
 *
 * @param pindexPrev The previous block
 * @return true if previous block has 2/3 signatures (or we're in bootstrap)
 */
bool PreviousBlockHasQuorum(const CBlockIndex* pindexPrev);

} // namespace hu

#endif // BATHRON_SIGNALING_H
