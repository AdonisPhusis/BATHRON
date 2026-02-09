// Copyright (c) 2025 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BATHRON_METRICS_H
#define BATHRON_METRICS_H

#include <atomic>
#include <univalue.h>

namespace hu {

/**
 * HU Metrics - Production-ready monitoring for DMM + HU Finality
 *
 * I5: Exposes internal counters for network health monitoring.
 * All counters are atomic for thread-safe updates.
 *
 * Usage:
 *   g_hu_metrics.blocksProduced++;
 *   g_hu_metrics.signaturesReceived++;
 *
 * RPC:
 *   gethustats -> returns JSON with all metrics
 */
struct HuMetrics {
    // ═══════════════════════════════════════════════════════════════════════════
    // DMM Block Production Metrics
    // ═══════════════════════════════════════════════════════════════════════════
    std::atomic<uint64_t> blocksProduced{0};        // Total blocks produced by this node
    std::atomic<uint64_t> blocksPrimary{0};         // Blocks produced as primary (slot 0)
    std::atomic<uint64_t> blocksFallback{0};        // Blocks produced as fallback (slot > 0)
    std::atomic<uint64_t> fallbackTriggered{0};     // Times we waited for fallback timeout

    // ═══════════════════════════════════════════════════════════════════════════
    // HU Finality Metrics
    // ═══════════════════════════════════════════════════════════════════════════
    std::atomic<uint64_t> blocksFinalized{0};       // Total blocks with quorum signatures
    std::atomic<uint64_t> signaturesSent{0};        // HU signatures we signed and broadcast
    std::atomic<uint64_t> signaturesReceived{0};    // HU signatures received from peers
    std::atomic<uint64_t> signaturesValid{0};       // HU signatures that passed validation
    std::atomic<uint64_t> signaturesInvalid{0};     // HU signatures that failed validation
    std::atomic<uint64_t> signaturesRateLimited{0}; // HU signatures rejected by rate limiter

    // ═══════════════════════════════════════════════════════════════════════════
    // Quorum Health Metrics
    // ═══════════════════════════════════════════════════════════════════════════
    std::atomic<uint64_t> quorumMissed{0};          // Blocks where we weren't in quorum
    std::atomic<uint64_t> quorumReached{0};         // Times quorum was reached for a block
    std::atomic<int> lastFinalizedHeight{0};        // Height of last finalized block

    // ═══════════════════════════════════════════════════════════════════════════
    // Finality Delay Metrics (v4.0)
    // ═══════════════════════════════════════════════════════════════════════════
    std::atomic<int64_t> lastFinalityDelayMs{0};    // Delay of last finalized block (ms)
    std::atomic<int64_t> totalFinalityDelayMs{0};   // Sum of all finality delays (for avg)
    std::atomic<uint64_t> finalityDelayCount{0};    // Number of finality delay samples
    std::atomic<int64_t> lastBlockReceivedTime{0};  // Timestamp when last block was received

    // ═══════════════════════════════════════════════════════════════════════════
    // Cold Start / Recovery Metrics
    // ═══════════════════════════════════════════════════════════════════════════
    std::atomic<uint64_t> coldStartRecovery{0};     // Times cold start recovery was triggered
    std::atomic<uint64_t> dbRestored{0};            // Finality records restored from DB

    /**
     * Convert metrics to JSON for RPC
     */
    UniValue ToJSON() const {
        UniValue result(UniValue::VOBJ);

        // DMM Production
        UniValue dmm(UniValue::VOBJ);
        dmm.pushKV("blocks_produced", (int64_t)blocksProduced.load());
        dmm.pushKV("blocks_primary", (int64_t)blocksPrimary.load());
        dmm.pushKV("blocks_fallback", (int64_t)blocksFallback.load());
        dmm.pushKV("fallback_triggered", (int64_t)fallbackTriggered.load());
        result.pushKV("dmm", dmm);

        // HU Finality
        UniValue finality(UniValue::VOBJ);
        finality.pushKV("blocks_finalized", (int64_t)blocksFinalized.load());
        finality.pushKV("signatures_sent", (int64_t)signaturesSent.load());
        finality.pushKV("signatures_received", (int64_t)signaturesReceived.load());
        finality.pushKV("signatures_valid", (int64_t)signaturesValid.load());
        finality.pushKV("signatures_invalid", (int64_t)signaturesInvalid.load());
        finality.pushKV("signatures_rate_limited", (int64_t)signaturesRateLimited.load());
        result.pushKV("finality", finality);

        // Quorum Health
        UniValue quorum(UniValue::VOBJ);
        quorum.pushKV("quorum_reached", (int64_t)quorumReached.load());
        quorum.pushKV("quorum_missed", (int64_t)quorumMissed.load());
        quorum.pushKV("last_finalized_height", (int64_t)lastFinalizedHeight.load());

        // Finality delay stats (v4.0)
        quorum.pushKV("last_finality_delay_ms", (int64_t)lastFinalityDelayMs.load());
        uint64_t count = finalityDelayCount.load();
        if (count > 0) {
            int64_t avgDelay = totalFinalityDelayMs.load() / (int64_t)count;
            quorum.pushKV("avg_finality_delay_ms", avgDelay);
        } else {
            quorum.pushKV("avg_finality_delay_ms", 0);
        }
        quorum.pushKV("finality_samples", (int64_t)count);

        result.pushKV("quorum", quorum);

        // Recovery
        UniValue recovery(UniValue::VOBJ);
        recovery.pushKV("cold_start_recovery", (int64_t)coldStartRecovery.load());
        recovery.pushKV("db_records_restored", (int64_t)dbRestored.load());
        result.pushKV("recovery", recovery);

        return result;
    }

    /**
     * Reset all metrics (for testing)
     */
    void Reset() {
        blocksProduced.store(0);
        blocksPrimary.store(0);
        blocksFallback.store(0);
        fallbackTriggered.store(0);
        blocksFinalized.store(0);
        signaturesSent.store(0);
        signaturesReceived.store(0);
        signaturesValid.store(0);
        signaturesInvalid.store(0);
        signaturesRateLimited.store(0);
        quorumMissed.store(0);
        quorumReached.store(0);
        lastFinalizedHeight.store(0);
        lastFinalityDelayMs.store(0);
        totalFinalityDelayMs.store(0);
        finalityDelayCount.store(0);
        lastBlockReceivedTime.store(0);
        coldStartRecovery.store(0);
        dbRestored.store(0);
    }
};

// Global metrics instance
extern HuMetrics g_hu_metrics;

} // namespace hu

#endif // BATHRON_METRICS_H
