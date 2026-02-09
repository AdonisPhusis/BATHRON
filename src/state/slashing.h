// Copyright (c) 2025 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BATHRON_SLASHING_H
#define BATHRON_SLASHING_H

#include "state/finality.h"
#include "sync.h"
#include "uint256.h"

#include <map>
#include <set>
#include <univalue.h>
#include <vector>

namespace hu {

/**
 * O2: HU Double-Sign Detection (Slashing)
 *
 * Detects masternodes that sign two different blocks at the same height.
 * This is a Byzantine fault that could enable finality attacks.
 *
 * Detection criteria:
 * 1. Same proTxHash (same MN)
 * 2. Same block height
 * 3. Different block hashes
 *
 * Actions on detection:
 * - Log explicit warning
 * - Increment PoSe score (via existing PoSe mechanism)
 * - Track evidence for future slashing (on-chain penalty)
 */

/**
 * Evidence of double-signing
 */
struct CHuDoubleSignEvidence {
    uint256 proTxHash;          // The offending masternode
    int nHeight;                // Block height of the offense

    // First signature
    uint256 blockHash1;
    std::vector<unsigned char> vchSig1;

    // Second conflicting signature
    uint256 blockHash2;
    std::vector<unsigned char> vchSig2;

    int64_t nTimeDetected;      // When we detected this

    CHuDoubleSignEvidence() : nHeight(0), nTimeDetected(0) {}

    SERIALIZE_METHODS(CHuDoubleSignEvidence, obj) {
        READWRITE(obj.proTxHash);
        READWRITE(obj.nHeight);
        READWRITE(obj.blockHash1);
        READWRITE(obj.vchSig1);
        READWRITE(obj.blockHash2);
        READWRITE(obj.vchSig2);
        READWRITE(obj.nTimeDetected);
    }

    UniValue ToJSON() const;
};

/**
 * Double-sign detector
 *
 * Tracks signatures per MN per height and detects conflicts.
 * Uses a rolling window to limit memory usage.
 */
class CHuSlashingDetector {
private:
    mutable RecursiveMutex cs;

    // Track signatures: height -> proTxHash -> (blockHash, signature)
    struct SignatureRecord {
        uint256 blockHash;
        std::vector<unsigned char> vchSig;
    };
    std::map<int, std::map<uint256, SignatureRecord>> mapHeightSignatures;

    // Detected double-signs (for reporting and PoSe)
    std::vector<CHuDoubleSignEvidence> vEvidence;

    // Keep track of last cleanup height
    int nLastCleanupHeight{0};

    // How many blocks of history to keep
    static const int HISTORY_BLOCKS = 100;

public:
    CHuSlashingDetector() = default;

    /**
     * Check if a signature conflicts with a previously seen one.
     * If double-sign is detected, logs and records evidence.
     *
     * @param sig The signature to check
     * @param nHeight Block height for this signature
     * @return true if double-sign was detected (caller should reject/penalize)
     */
    bool CheckAndRecordSignature(const CHuSignature& sig, int nHeight);

    /**
     * Get all detected double-sign evidence
     */
    std::vector<CHuDoubleSignEvidence> GetEvidence() const;

    /**
     * Get evidence for a specific MN
     */
    std::vector<CHuDoubleSignEvidence> GetEvidenceForMN(const uint256& proTxHash) const;

    /**
     * Check if an MN has double-signed
     */
    bool HasDoubleSignEvidence(const uint256& proTxHash) const;

    /**
     * Get the number of double-sign events for an MN
     */
    int GetDoubleSignCount(const uint256& proTxHash) const;

    /**
     * Cleanup old data
     */
    void Cleanup(int nCurrentHeight);

    /**
     * Clear all state (for testing)
     */
    void Clear();

    /**
     * Get statistics
     */
    UniValue GetStats() const;
};

// Global slashing detector
extern std::unique_ptr<CHuSlashingDetector> huSlashingDetector;

/**
 * Initialize the slashing detector
 */
void InitHuSlashing();

/**
 * Shutdown the slashing detector
 */
void ShutdownHuSlashing();

/**
 * Check for double-sign and handle accordingly
 * Called from ProcessHuSignature
 *
 * @param sig The signature to check
 * @param nHeight Block height
 * @return true if signature is OK (no double-sign), false if double-sign detected
 */
bool CheckHuDoubleSign(const CHuSignature& sig, int nHeight);

} // namespace hu

#endif // BATHRON_SLASHING_H
