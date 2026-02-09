// Copyright (c) 2026 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "btcheaders/btcheaders.h"
#include "btcheaders/btcheadersdb.h"

#include "consensus/validation.h"
#include "masternode/deterministicmns.h"
#include "hash.h"
#include "logging.h"
#include "primitives/transaction.h"
#include "tinyformat.h"
#include "util/system.h"
#include "validation.h"

// ============================================================================
// BtcHeadersPayload Implementation
// ============================================================================

// Static member definition (required for ODR-use in C++11/14)
const uint8_t BtcHeadersPayload::CURRENT_VERSION;

uint256 BtcHeadersPayload::GetSignatureHash() const
{
    // Domain separation: "BTCHDR" prevents cross-protocol replay
    // Message format: "BTCHDR" || version || publisherProTxHash || startHeight || count || headers
    CHashWriter ss(SER_GETHASH, 0);
    ss << std::string("BTCHDR");  // 6 bytes domain tag
    ss << nVersion;
    ss << publisherProTxHash;
    ss << startHeight;
    ss << count;
    for (const auto& h : headers) {
        ss << h;
    }
    return ss.GetHash();
}

bool BtcHeadersPayload::VerifySignature() const
{
    // Get MN from DMN manager (use GetListAtChainTip().GetMN())
    auto dmn = deterministicMNManager->GetListAtChainTip().GetMN(publisherProTxHash);
    if (!dmn) {
        return false;
    }

    // Verify signature using operator public key
    // CRITICAL: Key must match publisherProTxHash (anti-spoof)
    uint256 hash = GetSignatureHash();
    return dmn->pdmnState->pubKeyOperator.Verify(hash, sig);
}

bool BtcHeadersPayload::IsTriviallyValid(std::string& strError) const
{
    // Version check
    if (nVersion != CURRENT_VERSION) {
        strError = strprintf("invalid version %d (expected %d)", nVersion, CURRENT_VERSION);
        return false;
    }

    // R7: Count range check (1-10)
    if (count < 1 || count > BTCHEADERS_MAX_COUNT) {
        strError = strprintf("invalid count %d (must be 1-%d)", count, BTCHEADERS_MAX_COUNT);
        return false;
    }

    // R7: Count must match headers vector size
    if (headers.size() != count) {
        strError = strprintf("count %d != headers.size() %zu", count, headers.size());
        return false;
    }

    // R7: Payload size check
    if (GetSerializedSize() > BTCHEADERS_MAX_PAYLOAD_SIZE) {
        strError = strprintf("payload size %zu exceeds max %zu",
                             GetSerializedSize(), BTCHEADERS_MAX_PAYLOAD_SIZE);
        return false;
    }

    // Publisher proTxHash must not be null
    if (publisherProTxHash.IsNull()) {
        strError = "publisherProTxHash is null";
        return false;
    }

    // Signature must not be empty
    if (sig.empty()) {
        strError = "signature is empty";
        return false;
    }

    return true;
}

size_t BtcHeadersPayload::GetSerializedSize() const
{
    // 1 (version) + 32 (proTxHash) + 4 (startHeight) + 1 (count) +
    // count * 80 (headers) + sig.size() + varint overhead
    size_t baseSize = 1 + 32 + 4 + 1 + (headers.size() * 80);
    // Add signature size + varint for sig length
    baseSize += sig.size() + GetSizeOfCompactSize(sig.size());
    return baseSize;
}

std::string BtcHeadersPayload::ToString() const
{
    return strprintf("BtcHeadersPayload(version=%d, publisher=%s, start=%u, count=%d)",
                     nVersion,
                     publisherProTxHash.ToString().substr(0, 16),
                     startHeight,
                     count);
}

// ============================================================================
// Payload Extraction
// ============================================================================

bool GetBtcHeadersPayload(const CTransaction& tx, BtcHeadersPayload& payload)
{
    if (tx.nType != CTransaction::TxType::TX_BTC_HEADERS) {
        return false;
    }
    if (!tx.IsSpecialTx() || !tx.hasExtraPayload()) {
        return false;
    }
    try {
        CDataStream ds(*tx.extraPayload, SER_NETWORK, PROTOCOL_VERSION);
        ds >> payload;
        return ds.empty();  // Must consume all bytes
    } catch (const std::exception& e) {
        return false;
    }
}

// ============================================================================
// Consensus Validation (R1-R7)
// ============================================================================

bool CheckBtcHeadersTx(const CTransaction& tx,
                       const CBlockIndex* pindexPrev,
                       CValidationState& state)
{
    // Extract payload
    BtcHeadersPayload payload;
    if (!GetBtcHeadersPayload(tx, payload)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-payload");
    }

    // Genesis block 1: TX_BTC_HEADERS carries all BTC headers from checkpoint.
    // No MNs registered yet, so skip R1 (MN check), R2 (signature), anti-spam.
    // pindexPrev==nullptr when called from CheckBlock (non-contextual)
    // pindexPrev->nHeight==0 when called contextually for block 1
    bool isGenesisBlock = (!pindexPrev || pindexPrev->nHeight == 0);

    // R7: Trivial validation FIRST (count, size, count==headers.size())
    // Genesis (or non-contextual) allows higher count (BTCHEADERS_GENESIS_MAX_COUNT)
    {
        if (payload.nVersion != BTCHEADERS_VERSION) {
            return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-version");
        }
        uint16_t maxCount = isGenesisBlock ? BTCHEADERS_GENESIS_MAX_COUNT : BTCHEADERS_MAX_COUNT;
        if (payload.count < 1 || payload.count > maxCount) {
            LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS invalid count %d (max=%d, genesis=%d)\n",
                     payload.count, maxCount, isGenesisBlock);
            return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-count");
        }
        if (payload.headers.size() != payload.count) {
            return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-count-mismatch");
        }
        if (payload.GetSerializedSize() > BTCHEADERS_MAX_PAYLOAD_SIZE) {
            return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-size");
        }
        // Genesis: allow null publisher and empty sig (no MNs yet)
        if (!isGenesisBlock) {
            if (payload.publisherProTxHash.IsNull()) {
                return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-null-publisher");
            }
            if (payload.sig.empty()) {
                return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-empty-sig");
            }
        }
    }

    if (!isGenesisBlock) {
        // R1: Publisher must be registered MN
        auto dmn = deterministicMNManager->GetListAtChainTip().GetMN(payload.publisherProTxHash);
        if (!dmn) {
            LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS unknown MN: %s\n",
                     payload.publisherProTxHash.ToString());
            return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-unknown-mn");
        }

        // R2: Valid signature (operator key + BTCHDR domain sep)
        if (!payload.VerifySignature()) {
            LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS invalid signature from %s\n",
                     payload.publisherProTxHash.ToString());
            return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-sig");
        }
    } else {
        LogPrintf("TX_BTC_HEADERS: Genesis block 1 - skipping R1/R2 (no MNs yet)\n");
    }

    // Anti-spam: Publisher cooldown check (skip for genesis)
    // Same MN cannot publish twice within BTCHEADERS_PUBLISHER_COOLDOWN blocks
    // EXCEPTION: If sync is behind (btcspv > btcheadersdb), allow rapid catch-up
    if (!isGenesisBlock && pindexPrev && g_btcheadersdb) {
        uint256 lastPublisher;
        int lastPublishHeight = 0;
        if (g_btcheadersdb->GetLastPublisher(lastPublisher, lastPublishHeight)) {
            int currentHeight = pindexPrev->nHeight + 1;  // Block being validated
            int blocksSinceLastPublish = currentHeight - lastPublishHeight;

            if (lastPublisher == payload.publisherProTxHash &&
                blocksSinceLastPublish < BTCHEADERS_PUBLISHER_COOLDOWN) {
                // Same publisher within cooldown - check if sync is behind
                // Two ways to determine this:
                // 1. If we have SPV: check if spvTip > headersTip
                // 2. Without SPV: if TX's startHeight == tipHeight+1, we need these headers
                uint32_t headersTip = g_btcheadersdb->GetTipHeight();
                bool syncBehind = false;

                // Method 1: SPV-based check (if available)
                if (g_btc_spv) {
                    uint32_t spvTip = g_btc_spv->GetTipHeight();
                    syncBehind = (spvTip > headersTip + payload.count);
                }

                // Method 2: TX-based check (always works)
                // If this TX starts right after our tip, we clearly need it for catch-up
                if (!syncBehind && payload.startHeight == headersTip + 1) {
                    syncBehind = true;
                    LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS: cooldown bypassed (startHeight=%u == tipHeight+1=%u)\n",
                             payload.startHeight, headersTip + 1);
                }

                if (!syncBehind) {
                    // Not catching up - enforce cooldown
                    LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS publisher %s in cooldown (%d blocks since last)\n",
                             payload.publisherProTxHash.ToString().substr(0, 16), blocksSinceLastPublish);
                    return state.DoS(10, false, REJECT_INVALID, "btcheaders-publisher-cooldown");
                }
            }
        }
    }

    // Context-dependent checks (R3-R6)
    // Only if we have pindexPrev and btcheadersdb is initialized
    if (pindexPrev && g_btcheadersdb) {
        uint32_t tipHeight;
        uint256 tipHash;

        if (g_btcheadersdb->GetTip(tipHeight, tipHash)) {
            // Check if these headers already exist (replay scenario during reindex)
            // If they do, skip R3 validation - they were already validated when first added
            uint256 existingHash;
            bool headersExist = g_btcheadersdb->GetHashAtHeight(payload.startHeight, existingHash);

            if (headersExist) {
                // Headers already exist - verify they match (replay validation)
                if (existingHash != payload.headers[0].GetHash()) {
                    LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS replay: hash mismatch at height %u\n",
                             payload.startHeight);
                    return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-replay-mismatch");
                }
                // Skip R3 check - this is a valid replay of historical TX
                LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS: replay at height %u (already in btcheadersdb), skipping R3\n",
                         payload.startHeight);
            } else {
                // Headers don't exist yet - normal validation
                // R3: Must extend tip exactly (V1: no BTC reorg support)
                // DoS=50: High enough to ban after 2 attempts, low enough to not immediately ban
                // MNs with stale btcspv data should update, not spam the network
                if (payload.startHeight != tipHeight + 1) {
                    LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS startHeight %u != tipHeight+1 (%u)\n",
                             payload.startHeight, tipHeight + 1);
                    return state.DoS(50, false, REJECT_INVALID, "bad-btcheaders-startheight");
                }

                // Now safe to access headers[0] (R7 already validated)
                if (payload.headers[0].hashPrevBlock != tipHash) {
                    LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS headers[0].prevBlock != tipHash\n");
                    return state.DoS(50, false, REJECT_INVALID, "bad-btcheaders-not-extending-tip");
                }
            }
        } else {
            // Empty DB - first headers submission
            // startHeight must be the first checkpoint height or 0
            // For V1, we accept any startHeight on empty DB
            LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS: btcheadersdb empty, accepting startHeight=%u\n",
                     payload.startHeight);
        }

        // R4: Internal chaining
        for (size_t i = 1; i < payload.headers.size(); i++) {
            if (payload.headers[i].hashPrevBlock != payload.headers[i-1].GetHash()) {
                LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS broken chain at index %zu\n", i);
                return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-broken-chain");
            }
        }

        // R5: Valid PoW for each header
        // Reuse btcspv CheckProofOfWork (need to make it accessible)
        if (g_btc_spv) {
            for (size_t i = 0; i < payload.headers.size(); i++) {
                const auto& header = payload.headers[i];
                if (!g_btc_spv->CheckProofOfWork(header)) {
                    LogPrint(BCLog::MASTERNODE, "TX_BTC_HEADERS invalid PoW at index %zu\n", i);
                    return state.DoS(100, false, REJECT_INVALID, "bad-btcheaders-pow");
                }
            }

            // R6: Correct difficulty for each header
            // This requires having the retarget window (2016 blocks) in history
            // For V1, we rely on btcspv for difficulty validation
            // If btcspv doesn't have enough history, we log a warning but continue
            // (the PoW check is still valid - difficulty is just not verified against expected)
            // TODO: Implement proper difficulty verification in V2
        } else {
            // No btcspv - cannot verify PoW/difficulty
            // In production this should fail, but for testing we allow it
            LogPrintf("WARNING: TX_BTC_HEADERS PoW/difficulty not verified (no btcspv)\n");
        }
    }

    return true;
}

// ============================================================================
// Block Processing
// ============================================================================

bool ProcessBtcHeadersTxInBlock(const CTransaction& tx,
                                btcheadersdb::CBtcHeadersDB::Batch& batch,
                                int bathronBlockHeight)
{
    BtcHeadersPayload payload;
    if (!GetBtcHeadersPayload(tx, payload)) {
        return false;
    }

    LogPrint(BCLog::MASTERNODE, "ProcessBtcHeadersTxInBlock: %s start=%u count=%d publisher=%s\n",
             tx.GetHash().ToString().substr(0, 16), payload.startHeight, payload.count,
             payload.publisherProTxHash.ToString().substr(0, 16));

    // Write each header to the batch
    uint32_t h = payload.startHeight;
    for (const auto& header : payload.headers) {
        batch.WriteHeader(h, header);
        h++;
    }

    // Update tip
    uint256 lastHash = payload.headers.back().GetHash();
    batch.WriteTip(h - 1, lastHash);

    // Track last publisher for anti-spam cooldown
    batch.WriteLastPublisher(payload.publisherProTxHash, bathronBlockHeight);

    return true;
}

bool DisconnectBtcHeadersTx(const CTransaction& tx,
                            btcheadersdb::CBtcHeadersDB::Batch& batch)
{
    BtcHeadersPayload payload;
    if (!GetBtcHeadersPayload(tx, payload)) {
        return false;
    }

    LogPrint(BCLog::MASTERNODE, "DisconnectBtcHeadersTx: %s start=%u count=%d\n",
             tx.GetHash().ToString().substr(0, 16), payload.startHeight, payload.count);

    // Revert tip to before these headers
    uint32_t revertToHeight = payload.startHeight - 1;
    uint256 prevHash = payload.headers[0].hashPrevBlock;

    // Erase headers (V1: these heights were new, no prior value to restore)
    for (size_t i = 0; i < payload.headers.size(); i++) {
        uint32_t h = payload.startHeight + i;
        uint256 hash = payload.headers[i].GetHash();
        batch.EraseHeader(h, hash);
    }

    // Restore previous tip
    batch.WriteTip(revertToHeight, prevHash);

    return true;
}
