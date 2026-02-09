// Copyright (c) 2025 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "state/slashing.h"

#include "logging.h"
#include "state/metrics.h"
#include "utilstrencodings.h"
#include "utiltime.h"

namespace hu {

std::unique_ptr<CHuSlashingDetector> huSlashingDetector;

// ============================================================================
// CHuDoubleSignEvidence Implementation
// ============================================================================

UniValue CHuDoubleSignEvidence::ToJSON() const
{
    UniValue result(UniValue::VOBJ);
    result.pushKV("proTxHash", proTxHash.ToString());
    result.pushKV("height", nHeight);
    result.pushKV("blockhash1", blockHash1.ToString());
    result.pushKV("signature1", HexStr(vchSig1));
    result.pushKV("blockhash2", blockHash2.ToString());
    result.pushKV("signature2", HexStr(vchSig2));
    result.pushKV("time_detected", nTimeDetected);
    return result;
}

// ============================================================================
// CHuSlashingDetector Implementation
// ============================================================================

bool CHuSlashingDetector::CheckAndRecordSignature(const CHuSignature& sig, int nHeight)
{
    LOCK(cs);

    auto& heightMap = mapHeightSignatures[nHeight];
    auto it = heightMap.find(sig.proTxHash);

    if (it != heightMap.end()) {
        // Already have a signature from this MN at this height
        const SignatureRecord& existingRecord = it->second;

        if (existingRecord.blockHash != sig.blockHash) {
            // DOUBLE-SIGN DETECTED!
            CHuDoubleSignEvidence evidence;
            evidence.proTxHash = sig.proTxHash;
            evidence.nHeight = nHeight;
            evidence.blockHash1 = existingRecord.blockHash;
            evidence.vchSig1 = existingRecord.vchSig;
            evidence.blockHash2 = sig.blockHash;
            evidence.vchSig2 = sig.vchSig;
            evidence.nTimeDetected = GetTime();

            vEvidence.push_back(evidence);

            // Log explicit warning
            LogPrintf("SLASHING: MN %s DOUBLE-SIGNED at HU height %d!\n"
                      "  Block 1: %s\n"
                      "  Block 2: %s\n"
                      "  This is a BYZANTINE FAULT - PoSe penalty applied.\n",
                      sig.proTxHash.ToString().substr(0, 16),
                      nHeight,
                      existingRecord.blockHash.ToString().substr(0, 16),
                      sig.blockHash.ToString().substr(0, 16));

            // TODO: Trigger PoSe penalty via deterministicMNManager
            // For now, we just log and track evidence

            return true;  // Double-sign detected
        }

        // Same block hash - this is a duplicate, not a double-sign
        return false;
    }

    // First signature from this MN at this height - record it
    SignatureRecord record;
    record.blockHash = sig.blockHash;
    record.vchSig = sig.vchSig;
    heightMap[sig.proTxHash] = record;

    return false;  // No double-sign
}

std::vector<CHuDoubleSignEvidence> CHuSlashingDetector::GetEvidence() const
{
    LOCK(cs);
    return vEvidence;
}

std::vector<CHuDoubleSignEvidence> CHuSlashingDetector::GetEvidenceForMN(const uint256& proTxHash) const
{
    LOCK(cs);
    std::vector<CHuDoubleSignEvidence> result;
    for (const auto& ev : vEvidence) {
        if (ev.proTxHash == proTxHash) {
            result.push_back(ev);
        }
    }
    return result;
}

bool CHuSlashingDetector::HasDoubleSignEvidence(const uint256& proTxHash) const
{
    LOCK(cs);
    for (const auto& ev : vEvidence) {
        if (ev.proTxHash == proTxHash) {
            return true;
        }
    }
    return false;
}

int CHuSlashingDetector::GetDoubleSignCount(const uint256& proTxHash) const
{
    LOCK(cs);
    int count = 0;
    for (const auto& ev : vEvidence) {
        if (ev.proTxHash == proTxHash) {
            count++;
        }
    }
    return count;
}

void CHuSlashingDetector::Cleanup(int nCurrentHeight)
{
    LOCK(cs);

    // Only cleanup every 50 blocks
    if (nCurrentHeight - nLastCleanupHeight < 50) {
        return;
    }
    nLastCleanupHeight = nCurrentHeight;

    // Remove signature records older than HISTORY_BLOCKS
    int cutoffHeight = nCurrentHeight - HISTORY_BLOCKS;
    auto it = mapHeightSignatures.begin();
    while (it != mapHeightSignatures.end()) {
        if (it->first < cutoffHeight) {
            it = mapHeightSignatures.erase(it);
        } else {
            ++it;
        }
    }

    LogPrint(BCLog::STATE, "Quorum Slashing: Cleanup complete. Tracking %zu heights, %zu evidence records\n",
             mapHeightSignatures.size(), vEvidence.size());
}

void CHuSlashingDetector::Clear()
{
    LOCK(cs);
    mapHeightSignatures.clear();
    vEvidence.clear();
    nLastCleanupHeight = 0;
}

UniValue CHuSlashingDetector::GetStats() const
{
    LOCK(cs);

    UniValue result(UniValue::VOBJ);
    result.pushKV("heights_tracked", (int)mapHeightSignatures.size());
    result.pushKV("evidence_count", (int)vEvidence.size());

    // Count unique offenders
    std::set<uint256> offenders;
    for (const auto& ev : vEvidence) {
        offenders.insert(ev.proTxHash);
    }
    result.pushKV("unique_offenders", (int)offenders.size());

    // Recent evidence (last 10)
    UniValue recentEvidence(UniValue::VARR);
    size_t start = vEvidence.size() > 10 ? vEvidence.size() - 10 : 0;
    for (size_t i = start; i < vEvidence.size(); i++) {
        recentEvidence.push_back(vEvidence[i].ToJSON());
    }
    result.pushKV("recent_evidence", recentEvidence);

    return result;
}

// ============================================================================
// Global Functions
// ============================================================================

void InitHuSlashing()
{
    huSlashingDetector = std::make_unique<CHuSlashingDetector>();
    LogPrintf("Quorum Slashing: Initialized\n");
}

void ShutdownHuSlashing()
{
    if (huSlashingDetector) {
        auto evidence = huSlashingDetector->GetEvidence();
        if (!evidence.empty()) {
            LogPrintf("Quorum Slashing: Shutdown with %zu double-sign evidence records\n",
                      evidence.size());
        }
    }
    huSlashingDetector.reset();
    LogPrintf("Quorum Slashing: Shutdown\n");
}

bool CheckHuDoubleSign(const CHuSignature& sig, int nHeight)
{
    if (!huSlashingDetector) {
        return true;  // Detector not initialized, allow signature
    }

    bool isDoubleSign = huSlashingDetector->CheckAndRecordSignature(sig, nHeight);

    if (isDoubleSign) {
        // Update metrics
        // Note: We could add a g_hu_metrics.doubleSignsDetected counter

        // Cleanup old data
        huSlashingDetector->Cleanup(nHeight);

        return false;  // Reject the signature
    }

    return true;  // Signature is OK
}

} // namespace hu
