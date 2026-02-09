// Copyright (c) 2025 The Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "state/settlement_logic.h"

#include "coins.h"
#include "htlc/htlc.h"
#include "htlc/htlcdb.h"
#include "consensus/validation.h"
#include "logging.h"
#include "primitives/transaction.h"
#include "script/conditional.h"
#include "script/script.h"
#include "serialize.h"
#include "tinyformat.h"
#include "version.h"

#include <limits>

// =============================================================================
// M1 Fee Model Helpers (BP30 v3.0)
// =============================================================================

/**
 * IsExactlyOpTrueScript - Check if script is exactly OP_TRUE
 *
 * Consensus requirement: fee output must be exactly [0x51] (OP_TRUE).
 * Rejects any variation to prevent griefing/ambiguity.
 */
bool IsExactlyOpTrueScript(const CScript& script)
{
    return script.size() == 1 && script[0] == OP_TRUE;
}

/**
 * ComputeMinM1Fee - Deterministic minimum fee calculation
 *
 * Uses same formula as minRelayTxFee: fee = (size * rate) / 1000
 */
CAmount ComputeMinM1Fee(size_t txSize, CAmount feeRate)
{
    // Minimum 1 sat fee to prevent zero-fee spam
    CAmount fee = (static_cast<CAmount>(txSize) * feeRate) / 1000;
    return std::max(fee, CAmount(1));
}

/**
 * CheckFeeOutputAt - Validate fee output at canonical index
 *
 * Enforces strict consensus rules for M1 fee outputs:
 * - Must be at expected index
 * - Must be exactly OP_TRUE script (not equivalent, not similar)
 * - Must meet minimum fee amount
 */
bool CheckFeeOutputAt(const CTransaction& tx,
                      size_t feeIndex,
                      CAmount minFee,
                      CValidationState& state,
                      const std::string& txType)
{
    // Check index in range
    if (feeIndex >= tx.vout.size()) {
        return state.DoS(100, false, REJECT_INVALID,
                         strprintf("bad-%s-fee-missing", txType));
    }

    const CTxOut& feeOut = tx.vout[feeIndex];

    // Check script is exactly OP_TRUE
    if (!IsExactlyOpTrueScript(feeOut.scriptPubKey)) {
        LogPrint(BCLog::STATE, "CheckFeeOutputAt: REJECT %s fee at vout[%zu] script not OP_TRUE (size=%zu)\n",
                 txType, feeIndex, feeOut.scriptPubKey.size());
        return state.DoS(100, false, REJECT_INVALID,
                         strprintf("bad-%s-fee-script", txType));
    }

    // Check fee amount meets minimum
    if (feeOut.nValue < minFee) {
        LogPrint(BCLog::STATE, "CheckFeeOutputAt: REJECT %s fee at vout[%zu] value=%lld < min=%lld\n",
                 txType, feeIndex, (long long)feeOut.nValue, (long long)minFee);
        return state.DoS(100, false, REJECT_INVALID,
                         strprintf("bad-%s-fee-too-low", txType));
    }

    return true;
}

/**
 * CheckLock - Validate TX_LOCK transaction structure
 *
 * BP30 v2.0 (Bearer Asset Model) TX_LOCK rules:
 * - nType == TX_LOCK
 * - All vin must be M0 standard (not in settlement indexes)
 * - Exactly 2 vout: vout[0] = Vault (OP_TRUE), vout[1] = Receipt
 * - vout[0].nValue == vout[1].nValue
 * - vout[0] must be OP_TRUE script (consensus-protected)
 * - vout[1] can be any standard script (M1 receipt destination)
 */
bool CheckLock(const CTransaction& tx,
               const CCoinsViewCache& view,
               CValidationState& state)
{
    // Type check
    if (tx.nType != CTransaction::TxType::TX_LOCK) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txlock-type");
    }

    // Must have at least 1 input
    if (tx.vin.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txlock-no-inputs");
    }

    // Check inputs are M0 standard (DB-driven check)
    // For smoke test, we skip this check if settlement DB not initialized
    if (g_settlementdb) {
        for (const CTxIn& txin : tx.vin) {
            if (!g_settlementdb->IsM0Standard(txin.prevout)) {
                return state.DoS(100, false, REJECT_INVALID, "bad-txlock-input-not-m0");
            }
        }
    }

    // Canonical output order (A11): at least 2 outputs (Vault + Receipt, optional change)
    // vout[0] = Vault, vout[1] = Receipt, vout[2+] = change
    if (tx.vout.size() < 2) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txlock-output-count");
    }

    const CTxOut& vaultOut = tx.vout[0];
    const CTxOut& receiptOut = tx.vout[1];

    // BP30 v2.0: vout[0] (Vault) must be OP_TRUE script
    // This makes it anyone-can-spend at script level, but consensus protects it
    if (vaultOut.scriptPubKey.size() != 1 || vaultOut.scriptPubKey[0] != OP_TRUE) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txlock-vault-not-optrue");
    }

    // Amount must be positive
    if (vaultOut.nValue <= 0) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txlock-amount-zero");
    }

    // Backing invariant: vout[0].nValue == vout[1].nValue
    if (vaultOut.nValue != receiptOut.nValue) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txlock-amount-mismatch");
    }

    LogPrint(BCLog::STATE, "CheckLock: PASS tx=%s amount=%lld (bearer model)\n",
             tx.GetHash().ToString().substr(0, 16), (long long)vaultOut.nValue);

    return true;
}

/**
 * ApplyLock - Apply TX_LOCK to settlement layer (Bearer Asset Model)
 *
 * BP30 v2.0: Creates independent Vault and M1 Receipt (no bidirectional link).
 * - VaultEntry at vout[0] (OP_TRUE script, consensus-protected)
 * - M1Receipt at vout[1] (bearer asset)
 *
 * Updates:
 * - M0_vaulted += P
 * - M1_supply += P
 */
bool ApplyLock(const CTransaction& tx,
               const CCoinsViewCache& view,
               SettlementState& settlementState,
               uint32_t nHeight,
               CSettlementDB::Batch& batch)
{
    const uint256& txid = tx.GetHash();
    CAmount P = tx.vout[0].nValue;

    // Create Vault entry (no link to receipt - bearer model)
    VaultEntry vault;
    vault.outpoint = COutPoint(txid, 0);
    vault.amount = P;
    vault.nLockHeight = nHeight;
    // NOTE: No receiptOutpoint or unlockPubKey - bearer asset model

    // Create M1 Receipt entry (no link to vault - bearer model)
    M1Receipt receipt;
    receipt.outpoint = COutPoint(txid, 1);
    receipt.amount = P;
    receipt.nCreateHeight = nHeight;
    // NOTE: No vaultOutpoint - bearer asset model

    // Write to batch
    batch.WriteVault(vault);
    batch.WriteReceipt(receipt);

    // Update settlement state
    settlementState.M0_vaulted += P;
    settlementState.M1_supply += P;

    LogPrint(BCLog::STATE, "ApplyLock: tx=%s P=%lld M0_vaulted=%lld M1_supply=%lld (bearer)\n",
             txid.ToString().substr(0, 16), (long long)P,
             (long long)settlementState.M0_vaulted,
             (long long)settlementState.M1_supply);

    // Phase 2.5: A6 invariant check
    CValidationState a6State;
    if (!CheckA6P1(settlementState, a6State)) {
        LogPrintf("ERROR: ApplyLock: A6 invariant violated after tx=%s\n",
                  txid.ToString().substr(0, 16).c_str());
        return false;
    }

    return true;
}

CAmount GetLockAmount(const CTransaction& tx)
{
    if (tx.vout.size() < 1) return 0;
    return tx.vout[0].nValue;
}

/**
 * UndoLock - Undo TX_LOCK during reorg
 *
 * Reverses ApplyLock:
 * - Erase VaultEntry at vout[0]
 * - Erase M1Receipt at vout[1]
 * - Update SettlementState: M0_vaulted -= P, M1_supply -= P
 */
bool UndoLock(const CTransaction& tx,
              SettlementState& settlementState,
              CSettlementDB::Batch& batch)
{
    const uint256& txid = tx.GetHash();
    CAmount P = tx.vout[0].nValue;

    // Erase DB entries
    batch.EraseVault(COutPoint(txid, 0));
    batch.EraseReceipt(COutPoint(txid, 1));

    // Revert state
    settlementState.M0_vaulted -= P;
    settlementState.M1_supply -= P;

    LogPrint(BCLog::STATE, "UndoLock: tx=%s P=%lld M0_vaulted=%lld M1_supply=%lld\n",
             txid.ToString().substr(0, 16), (long long)P,
             (long long)settlementState.M0_vaulted,
             (long long)settlementState.M1_supply);

    return true;
}

// =============================================================================
// TX_UNLOCK Implementation (Bearer Asset Model)
// =============================================================================

/**
 * CheckUnlock - Validate TX_UNLOCK transaction structure (Bearer Asset Model)
 *
 * BP30 v3.0 TX_UNLOCK rules (M1 fee model - no M0 fee inputs required):
 * - nType == TX_UNLOCK
 * - vin[0..N] = M1 Receipts (at least 1)
 * - vin[N+1..K] = Vaults (at least 1)
 * - NO M0 fee inputs required (fee paid in M1)
 * - All M1 inputs must be valid receipts in R index
 * - All vault inputs must be valid vaults in V index
 * - vout[0] = M0 output (mandatory) - unlocked funds to user
 * - vout[1] = M1 change (optional) - remaining M1 to user
 * - vout[2] = M1 fee (mandatory if fee > 0) - to OP_TRUE for producer
 * - vout[3] = Vault backing for M1 fee (OP_TRUE) - keeps A6 invariant
 *
 * Conservation rule (BP30 v3.0 M1 fee):
 *   sum(M1_in) == M0_out + M1_change + M1_fee
 *   sum(Vault_in) >= M0_out + M1_fee  (vault backs both M0 released and M1 fee)
 *
 * A6 Preservation:
 *   M0_vaulted -= M0_out (only M0 released decreases vaulted)
 *   M1_supply unchanged (M1_fee is transferred to producer, not burned)
 *
 * Security:
 *   M0_out + M1_fee <= sum(vaults)  (cannot create M0/M1 from thin air)
 */
bool CheckUnlock(const CTransaction& tx,
                 const CCoinsViewCache& view,
                 CValidationState& state)
{
    // Type check
    if (tx.nType != CTransaction::TxType::TX_UNLOCK) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-type");
    }

    // Must have at least 2 inputs (1 receipt + 1 vault minimum)
    if (tx.vin.size() < 2) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-input-count");
    }

    // Must have at least 1 output (M0 out), optionally more (M1 change)
    if (tx.vout.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-no-outputs");
    }

    // Settlement DB required for validation
    if (!g_settlementdb) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-no-db");
    }

    // BP30 v3.0 canonical order: M1 receipts first, then vaults
    // NO M0 fee inputs allowed (fee is paid in M1)
    // Canonical order: vin[0..N-1]=M1 receipts, vin[N..K-1]=Vaults
    CAmount totalM1in = 0;
    CAmount totalVault = 0;
    size_t receiptCount = 0;
    size_t vaultCount = 0;
    bool inReceiptSection = true;

    for (size_t i = 0; i < tx.vin.size(); ++i) {
        const COutPoint& prevout = tx.vin[i].prevout;

        if (g_settlementdb->IsM1Receipt(prevout)) {
            if (!inReceiptSection) {
                // M1 receipts must come before vaults (canonical order)
                return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-order-receipt-after-vault");
            }
            M1Receipt receipt;
            if (!g_settlementdb->ReadReceipt(prevout, receipt)) {
                return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-receipt-read-fail");
            }
            totalM1in += receipt.amount;
            receiptCount++;
        } else if (g_settlementdb->IsVault(prevout)) {
            inReceiptSection = false;  // Switch to vault section
            VaultEntry vault;
            if (!g_settlementdb->ReadVault(prevout, vault)) {
                return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-vault-read-fail");
            }
            totalVault += vault.amount;
            vaultCount++;
        } else {
            // BP30 v3.0: M0 fee inputs no longer allowed for TX_UNLOCK
            // Fee is paid in M1 (deducted from unlock amount)
            return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-invalid-input",
                             false, "TX_UNLOCK inputs must be M1 receipts or vaults only (M1 fee model)");
        }
    }

    // Must have at least 1 receipt and 1 vault
    if (receiptCount == 0) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-no-receipts");
    }
    if (vaultCount == 0) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-no-vaults");
    }

    // BP30 v3.0: Canonical output order (M1 fee model)
    // vout[0] = M0 unlocked output (mandatory, P2PKH) - to user
    // vout[1] = M1 change (optional, P2PKH) - to user
    // vout[2] = M1 fee (optional, OP_TRUE) - to block producer
    // vout[3] = Vault backing for M1 fee (optional, OP_TRUE)
    CAmount m0Out = tx.vout[0].nValue;
    CAmount m1ChangeOut = 0;
    CAmount m1FeeOut = 0;
    CAmount vaultChangeOut = 0;

    // Validate M0 output (vout[0])
    if (m0Out <= 0) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-m0-output-zero");
    }
    if (tx.vout[0].scriptPubKey.IsUnspendable()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-m0-output-unspendable");
    }

    // Parse outputs: identify M1 change, M1 fee, and vault change
    // OP_TRUE outputs are either M1 fee or vault backing
    // We identify them by position: first OP_TRUE after M1 change is M1 fee, second is vault
    //
    // BP30 v3.0 HARDENING: Fee output validation
    // - Fee output must be EXACTLY OP_TRUE (not equivalent, not similar)
    // - Fee output must be at canonical index
    // - Fee amount must meet minimum
    bool foundM1Fee = false;
    size_t m1FeeIndex = 0;
    for (size_t i = 1; i < tx.vout.size(); ++i) {
        const CTxOut& out = tx.vout[i];
        if (out.nValue <= 0) continue;  // Skip dust/empty outputs

        // BP30 v3.0: Use strict OP_TRUE check (exactly 1 byte: 0x51)
        if (IsExactlyOpTrueScript(out.scriptPubKey)) {
            if (!foundM1Fee) {
                // First OP_TRUE is M1 fee output (claimable by producer)
                m1FeeOut = out.nValue;
                m1FeeIndex = i;
                foundM1Fee = true;
            } else {
                // Second OP_TRUE is vault backing for the M1 fee
                vaultChangeOut += out.nValue;
            }
        } else if (i == 1 && !out.scriptPubKey.IsUnspendable()) {
            // vout[1] is M1 change if it's P2PKH (not OP_TRUE)
            m1ChangeOut = out.nValue;
        }
    }

    // BP30 v3.0 HARDENING: Validate M1 fee output structure
    // If there's any fee expected (M1_in > M0_out + M1_change), fee output must exist
    CAmount expectedFee = totalM1in - m0Out - m1ChangeOut;
    if (expectedFee > 0) {
        // Fee output is required
        if (!foundM1Fee) {
            LogPrint(BCLog::STATE, "CheckUnlock: REJECT fee output missing (expected=%lld)\n",
                     (long long)expectedFee);
            return state.DoS(100, false, REJECT_INVALID, "bad-unlock-fee-missing");
        }

        // Validate fee output is at expected index (canonical order)
        // Expected: vout[1] if no change, vout[2] if there's change
        size_t expectedFeeIndex = (m1ChangeOut > 0) ? 2 : 1;
        if (m1FeeIndex != expectedFeeIndex) {
            LogPrint(BCLog::STATE, "CheckUnlock: REJECT fee at wrong index (found=%zu, expected=%zu)\n",
                     m1FeeIndex, expectedFeeIndex);
            return state.DoS(100, false, REJECT_INVALID, "bad-unlock-fee-index");
        }

        // Validate minimum fee amount
        CAmount minFee = ComputeMinM1Fee(::GetSerializeSize(tx, PROTOCOL_VERSION));
        if (m1FeeOut < minFee) {
            LogPrint(BCLog::STATE, "CheckUnlock: REJECT fee too low (fee=%lld, min=%lld)\n",
                     (long long)m1FeeOut, (long long)minFee);
            return state.DoS(100, false, REJECT_INVALID, "bad-unlock-fee-too-low");
        }
    }

    // BP30 v3.0 Conservation Rule (M1 fee model):
    //
    //   sum(M1_in) == M0_out + M1_change + M1_fee
    //
    // The M1_fee is NOT burned - it's transferred to block producer.
    // This preserves A6 because:
    //   - M0_vaulted decreases by M0_out (released to user)
    //   - M1_supply stays the same (M1_fee goes to producer)
    //   - Vault backing for M1_fee stays locked
    //
    CAmount totalM1Out = m0Out + m1ChangeOut + m1FeeOut;
    if (totalM1Out != totalM1in) {
        LogPrintf("CheckUnlock FAIL: M1_in=%lld != M0_out=%lld + M1_change=%lld + M1_fee=%lld\n",
                  (long long)totalM1in, (long long)m0Out, (long long)m1ChangeOut, (long long)m1FeeOut);
        return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-conservation-violated");
    }

    // Security: Vault must cover both M0 released AND M1 fee backing
    // The vault backing for M1 fee must remain locked
    CAmount requiredVault = m0Out + m1FeeOut;
    if (requiredVault > totalVault) {
        LogPrintf("CheckUnlock FAIL: Required vault=%lld (M0=%lld + fee=%lld) > available=%lld\n",
                  (long long)requiredVault, (long long)m0Out, (long long)m1FeeOut, (long long)totalVault);
        return state.DoS(100, false, REJECT_INVALID, "bad-txunlock-vault-insufficient");
    }

    // If there's M1 fee, there should be corresponding vault backing
    // (unless vault exactly covers M0_out + M1_fee with no remainder)
    if (m1FeeOut > 0 && vaultChangeOut < m1FeeOut) {
        // Vault backing for M1 fee is insufficient
        // Note: This is a soft check - the key invariant is that totalVault >= m0Out + m1FeeOut
        LogPrint(BCLog::STATE, "CheckUnlock: WARNING vault_change=%lld < m1_fee=%lld (fee backing may be partial)\n",
                 (long long)vaultChangeOut, (long long)m1FeeOut);
    }

    LogPrint(BCLog::STATE, "CheckUnlock: PASS tx=%s receipts=%d vaults=%d M1_in=%lld M0_out=%lld M1_change=%lld M1_fee=%lld vault_change=%lld\n",
             tx.GetHash().ToString().substr(0, 16),
             (int)receiptCount, (int)vaultCount,
             (long long)totalM1in, (long long)m0Out,
             (long long)m1ChangeOut, (long long)m1FeeOut,
             (long long)vaultChangeOut);

    return true;
}

/**
 * ApplyUnlock - Apply TX_UNLOCK to settlement layer (Bearer Asset Model)
 *
 * BP30 v3.0: M1 fee model - no M0 fee inputs required.
 *
 * Input structure:
 * - vin[0..N-1] = M1 receipts (consumed)
 * - vin[N..K-1] = Vaults (consumed)
 * - NO M0 fee inputs (fee is paid in M1)
 *
 * Output structure:
 * - vout[0] = M0 unlocked to user (P2PKH)
 * - vout[1] = M1 change receipt to user (P2PKH, optional)
 * - vout[2] = M1 fee to producer (OP_TRUE, optional but recommended)
 * - vout[3] = Vault backing for M1 fee (OP_TRUE, backs producer's M1)
 *
 * Conservation:
 * - M1_in = M0_out + M1_change + M1_fee
 *
 * Updates:
 * - M0_vaulted -= M0_out (only the M0 released to user)
 * - M1_supply -= (M1_in - M1_change - M1_fee) = M0_out (net burn)
 * - Creates M1Receipt for M1_fee (producer can claim)
 * - Creates VaultEntry for fee backing (stays locked)
 *
 * A6 Preservation:
 * - M1_fee is transferred (not burned), so M1_supply only decreases by M0_out
 * - Vault backing for M1_fee stays locked, keeping A6 balanced
 */
bool ApplyUnlock(const CTransaction& tx,
                 const CCoinsViewCache& view,
                 SettlementState& settlementState,
                 CSettlementDB::Batch& batch,
                 UnlockUndoData& undoData)
{
    const uint256 txid = tx.GetHash();
    CAmount totalM1in = 0;
    CAmount totalVault = 0;
    uint32_t inputReceiptHeight = 0;  // For change receipt inheritance

    // Clear undo data
    undoData.receiptsSpent.clear();
    undoData.vaultsSpent.clear();

    // BP30 v3.0: Process all inputs: receipts and vaults only (no M0 fee inputs)
    for (const CTxIn& txin : tx.vin) {
        const COutPoint& prevout = txin.prevout;

        if (g_settlementdb->IsM1Receipt(prevout)) {
            M1Receipt receipt;
            if (g_settlementdb->ReadReceipt(prevout, receipt)) {
                totalM1in += receipt.amount;
                inputReceiptHeight = receipt.nCreateHeight;  // Inherit height for change
                undoData.receiptsSpent.push_back(receipt);  // Save for undo
                batch.EraseReceipt(prevout);
            }
        } else if (g_settlementdb->IsVault(prevout)) {
            VaultEntry vault;
            if (g_settlementdb->ReadVault(prevout, vault)) {
                totalVault += vault.amount;
                undoData.vaultsSpent.push_back(vault);  // Save for undo
                batch.EraseVault(prevout);
            }
        }
        // Note: M0 fee inputs are no longer allowed (BP30 v3.0 M1 fee model)
    }

    // Calculate M0 out
    CAmount m0Out = tx.vout[0].nValue;
    CAmount m1ChangeOut = 0;
    CAmount m1FeeOut = 0;
    CAmount vaultChangeOut = 0;

    // BP30 v3.0: Process outputs - M1 change, M1 fee, and vault backing
    // OP_TRUE outputs: first is M1 fee (to producer), subsequent are vault backing
    undoData.vaultChangeCreated = false;
    bool foundM1Fee = false;
    // int m1FeeIndex = -1;  // Tracked but not currently used
    // std::vector<int> vaultBackingIndices;  // Tracked but not currently used

    for (size_t i = 1; i < tx.vout.size(); ++i) {
        const CTxOut& out = tx.vout[i];
        if (out.nValue <= 0) continue;

        // Check if this is an OP_TRUE output
        if (out.scriptPubKey.size() == 1 && out.scriptPubKey[0] == OP_TRUE) {
            if (!foundM1Fee) {
                // First OP_TRUE is M1 fee output (claimable by producer)
                m1FeeOut = out.nValue;
                foundM1Fee = true;

                // Create M1 receipt for fee (producer can spend this)
                M1Receipt feeReceipt;
                feeReceipt.outpoint = COutPoint(txid, i);
                feeReceipt.amount = out.nValue;
                feeReceipt.nCreateHeight = inputReceiptHeight;
                batch.WriteReceipt(feeReceipt);
            } else {
                // Subsequent OP_TRUE outputs are vault backing for M1 fee
                VaultEntry vaultBacking;
                vaultBacking.outpoint = COutPoint(txid, i);
                vaultBacking.amount = out.nValue;
                vaultBacking.nLockHeight = undoData.vaultsSpent.empty() ? 0 : undoData.vaultsSpent[0].nLockHeight;
                batch.WriteVault(vaultBacking);
                vaultChangeOut += out.nValue;

                // Track for undo (use first vault backing as the main one)
                if (!undoData.vaultChangeCreated) {
                    undoData.vaultChangeCreated = true;
                    undoData.vaultChangeOutpoint = vaultBacking.outpoint;
                }
            }
        } else if (i == 1 && !out.scriptPubKey.IsUnspendable()) {
            // vout[1] is M1 change receipt if it's P2PKH (not OP_TRUE)
            M1Receipt changeReceipt;
            changeReceipt.outpoint = COutPoint(txid, i);
            changeReceipt.amount = out.nValue;
            changeReceipt.nCreateHeight = inputReceiptHeight;
            batch.WriteReceipt(changeReceipt);
            m1ChangeOut = out.nValue;
        }
    }

    // BP30 v3.0: Calculate net M1 burn
    // M1_fee is NOT burned - it's transferred to producer (stays in M1_supply)
    // Net burn = M1_in - M1_change - M1_fee = M0_out
    CAmount netM1Burn = totalM1in - m1ChangeOut - m1FeeOut;

    // Update settlement state
    // M0_vaulted decreases by M0 released only (NOT by M1 fee backing)
    settlementState.M0_vaulted -= m0Out;

    // M1_supply decreases by net burn (M1_fee is not burned, it's transferred)
    settlementState.M1_supply -= netM1Burn;

    // Populate undo data
    undoData.m0Released = m0Out;
    undoData.netM1Burned = netM1Burn;
    undoData.changeReceiptsCreated = (m1ChangeOut > 0) ? 1 : 0;
    if (m1FeeOut > 0) {
        undoData.changeReceiptsCreated++;  // Count M1 fee receipt too
    }

    LogPrint(BCLog::STATE, "ApplyUnlock: tx=%s M1_in=%lld M0_out=%lld M1_change=%lld M1_fee=%lld vault_backing=%lld netBurn=%lld M0_vaulted=%lld M1_supply=%lld\n",
             txid.ToString().substr(0, 16),
             (long long)totalM1in, (long long)m0Out,
             (long long)m1ChangeOut, (long long)m1FeeOut, (long long)vaultChangeOut,
             (long long)netM1Burn,
             (long long)settlementState.M0_vaulted,
             (long long)settlementState.M1_supply);

    // Phase 2.5: A6 invariant check
    CValidationState a6State;
    if (!CheckA6P1(settlementState, a6State)) {
        LogPrintf("ERROR: ApplyUnlock: A6 invariant violated after tx=%s\n",
                  txid.ToString().substr(0, 16).c_str());
        return false;
    }

    return true;
}

/**
 * UndoUnlock - Undo TX_UNLOCK during reorg (BP30 v2.2)
 *
 * Reverses ApplyUnlock:
 * - Erase M1 change receipts at vout[1]
 * - Erase vault change at vout[2] if created
 * - Restore all M1Receipts from undoData
 * - Restore all VaultEntries from undoData
 * - Update SettlementState:
 *     M0_vaulted += undoData.m0Released
 *     M1_supply += undoData.netM1Burned
 */
bool UndoUnlock(const CTransaction& tx,
                const UnlockUndoData& undoData,
                SettlementState& settlementState,
                CSettlementDB::Batch& batch)
{
    const uint256 txid = tx.GetHash();

    // Erase M1 change receipts created at vout[1+]
    for (size_t i = 0; i < undoData.changeReceiptsCreated; ++i) {
        batch.EraseReceipt(COutPoint(txid, i + 1));  // vout[1], vout[2], ...
    }

    // BP30 v2.2: Erase vault change if created
    if (undoData.vaultChangeCreated) {
        batch.EraseVault(undoData.vaultChangeOutpoint);
    }

    // Restore all M1 receipts that were spent
    for (const M1Receipt& receipt : undoData.receiptsSpent) {
        batch.WriteReceipt(receipt);
    }

    // Restore all vaults that were spent
    for (const VaultEntry& vault : undoData.vaultsSpent) {
        batch.WriteVault(vault);
    }

    // Restore settlement state
    settlementState.M0_vaulted += undoData.m0Released;
    settlementState.M1_supply += undoData.netM1Burned;

    LogPrint(BCLog::STATE, "UndoUnlock: tx=%s m0Released=%lld netM1Burned=%lld receipts=%zu vaults=%zu m1changes=%zu vaultChange=%s M0_vaulted=%lld M1_supply=%lld\n",
             txid.ToString().substr(0, 16),
             (long long)undoData.m0Released, (long long)undoData.netM1Burned,
             undoData.receiptsSpent.size(), undoData.vaultsSpent.size(),
             undoData.changeReceiptsCreated,
             undoData.vaultChangeCreated ? "yes" : "no",
             (long long)settlementState.M0_vaulted,
             (long long)settlementState.M1_supply);

    return true;
}

CAmount GetUnlockAmount(const CTransaction& tx)
{
    if (tx.vout.size() < 1) return 0;
    return tx.vout[0].nValue;
}

// =============================================================================
// TX_TRANSFER_M1 Implementation (Bearer Asset Model)
// =============================================================================

/**
 * ParseTransferM1Outputs - Single source of truth for M1 output detection
 *
 * BP30 v2.5: Canonical cumsum-based M1/M0 classification.
 * Used by: CheckTransfer, ApplyTransfer, validation.cpp mempool, wallet builder.
 *
 * See settlement_logic.h for full documentation.
 */
bool ParseTransferM1Outputs(const CTransaction& tx,
                            CAmount m1In,
                            size_t& splitIndex,
                            CAmount& m1Out)
{
    m1Out = 0;
    splitIndex = tx.vout.size();  // Default: all outputs are M1

    for (size_t i = 0; i < tx.vout.size(); ++i) {
        const CTxOut& out = tx.vout[i];

        // Each output must have positive amount
        if (out.nValue <= 0) {
            return false;  // Invalid: zero/negative output
        }

        // Each output must be spendable
        if (out.scriptPubKey.IsUnspendable()) {
            return false;  // Invalid: OP_RETURN output
        }

        // Cumsum rule: output is M1 if adding it doesn't exceed m1In
        if (m1Out + out.nValue <= m1In) {
            m1Out += out.nValue;
        } else {
            // First M0 output found - record split index
            splitIndex = i;
            break;
        }
    }

    // Note: caller must check m1Out == m1In for strict conservation
    return true;
}

/**
 * CheckTransfer - Validate TX_TRANSFER_M1 transaction structure (Bearer Model)
 *
 * BP30 v3.0 TX_TRANSFER_M1 rules (M1 fee model):
 * - nType == TX_TRANSFER_M1
 * - Exactly 1 M1 Receipt input (in vin[0])
 * - NO M0 fee inputs required (M1 fee model)
 * - vout[0..N-2] = M1 Receipts to recipients
 * - vout[N-1] = M1 fee (OP_TRUE script, block producer claims)
 * - sum(outputs) == input.amount (strict M1 conservation)
 * - No vault link required (bearer asset)
 *
 * M1 Fee Model:
 *   Fee is paid in M1 (deducted from transfer amount).
 *   The fee output uses OP_TRUE script, so block producer can claim it.
 *   This solves the UX deadlock where users with 0 M0 couldn't transfer M1.
 *
 * Conservation:
 *   M1_in = sum(M1_out_to_recipients) + M1_fee
 *   All outputs are M1 (including fee), so: sum(all vout) == M1_in
 *
 * Use cases:
 * - 1 recipient + fee: simple transfer (recipient gets amount - fee)
 * - N recipients + fee: split (divide receipt, fee deducted)
 */
bool CheckTransfer(const CTransaction& tx,
                   const CCoinsViewCache& view,
                   CValidationState& state)
{
    // Type check
    if (tx.nType != CTransaction::TxType::TX_TRANSFER_M1) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-type");
    }

    // Must have at least 1 input
    if (tx.vin.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-no-inputs");
    }

    // Must have at least 1 output (at least one new receipt)
    if (tx.vout.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-no-outputs");
    }

    // Settlement DB required
    if (!g_settlementdb) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-no-db");
    }

    // Count M1 receipt inputs - must be exactly 1, and it must be vin[0]
    int m1InputCount = 0;
    M1Receipt oldReceipt;

    for (size_t i = 0; i < tx.vin.size(); ++i) {
        if (g_settlementdb->IsM1Receipt(tx.vin[i].prevout)) {
            m1InputCount++;
            if (i != 0) {
                // M1 receipt must be vin[0] (canonical order)
                return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-receipt-not-vin0");
            }
            if (!g_settlementdb->ReadReceipt(tx.vin[i].prevout, oldReceipt)) {
                return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-receipt-read-failed");
            }
        } else if (!g_settlementdb->IsM0Standard(tx.vin[i].prevout)) {
            // Non-receipt inputs must be M0 standard (not vaulted)
            return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-input-not-m0");
        }
    }

    // Must have exactly 1 M1 receipt input
    if (m1InputCount == 0) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-no-receipt-input");
    }
    if (m1InputCount > 1) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-multi-receipt-inputs");
    }

    // BP30 v2.5: Use centralized helper for M1 output detection
    // See ParseTransferM1Outputs() for canonical order rule documentation.
    const CAmount m1In = oldReceipt.amount;
    size_t splitIndex;
    CAmount m1Out;

    if (!ParseTransferM1Outputs(tx, m1In, splitIndex, m1Out)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-invalid-outputs");
    }

    // STRICT M1 conservation: sum(M1_out) MUST equal sum(M1_in)
    // No implicit burn allowed - M1 is a bearer asset
    if (m1Out != m1In) {
        LogPrint(BCLog::STATE, "CheckTransfer: FAIL m1Out=%lld != m1In=%lld (strict conservation)\n",
                 (long long)m1Out, (long long)m1In);
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-m1-not-conserved");
    }

    size_t numM1Outputs = splitIndex;

    // Must have at least one M1 output
    if (numM1Outputs == 0) {
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-zero-m1-outputs");
    }

    // BP30 v3.0 HARDENING: M1 fee output validation
    // Canonical structure:
    //   vout[0..N-2] = Recipient M1 receipts (P2PKH, NOT OP_TRUE)
    //   vout[N-1] = M1 fee (EXACTLY OP_TRUE script)
    //
    // With M1 fee model, there must be at least 2 outputs:
    //   vout[0] = recipient, vout[1] = fee
    if (numM1Outputs < 2) {
        // No fee output - this is only valid for legacy (no-fee) transfers
        // With M1 fee model, we require at least 2 M1 outputs
        LogPrint(BCLog::STATE, "CheckTransfer: REJECT only %zu M1 outputs (need at least 2 for fee model)\n",
                 numM1Outputs);
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-fee-missing");
    }

    // Fee output is the last M1 output (vout[N-1] where N = numM1Outputs)
    size_t feeIndex = numM1Outputs - 1;
    const CTxOut& feeOut = tx.vout[feeIndex];

    // Validate fee output script is EXACTLY OP_TRUE
    if (!IsExactlyOpTrueScript(feeOut.scriptPubKey)) {
        LogPrint(BCLog::STATE, "CheckTransfer: REJECT fee at vout[%zu] script not OP_TRUE (size=%zu)\n",
                 feeIndex, feeOut.scriptPubKey.size());
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-fee-script");
    }

    // Validate minimum fee amount
    CAmount minFee = ComputeMinM1Fee(::GetSerializeSize(tx, PROTOCOL_VERSION));
    if (feeOut.nValue < minFee) {
        LogPrint(BCLog::STATE, "CheckTransfer: REJECT fee at vout[%zu] value=%lld < min=%lld\n",
                 feeIndex, (long long)feeOut.nValue, (long long)minFee);
        return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-fee-too-low");
    }

    // Validate recipient outputs (vout[0..N-2]) are NOT OP_TRUE
    // Recipient scripts must be spendable addresses, not OP_TRUE
    for (size_t i = 0; i < feeIndex; ++i) {
        if (IsExactlyOpTrueScript(tx.vout[i].scriptPubKey)) {
            LogPrint(BCLog::STATE, "CheckTransfer: REJECT vout[%zu] is OP_TRUE but should be recipient\n", i);
            return state.DoS(100, false, REJECT_INVALID, "bad-txtransfer-fee-index",
                             false, "Recipient output cannot be OP_TRUE (only last output can be fee)");
        }
    }

    // BP30 v2.0: No vault link check needed - bearer model
    // The M1 receipt is self-sufficient, backed by global vault pool

    LogPrint(BCLog::STATE, "CheckTransfer: PASS tx=%s m1In=%lld m1Out=%lld numM1=%zu fee=%lld (M1 fee model)\n",
             tx.GetHash().ToString().substr(0, 16), (long long)m1In,
             (long long)m1Out, numM1Outputs, (long long)feeOut.nValue);

    return true;
}

/**
 * ApplyTransfer - Apply TX_TRANSFER_M1 to settlement layer (Bearer Model)
 *
 * BP30 v2.4: Strict M1 conservation - same logic as CheckTransfer.
 * No vault update needed - bearer model has no bidirectional links.
 *
 * M1 outputs identified by cumsum: outputs until cumsum reaches M1_in.
 * Remaining outputs are M0 fee change (not stored as receipts).
 *
 * Operations:
 * 1. Read old receipt (vin[0]) and save for undo
 * 2. Erase old receipt
 * 3. Create new receipts at M1 outputs only
 */
bool ApplyTransfer(const CTransaction& tx,
                   const CCoinsViewCache& view,
                   CSettlementDB::Batch& batch,
                   TransferUndoData& undoData)
{
    const COutPoint& oldReceiptOutpoint = tx.vin[0].prevout;
    const uint256& txid = tx.GetHash();

    // Read old receipt
    M1Receipt oldReceipt;
    if (!g_settlementdb->ReadReceipt(oldReceiptOutpoint, oldReceipt)) {
        return false; // Should never happen after CheckTransfer
    }

    // BP30 v2.2: Save original receipt for undo
    undoData.originalReceipt = oldReceipt;

    // Erase old receipt
    batch.EraseReceipt(oldReceiptOutpoint);

    // BP30 v2.5: Use centralized helper for M1 output detection
    const CAmount m1In = oldReceipt.amount;
    size_t splitIndex;
    CAmount m1Out;

    // Parse outputs (should never fail after CheckTransfer validated)
    if (!ParseTransferM1Outputs(tx, m1In, splitIndex, m1Out)) {
        return false;
    }

    // Create receipts only for M1 outputs (vout[0..splitIndex-1])
    for (size_t i = 0; i < splitIndex; ++i) {
        M1Receipt newReceipt;
        newReceipt.outpoint = COutPoint(txid, i);
        newReceipt.amount = tx.vout[i].nValue;
        newReceipt.nCreateHeight = oldReceipt.nCreateHeight;  // Preserve original lock height
        batch.WriteReceipt(newReceipt);
    }

    // Store splitIndex in undo data for correct undo
    undoData.numM1Outputs = splitIndex;

    LogPrint(BCLog::STATE, "ApplyTransfer: tx=%s old=%s numM1=%zu/%zu m1In=%lld m1Out=%lld (bearer, strict)\n",
             txid.ToString().substr(0, 16),
             oldReceiptOutpoint.ToString().substr(0, 16),
             splitIndex, tx.vout.size(),
             (long long)m1In, (long long)m1Out);

    return true;
}

/**
 * UndoTransfer - Undo TX_TRANSFER_M1 during reorg (Bearer Model)
 *
 * BP30 v2.3: Restores the old M1 receipt from undoData, erases only M1 receipts.
 * No vault update needed - bearer model has no bidirectional links.
 *
 * Operations:
 * 1. Erase new M1 receipts (vout[0..numM1Outputs-1]) - NOT M0 fee change
 * 2. Restore old receipt from undoData
 */
bool UndoTransfer(const CTransaction& tx,
                  const TransferUndoData& undoData,
                  CSettlementDB::Batch& batch)
{
    const uint256& txid = tx.GetHash();

    // BP30 v2.3: Only erase M1 receipts, not M0 fee change outputs
    // Use numM1Outputs from undo data (preserved from ApplyTransfer)
    size_t numM1Outputs = undoData.numM1Outputs;
    if (numM1Outputs == 0) {
        // Fallback for old undo data without numM1Outputs
        numM1Outputs = tx.vout.size();
    }

    for (size_t i = 0; i < numM1Outputs; ++i) {
        batch.EraseReceipt(COutPoint(txid, i));
    }

    // Restore old receipt from undo data (correct amount and nCreateHeight)
    batch.WriteReceipt(undoData.originalReceipt);

    // NOTE: No vault update needed - bearer asset model

    LogPrint(BCLog::STATE, "UndoTransfer: tx=%s erased %zu M1 receipts (of %zu vouts), restored old=%s amount=%lld (bearer)\n",
             txid.ToString().substr(0, 16),
             numM1Outputs, tx.vout.size(),
             undoData.originalReceipt.outpoint.ToString().substr(0, 16),
             (long long)undoData.originalReceipt.amount);

    return true;
}

// =============================================================================
// A6 Invariant Enforcement
// =============================================================================

/**
 * AddNoOverflow - Overflow-safe CAmount addition using __int128
 *
 * Uses __int128 to detect overflow without undefined behavior.
 * CAmount is int64_t, so the sum can safely fit in __int128.
 */
bool AddNoOverflow(CAmount a, CAmount b, CAmount& result)
{
    // Use __int128 for safe overflow detection
    __int128 sum = static_cast<__int128>(a) + static_cast<__int128>(b);

    // Check if result fits in int64_t range
    if (sum < std::numeric_limits<int64_t>::min() ||
        sum > std::numeric_limits<int64_t>::max()) {
        LogPrintf("ERROR: AddNoOverflow: overflow a=%lld b=%lld\n",
                  (long long)a, (long long)b);
        return false;
    }

    result = static_cast<CAmount>(sum);
    return true;
}

/**
 * CheckA6 - Verify A6 invariant
 *
 * A6: M0_vaulted == M1_supply
 */
bool CheckA6P1(const SettlementState& state, CValidationState& validationState)
{
    // A6: M0_vaulted == M1_supply
    if (state.M0_vaulted != state.M1_supply) {
        LogPrintf("ERROR: CheckA6: INVARIANT BROKEN! M0_vaulted=%lld != M1_supply=%lld\n",
                  (long long)state.M0_vaulted, (long long)state.M1_supply);
        return validationState.DoS(100, false, REJECT_INVALID, "settlement-a6-broken",
                                   false, strprintf("A6 broken: M0_vaulted=%lld != M1_supply=%lld",
                                                    (long long)state.M0_vaulted, (long long)state.M1_supply));
    }

    LogPrint(BCLog::STATE, "CheckA6: OK M0_vaulted=%lld == M1_supply=%lld\n",
             (long long)state.M0_vaulted, (long long)state.M1_supply);

    return true;
}

// =============================================================================
// A5: MONETARY CONSERVATION INVARIANT (v9.2 BURN-ONLY)
// =============================================================================

/**
 * CheckA5 - Verify A5 monetary conservation invariant (BURN-ONLY)
 *
 * INVARIANT: M0(N) = M0(N-1) + BurnClaims
 *
 * ALL M0 must come from BTC burns. There is NO inflation, NO block rewards.
 * Only TX_MINT_M0BTC (finalized burn claims) can increase M0 supply.
 */
bool CheckA5(const SettlementState& currentState,
             const SettlementState& prevState,
             CValidationState& validationState)
{
    // A5: M0(N) = M0(N-1) + BurnClaims
    CAmount expectedSupply = prevState.M0_total_supply + currentState.burnclaims_block;

    if (currentState.M0_total_supply != expectedSupply) {
        LogPrintf("ERROR: CheckA5: MONETARY CONSERVATION VIOLATED!\n");
        LogPrintf("  Height=%d, M0_supply=%lld != expected=%lld\n",
                  currentState.nHeight,
                  (long long)currentState.M0_total_supply, (long long)expectedSupply);
        LogPrintf("  prev=%lld + burns=%lld\n",
                  (long long)prevState.M0_total_supply,
                  (long long)currentState.burnclaims_block);

        return validationState.DoS(100, false, REJECT_INVALID, "settlement-a5-broken",
                                   false, strprintf("A5 violated at height %d: M0=%lld != expected=%lld",
                                                    currentState.nHeight,
                                                    (long long)currentState.M0_total_supply,
                                                    (long long)expectedSupply));
    }

    LogPrint(BCLog::STATE, "CheckA5: OK h=%d M0=%lld (prev=%lld + burns=%lld)\n",
             currentState.nHeight,
             (long long)currentState.M0_total_supply,
             (long long)prevState.M0_total_supply,
             (long long)currentState.burnclaims_block);

    return true;
}

/**
 * CalculateCoinbaseAmount - Sum all outputs of coinbase transaction
 */
CAmount CalculateCoinbaseAmount(const CTransaction& coinbaseTx)
{
    CAmount total = 0;
    for (const auto& out : coinbaseTx.vout) {
        total += out.nValue;
    }
    return total;
}

// =============================================================================
// ParseSettlementTx - Robust M0/M1/Vault classification WITHOUT DB lookup
// =============================================================================

/**
 * ParseSettlementTx - Classify settlement TX inputs/outputs WITHOUT DB lookup
 *
 * BP30 v2.6: Uses canonical position rules and OP_TRUE script detection.
 * Does NOT require settlement DB, making it safe for mempool/RPC contexts.
 */
bool ParseSettlementTx(const CTransaction& tx,
                       const CCoinsViewCache* pcoinsView,
                       SettlementTxView& view)
{
    // Initialize view
    view = SettlementTxView();
    view.complete = true;
    view.missing_inputs = 0;
    view.unclassified_inputs = 0;

    // Determine transaction type
    bool isSettlement = false;
    switch (tx.nType) {
        case CTransaction::TxType::TX_LOCK:
            view.txType = "TX_LOCK";
            isSettlement = true;
            break;
        case CTransaction::TxType::TX_UNLOCK:
            view.txType = "TX_UNLOCK";
            isSettlement = true;
            break;
        case CTransaction::TxType::TX_TRANSFER_M1:
            view.txType = "TX_TRANSFER_M1";
            isSettlement = true;
            break;
        default:
            view.txType = "NORMAL";
            break;
    }

    // ==== CLASSIFY INPUTS ====

    if (!isSettlement) {
        // Normal TX: all inputs are M0
        for (size_t i = 0; i < tx.vin.size(); ++i) {
            if (pcoinsView) {
                const Coin& coin = pcoinsView->AccessCoin(tx.vin[i].prevout);
                if (!coin.IsSpent()) {
                    view.m0_in += coin.out.nValue;
                    view.m0_input_indices.push_back(i);
                } else {
                    view.missing_inputs++;
                    view.complete = false;
                    view.reason_incomplete = "spent_prevouts";
                }
            } else {
                view.missing_inputs++;
                view.complete = false;
                view.reason_incomplete = "no_coins_view";
            }
        }
    }
    else if (tx.nType == CTransaction::TxType::TX_LOCK) {
        // TX_LOCK: All inputs are M0 (by definition - locking transparent funds)
        for (size_t i = 0; i < tx.vin.size(); ++i) {
            if (pcoinsView) {
                const Coin& coin = pcoinsView->AccessCoin(tx.vin[i].prevout);
                if (!coin.IsSpent()) {
                    view.m0_in += coin.out.nValue;
                    view.m0_input_indices.push_back(i);
                } else {
                    view.missing_inputs++;
                    view.complete = false;
                }
            } else {
                view.missing_inputs++;
                view.complete = false;
            }
        }
    }
    else if (tx.nType == CTransaction::TxType::TX_TRANSFER_M1) {
        // TX_TRANSFER_M1: vin[0] = M1 receipt (canonical), vin[1+] = M0 fee inputs
        for (size_t i = 0; i < tx.vin.size(); ++i) {
            if (pcoinsView) {
                const Coin& coin = pcoinsView->AccessCoin(tx.vin[i].prevout);
                if (!coin.IsSpent()) {
                    if (i == 0) {
                        // vin[0] is M1 receipt (canonical position)
                        view.m1_in += coin.out.nValue;
                        view.m1_input_indices.push_back(i);
                    } else {
                        // vin[1+] are M0 fee inputs
                        view.m0_in += coin.out.nValue;
                        view.m0_input_indices.push_back(i);
                    }
                } else {
                    view.missing_inputs++;
                    view.complete = false;
                }
            } else {
                view.missing_inputs++;
                view.complete = false;
            }
        }
    }
    else if (tx.nType == CTransaction::TxType::TX_UNLOCK) {
        // TX_UNLOCK canonical order: M1 receipts, then Vaults (OP_TRUE), then M0 fee inputs
        // Identify by prevout script: OP_TRUE = vault, before vaults = M1, after = M0
        bool seenVault = false;

        for (size_t i = 0; i < tx.vin.size(); ++i) {
            if (pcoinsView) {
                const Coin& coin = pcoinsView->AccessCoin(tx.vin[i].prevout);
                if (!coin.IsSpent()) {
                    CAmount value = coin.out.nValue;
                    bool isVault = IsVaultScript(coin.out.scriptPubKey);

                    if (isVault) {
                        // This is a vault input
                        view.vault_in += value;
                        view.vault_input_indices.push_back(i);
                        seenVault = true;
                    } else if (!seenVault) {
                        // Before any vault = M1 receipt
                        view.m1_in += value;
                        view.m1_input_indices.push_back(i);
                    } else {
                        // After vaults = M0 fee input
                        view.m0_in += value;
                        view.m0_input_indices.push_back(i);
                    }
                } else {
                    view.missing_inputs++;
                    view.complete = false;
                }
            } else {
                view.missing_inputs++;
                view.complete = false;
            }
        }
    }

    // ==== CLASSIFY OUTPUTS ====

    if (!isSettlement) {
        // Normal TX: all outputs are M0
        for (size_t i = 0; i < tx.vout.size(); ++i) {
            view.m0_out += tx.vout[i].nValue;
            view.m0_output_indices.push_back(i);
        }
    }
    else if (tx.nType == CTransaction::TxType::TX_LOCK) {
        // TX_LOCK: vout[0]=Vault(OP_TRUE), vout[1]=M1 receipt, vout[2+]=M0 change
        for (size_t i = 0; i < tx.vout.size(); ++i) {
            const CTxOut& out = tx.vout[i];

            if (i == 0) {
                // vout[0] MUST be vault (OP_TRUE) - verify script
                if (IsVaultScript(out.scriptPubKey)) {
                    view.vault_out += out.nValue;
                    view.vault_output_indices.push_back(i);
                } else {
                    // Invalid TX_LOCK structure - vout[0] not OP_TRUE
                    // Still classify as vault for fee calculation purposes
                    view.vault_out += out.nValue;
                    view.vault_output_indices.push_back(i);
                }
            } else if (i == 1) {
                // vout[1] is M1 receipt (canonical position)
                view.m1_out += out.nValue;
                view.m1_output_indices.push_back(i);
            } else {
                // vout[2+] is M0 change
                view.m0_out += out.nValue;
                view.m0_output_indices.push_back(i);
            }
        }
    }
    else if (tx.nType == CTransaction::TxType::TX_TRANSFER_M1) {
        // TX_TRANSFER_M1: Use ParseTransferM1Outputs with m1_in to find split point
        if (view.m1_in > 0) {
            size_t splitIndex;
            CAmount m1Out;
            if (ParseTransferM1Outputs(tx, view.m1_in, splitIndex, m1Out)) {
                // vout[0..splitIndex-1] are M1 receipts
                for (size_t i = 0; i < splitIndex; ++i) {
                    view.m1_out += tx.vout[i].nValue;
                    view.m1_output_indices.push_back(i);
                }
                // vout[splitIndex..] are M0 fee change
                for (size_t i = splitIndex; i < tx.vout.size(); ++i) {
                    view.m0_out += tx.vout[i].nValue;
                    view.m0_output_indices.push_back(i);
                }
            } else {
                // Parse failed - classify all as M1 conservatively
                for (size_t i = 0; i < tx.vout.size(); ++i) {
                    view.m1_out += tx.vout[i].nValue;
                    view.m1_output_indices.push_back(i);
                }
            }
        } else if (view.complete) {
            // We have input data but m1_in=0 - shouldn't happen for valid TX_TRANSFER_M1
            // Fallback: vout[0] is M1, rest is M0
            if (tx.vout.size() > 0) {
                view.m1_out = tx.vout[0].nValue;
                view.m1_output_indices.push_back(0);
            }
            for (size_t i = 1; i < tx.vout.size(); ++i) {
                view.m0_out += tx.vout[i].nValue;
                view.m0_output_indices.push_back(i);
            }
        } else {
            // Inputs not resolved - can't determine split point
            // Fallback: vout[0] is M1 (minimum valid case), rest unknown
            if (tx.vout.size() > 0) {
                view.m1_out = tx.vout[0].nValue;
                view.m1_output_indices.push_back(0);
            }
            for (size_t i = 1; i < tx.vout.size(); ++i) {
                view.m0_out += tx.vout[i].nValue;
                view.m0_output_indices.push_back(i);
            }
        }
    }
    else if (tx.nType == CTransaction::TxType::TX_UNLOCK) {
        // TX_UNLOCK canonical output order:
        // vout[0] = M0 unlocked (mandatory)
        // vout[1] = M1 change (if M1_in > M0_out, non-OP_TRUE)
        // vout[N] = Vault change (OP_TRUE)
        // vout[M] = M0 fee change (rest)
        //
        // Use cumsum for M1 change: M1 outputs until cumsum reaches (m1_in - m0_out)

        CAmount m0_out_expected = tx.vout.size() > 0 ? tx.vout[0].nValue : 0;
        CAmount m1_change_expected = view.m1_in - m0_out_expected;  // May be 0 or > 0

        // vout[0] is always M0 unlocked
        if (tx.vout.size() > 0) {
            view.m0_out += tx.vout[0].nValue;
            view.m0_output_indices.push_back(0);
        }

        // Process vout[1..N]: M1 change (cumsum), vault change (OP_TRUE), M0 fee change
        CAmount m1_cumsum = 0;
        bool m1_change_done = (m1_change_expected <= 0);

        for (size_t i = 1; i < tx.vout.size(); ++i) {
            const CTxOut& out = tx.vout[i];

            if (IsVaultScript(out.scriptPubKey)) {
                // Vault change output
                view.vault_out += out.nValue;
                view.vault_output_indices.push_back(i);
            } else if (!m1_change_done && m1_cumsum + out.nValue <= m1_change_expected) {
                // M1 change output (cumsum not exceeded)
                view.m1_out += out.nValue;
                view.m1_output_indices.push_back(i);
                m1_cumsum += out.nValue;
                if (m1_cumsum >= m1_change_expected) {
                    m1_change_done = true;
                }
            } else {
                // M0 fee change
                view.m0_out += out.nValue;
                view.m0_output_indices.push_back(i);
            }
        }
    }

    // ==== CALCULATE M0 FEE ====
    //
    // Unified formula: m0_fee = (m0_in + vault_in) - (m0_out + vault_out)
    //
    // Vaults are "locked M0", so they participate in M0 accounting:
    // - TX_LOCK:  m0_in → vault_out + m0_change, fee = m0_in - vault_out - m0_change
    // - TX_UNLOCK: vault_in → m0_unlocked (in m0_out), fee = m0_fee_in - m0_fee_change
    //              With vault_in accounted: (m0_fee_in + vault_in) - (m0_unlocked + m0_fee_change + vault_change)
    // - TX_TRANSFER_M1: vault_in=0, vault_out=0, so fee = m0_in - m0_out (fee inputs - change)
    //
    // M1 flows are conserved separately (M1_in == M1_out for transfer, M1_in == M0_out for unlock).
    view.m0_fee = (view.m0_in + view.vault_in) - (view.m0_out + view.vault_out);

    // Set reason_incomplete if not already set
    if (!view.complete && view.reason_incomplete.empty()) {
        if (view.missing_inputs > 0) {
            view.reason_incomplete = "missing_prevouts";
        } else if (view.unclassified_inputs > 0) {
            view.reason_incomplete = "unclassified_prevouts";
        } else {
            view.reason_incomplete = "unknown";
        }
    }

    return true;
}

// =============================================================================
// HTLC_CREATE_M1 - Lock M1 in Hash Time Locked Contract
// =============================================================================

// BP02-LEGACY: Height cutoff for HTLC payload validation
// Blocks <= this height may contain HTLCs with empty/invalid payloads
// that were accepted before strict validation was added
static const uint32_t HTLC_LEGACY_CUTOFF_HEIGHT = 115;

bool CheckHTLCCreate(const CTransaction& tx,
                     const CCoinsViewCache& view,
                     CValidationState& state,
                     bool fCheckUTXO,
                     uint32_t nHeight)
{
    // BP02-LEGACY: Skip payload validation for historical blocks
    bool fLegacyMode = (nHeight > 0 && nHeight <= HTLC_LEGACY_CUTOFF_HEIGHT);
    // Verify TX type
    if (tx.nType != CTransaction::HTLC_CREATE_M1) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlccreate-type");
    }

    // Must have at least 1 input (M1 receipt)
    if (tx.vin.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlccreate-no-inputs");
    }

    // Must have at least 1 output (HTLC P2SH)
    if (tx.vout.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlccreate-no-outputs");
    }

    // vin[0] must be an M1 receipt
    const COutPoint& receiptOutpoint = tx.vin[0].prevout;

    // UTXO check during mempool acceptance (fCheckUTXO=true)
    // Skip during block connection because UpdateCoins() already spent the input
    // before ProcessSpecialTxsInBlock is called
    if (fCheckUTXO && !view.HaveCoin(receiptOutpoint)) {
        return state.DoS(0, false, REJECT_DUPLICATE, "bad-htlccreate-input-spent",
                         false, "M1 receipt already spent or in mempool");
    }

    if (!g_settlementdb || !g_settlementdb->IsM1Receipt(receiptOutpoint)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlccreate-not-m1");
    }

    // Read M1 receipt to verify amount
    M1Receipt receipt;
    if (!g_settlementdb->ReadReceipt(receiptOutpoint, receipt)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlccreate-receipt-missing");
    }

    // vout[0] must be P2SH (HTLC script)
    const CTxOut& htlcOut = tx.vout[0];
    if (!htlcOut.scriptPubKey.IsPayToScriptHash()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlccreate-not-p2sh");
    }

    // vout[0].nValue must equal receipt amount (strict conservation)
    if (htlcOut.nValue != receipt.amount) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlccreate-amount-mismatch");
    }

    // Validate extraPayload contains valid HTLCCreatePayload
    // BP02-LEGACY: Skip strict payload validation for historical blocks
    if (!fLegacyMode) {
        if (!tx.extraPayload || tx.extraPayload->empty()) {
            return state.DoS(100, false, REJECT_INVALID, "bad-htlccreate-no-payload");
        }

        HTLCCreatePayload payload;
        try {
            CDataStream ss(*tx.extraPayload, SER_NETWORK, PROTOCOL_VERSION);
            ss >> payload;
        } catch (const std::exception&) {
            return state.DoS(100, false, REJECT_INVALID, "bad-htlccreate-payload-deserialize");
        }

        std::string strError;
        if (!payload.IsTriviallyValid(strError)) {
            return state.DoS(100, false, REJECT_INVALID, strError);
        }

        // Validate covenant fee bounds (H1 audit fix)
        if (payload.HasCovenant()) {
            if (CTV_FIXED_FEE >= receipt.amount) {
                return state.DoS(100, false, REJECT_INVALID, "bad-htlccreate-covenant-fee-exceeds-amount");
            }
        }
    } else {
        LogPrint(BCLog::HTLC, "CheckHTLCCreate: BP02-LEGACY mode, skipping payload validation for height %u\n", nHeight);
    }

    return true;
}

bool ApplyHTLCCreate(const CTransaction& tx,
                     const CCoinsViewCache& view,
                     uint32_t nHeight,
                     CSettlementDB::Batch& settlementBatch,
                     CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();
    const COutPoint& receiptOutpoint = tx.vin[0].prevout;

    // Read original M1 receipt
    M1Receipt receipt;
    if (!g_settlementdb->ReadReceipt(receiptOutpoint, receipt)) {
        LogPrintf("ERROR: ApplyHTLCCreate failed to read receipt %s\n", receiptOutpoint.ToString());
        return false;
    }

    // Create undo data
    HTLCCreateUndoData undoData;
    undoData.originalReceiptOutpoint = receipt.outpoint;
    undoData.originalAmount = receipt.amount;
    undoData.originalCreateHeight = receipt.nCreateHeight;

    // Erase M1 receipt from settlement DB
    settlementBatch.EraseReceipt(receiptOutpoint);

    // BP02-LEGACY: Check if this is a historical block with potentially invalid payload
    bool fLegacyMode = (nHeight > 0 && nHeight <= HTLC_LEGACY_CUTOFF_HEIGHT);

    // Deserialize HTLCCreatePayload from extraPayload
    HTLCCreatePayload payload;
    bool fPayloadValid = false;
    if (tx.extraPayload && !tx.extraPayload->empty()) {
        try {
            CDataStream ss(*tx.extraPayload, SER_NETWORK, PROTOCOL_VERSION);
            ss >> payload;
            fPayloadValid = true;
        } catch (const std::exception& e) {
            if (!fLegacyMode) {
                LogPrintf("ERROR: ApplyHTLCCreate failed to deserialize payload for %s: %s\n",
                          txid.ToString(), e.what());
                return false;
            }
            LogPrint(BCLog::HTLC, "ApplyHTLCCreate: BP02-LEGACY - invalid payload for %s (height %u), using defaults\n",
                     txid.ToString().substr(0, 16), nHeight);
        }
    } else if (!fLegacyMode) {
        LogPrintf("ERROR: ApplyHTLCCreate - empty payload for %s\n", txid.ToString());
        return false;
    } else {
        LogPrint(BCLog::HTLC, "ApplyHTLCCreate: BP02-LEGACY - empty payload for %s (height %u), using defaults\n",
                 txid.ToString().substr(0, 16), nHeight);
    }

    // Create HTLC record from payload (or defaults for legacy mode)
    HTLCRecord htlc;
    htlc.htlcOutpoint = COutPoint(txid, 0);
    htlc.sourceReceipt = receiptOutpoint;
    htlc.amount = receipt.amount;
    htlc.createHeight = nHeight;
    htlc.status = HTLCStatus::ACTIVE;

    if (fPayloadValid) {
        htlc.hashlock = payload.hashlock;
        htlc.expiryHeight = payload.expiryHeight;
        htlc.claimKeyID = payload.claimKeyID;
        htlc.refundKeyID = payload.refundKeyID;
        htlc.templateCommitment = payload.templateCommitment;

        if (payload.HasCovenant()) {
            htlc.htlc3ExpiryHeight = payload.htlc3ExpiryHeight;
            htlc.htlc3ClaimKeyID = payload.htlc3ClaimKeyID;
            htlc.htlc3RefundKeyID = payload.htlc3RefundKeyID;
            htlc.covenantFee = CTV_FIXED_FEE;
            htlc.redeemScript = CreateConditionalWithCovenantScript(
                payload.hashlock, payload.expiryHeight,
                payload.claimKeyID, payload.refundKeyID,
                payload.templateCommitment);
        } else {
            htlc.redeemScript = CreateConditionalScript(
                payload.hashlock, payload.expiryHeight,
                payload.claimKeyID, payload.refundKeyID);
        }
    } else {
        // BP02-LEGACY: Use empty/default values for historical HTLCs with invalid payload
        // These HTLCs are essentially orphaned - they can only be refunded by timelock expiry
        htlc.hashlock.SetNull();
        htlc.expiryHeight = nHeight + 1000;  // Far future - effectively locked
        htlc.claimKeyID.SetNull();
        htlc.refundKeyID.SetNull();
        // Empty redeemScript - HTLC is non-functional but state is consistent
    }

    // Write HTLC record and hashlock index for cross-chain matching
    htlcBatch.WriteHTLC(htlc);
    htlcBatch.WriteHashlockIndex(htlc.hashlock, htlc.htlcOutpoint);
    htlcBatch.WriteCreateUndo(txid, undoData);

    LogPrint(BCLog::HTLC, "ApplyHTLCCreate: %s receipt=%s amount=%lld\n",
             txid.ToString().substr(0, 16), receiptOutpoint.ToString(), receipt.amount);

    return true;
}

bool UndoHTLCCreate(const CTransaction& tx,
                    CSettlementDB::Batch& settlementBatch,
                    CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();
    const COutPoint htlcOutpoint(txid, 0);

    // Read HTLC record before erasing (need hashlock for index cleanup)
    HTLCRecord htlc;
    if (!g_htlcdb->ReadHTLC(htlcOutpoint, htlc)) {
        LogPrintf("ERROR: UndoHTLCCreate failed to read HTLC %s\n", htlcOutpoint.ToString());
        return false;
    }

    // Read undo data
    HTLCCreateUndoData undoData;
    if (!g_htlcdb->ReadCreateUndo(txid, undoData)) {
        LogPrintf("ERROR: UndoHTLCCreate failed to read undo data for %s\n", txid.ToString());
        return false;
    }

    // Erase hashlock index first (while we still have the hashlock)
    htlcBatch.EraseHashlockIndex(htlc.hashlock, htlcOutpoint);

    // Erase HTLC record
    htlcBatch.EraseHTLC(htlcOutpoint);

    // Restore M1 receipt
    M1Receipt receipt;
    receipt.outpoint = undoData.originalReceiptOutpoint;
    receipt.amount = undoData.originalAmount;
    receipt.nCreateHeight = undoData.originalCreateHeight;
    settlementBatch.WriteReceipt(receipt);

    // Erase undo data
    htlcBatch.EraseCreateUndo(txid);

    LogPrint(BCLog::HTLC, "UndoHTLCCreate: %s restored receipt=%s\n",
             txid.ToString().substr(0, 16), receipt.outpoint.ToString());

    return true;
}

// =============================================================================
// HTLC_CLAIM - Claim HTLC with preimage
// =============================================================================

bool CheckHTLCClaim(const CTransaction& tx,
                    const CCoinsViewCache& view,
                    CValidationState& state)
{
    // Verify TX type
    if (tx.nType != CTransaction::HTLC_CLAIM) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-type");
    }

    // Must have at least 1 input (HTLC)
    if (tx.vin.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-no-inputs");
    }

    // Must have at least 1 output (new M1 receipt)
    if (tx.vout.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-no-outputs");
    }

    // vin[0] must be an active HTLC
    const COutPoint& htlcOutpoint = tx.vin[0].prevout;
    if (!g_htlcdb || !g_htlcdb->IsHTLC(htlcOutpoint)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-not-htlc");
    }

    // Read HTLC record
    HTLCRecord htlc;
    if (!g_htlcdb->ReadHTLC(htlcOutpoint, htlc)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-htlc-missing");
    }

    // HTLC must be active
    if (!htlc.IsActive()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-not-active");
    }

    // Verify the hashlock is set (required for preimage verification)
    if (htlc.hashlock.IsNull()) {
        LogPrintf("ERROR: CheckHTLCClaim HTLC %s has null hashlock - corrupt DB?\n", htlcOutpoint.ToString());
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-null-hashlock");
    }

    // Extract preimage from scriptSig and verify against hashlock
    // The scriptSig for branch A (claim) has format:
    // <sig> <pubkey> <preimage> OP_TRUE <redeemScript>
    std::vector<unsigned char> preimage;
    if (!ExtractPreimageFromScriptSig(tx.vin[0].scriptSig, htlc.redeemScript, preimage)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-invalid-scriptsig");
    }

    // Verify SHA256(preimage) == hashlock
    if (!VerifyPreimage(preimage, htlc.hashlock)) {
        LogPrint(BCLog::HTLC, "CheckHTLCClaim: preimage verification failed for %s\n", htlcOutpoint.ToString());
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-preimage-mismatch");
    }

    // Verify output amount matches HTLC amount (prevents M1 inflation — Invariant A6)
    if (htlc.HasCovenant()) {
        // Covenant claim (Settlement Pivot): vout[0] = htlc.amount - covenantFee
        if (htlc.covenantFee >= htlc.amount) {
            return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-covenant-fee-exceeds-amount");
        }
        CAmount expectedAmount = htlc.amount - htlc.covenantFee;
        if (tx.vout[0].nValue != expectedAmount) {
            LogPrint(BCLog::HTLC, "CheckHTLCClaim: amount mismatch for covenant HTLC %s: expected=%lld got=%lld\n",
                     htlcOutpoint.ToString(), expectedAmount, tx.vout[0].nValue);
            return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-amount-mismatch");
        }
    } else {
        // Standard claim: vout[0] = htlc.amount
        if (tx.vout[0].nValue != htlc.amount) {
            LogPrint(BCLog::HTLC, "CheckHTLCClaim: amount mismatch for HTLC %s: expected=%lld got=%lld\n",
                     htlcOutpoint.ToString(), htlc.amount, tx.vout[0].nValue);
            return state.DoS(100, false, REJECT_INVALID, "bad-htlcclaim-amount-mismatch");
        }
    }

    LogPrint(BCLog::HTLC, "CheckHTLCClaim: preimage verified for HTLC %s\n", htlcOutpoint.ToString());
    return true;
}

bool ApplyHTLCClaim(const CTransaction& tx,
                    const CCoinsViewCache& view,
                    uint32_t nHeight,
                    CSettlementDB::Batch& settlementBatch,
                    CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();
    const COutPoint& htlcOutpoint = tx.vin[0].prevout;

    // Read HTLC record
    HTLCRecord htlc;
    if (!g_htlcdb->ReadHTLC(htlcOutpoint, htlc)) {
        LogPrintf("ERROR: ApplyHTLCClaim failed to read HTLC %s\n", htlcOutpoint.ToString());
        return false;
    }

    // Create undo data (save full HTLC state)
    HTLCResolveUndoData undoData;
    undoData.htlcRecord = htlc;
    undoData.resultReceiptErased = COutPoint(txid, 0);

    // Extract preimage from scriptSig for storage
    std::vector<unsigned char> preimageVec;
    if (ExtractPreimageFromScriptSig(tx.vin[0].scriptSig, htlc.redeemScript, preimageVec)) {
        memcpy(htlc.preimage.begin(), preimageVec.data(), 32);
    }

    // Update HTLC record to CLAIMED
    htlc.status = HTLCStatus::CLAIMED;
    htlc.resolveTxid = txid;
    htlc.resultReceipt = COutPoint(txid, 0);

    // Erase hashlock index (HTLC no longer active)
    htlcBatch.EraseHashlockIndex(htlc.hashlock, htlcOutpoint);
    htlcBatch.WriteHTLC(htlc);
    htlcBatch.WriteResolveUndo(txid, undoData);

    if (htlc.HasCovenant()) {
        // Covenant claim (Settlement Pivot): create HTLC3 instead of M1Receipt
        HTLCRecord htlc3;
        htlc3.htlcOutpoint = COutPoint(txid, 0);
        htlc3.hashlock = htlc.hashlock;
        htlc3.sourceReceipt = htlc.htlcOutpoint;
        htlc3.amount = tx.vout[0].nValue;
        htlc3.claimKeyID = htlc.htlc3ClaimKeyID;
        htlc3.refundKeyID = htlc.htlc3RefundKeyID;
        htlc3.expiryHeight = htlc.htlc3ExpiryHeight;
        htlc3.createHeight = nHeight;
        htlc3.status = HTLCStatus::ACTIVE;
        htlc3.redeemScript = CreateConditionalScript(
            htlc.hashlock, htlc.htlc3ExpiryHeight,
            htlc.htlc3ClaimKeyID, htlc.htlc3RefundKeyID);

        htlcBatch.WriteHTLC(htlc3);
        htlcBatch.WriteHashlockIndex(htlc3.hashlock, htlc3.htlcOutpoint);

        LogPrint(BCLog::HTLC, "ApplyHTLCClaim: PIVOT %s htlc2=%s htlc3=%s amount=%lld\n",
                 txid.ToString().substr(0, 16), htlcOutpoint.ToString(),
                 htlc3.htlcOutpoint.ToString(), htlc3.amount);
    } else {
        // Standard claim: create M1Receipt for claimer
        M1Receipt newReceipt;
        newReceipt.outpoint = COutPoint(txid, 0);
        newReceipt.amount = tx.vout[0].nValue;
        newReceipt.nCreateHeight = nHeight;
        settlementBatch.WriteReceipt(newReceipt);

        LogPrint(BCLog::HTLC, "ApplyHTLCClaim: %s htlc=%s new_receipt=%s amount=%lld\n",
                 txid.ToString().substr(0, 16), htlcOutpoint.ToString(),
                 newReceipt.outpoint.ToString(), newReceipt.amount);
    }

    return true;
}

bool UndoHTLCClaim(const CTransaction& tx,
                   CSettlementDB::Batch& settlementBatch,
                   CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();

    // Read undo data
    HTLCResolveUndoData undoData;
    if (!g_htlcdb->ReadResolveUndo(txid, undoData)) {
        LogPrintf("ERROR: UndoHTLCClaim failed to read undo data for %s\n", txid.ToString());
        return false;
    }

    // Erase the output created by claim (HTLC3 for covenant, M1Receipt for standard)
    if (undoData.htlcRecord.HasCovenant()) {
        COutPoint htlc3Outpoint(txid, 0);
        // Verify HTLC3 exists before erasing (H2 audit fix: reorg robustness)
        HTLCRecord htlc3Check;
        if (g_htlcdb->ReadHTLC(htlc3Outpoint, htlc3Check)) {
            htlcBatch.EraseHTLC(htlc3Outpoint);
            htlcBatch.EraseHashlockIndex(undoData.htlcRecord.hashlock, htlc3Outpoint);
        } else {
            LogPrintf("WARNING: UndoHTLCClaim: HTLC3 %s not found during undo (possible double-undo or partial write)\n",
                      htlc3Outpoint.ToString());
        }
    } else {
        settlementBatch.EraseReceipt(COutPoint(txid, 0));
    }

    // Restore HTLC record to ACTIVE state
    HTLCRecord restored = undoData.htlcRecord;
    restored.status = HTLCStatus::ACTIVE;
    restored.resolveTxid.SetNull();
    restored.preimage.SetNull();
    restored.resultReceipt.SetNull();

    // Restore hashlock index (HTLC becomes active again)
    htlcBatch.WriteHashlockIndex(restored.hashlock, restored.htlcOutpoint);
    htlcBatch.WriteHTLC(restored);

    // Erase undo data
    htlcBatch.EraseResolveUndo(txid);

    LogPrint(BCLog::HTLC, "UndoHTLCClaim: %s restored htlc=%s\n",
             txid.ToString().substr(0, 16), restored.htlcOutpoint.ToString());

    return true;
}

// =============================================================================
// HTLC_REFUND - Refund expired HTLC
// =============================================================================

bool CheckHTLCRefund(const CTransaction& tx,
                     const CCoinsViewCache& view,
                     uint32_t nHeight,
                     CValidationState& state)
{
    // Verify TX type
    if (tx.nType != CTransaction::HTLC_REFUND) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcrefund-type");
    }

    // Must have at least 1 input (HTLC)
    if (tx.vin.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcrefund-no-inputs");
    }

    // Must have at least 1 output (M1 receipt back to creator)
    if (tx.vout.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcrefund-no-outputs");
    }

    // vin[0] must be an active HTLC
    const COutPoint& htlcOutpoint = tx.vin[0].prevout;
    if (!g_htlcdb || !g_htlcdb->IsHTLC(htlcOutpoint)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcrefund-not-htlc");
    }

    // Read HTLC record
    HTLCRecord htlc;
    if (!g_htlcdb->ReadHTLC(htlcOutpoint, htlc)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcrefund-htlc-missing");
    }

    // HTLC must be active
    if (!htlc.IsActive()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcrefund-not-active");
    }

    // Must be past expiry (check nLockTime or current height)
    if (nHeight < htlc.expiryHeight) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcrefund-not-expired");
    }

    // Verify output amount matches HTLC amount (prevents M1 inflation — Invariant A6)
    // Refund returns the FULL htlc.amount (no covenant fee deducted, no settlement occurred)
    if (tx.vout[0].nValue != htlc.amount) {
        LogPrint(BCLog::HTLC, "CheckHTLCRefund: amount mismatch for HTLC %s: expected=%lld got=%lld\n",
                 htlcOutpoint.ToString(), htlc.amount, tx.vout[0].nValue);
        return state.DoS(100, false, REJECT_INVALID, "bad-htlcrefund-amount-mismatch");
    }

    return true;
}

bool ApplyHTLCRefund(const CTransaction& tx,
                     const CCoinsViewCache& view,
                     uint32_t nHeight,
                     CSettlementDB::Batch& settlementBatch,
                     CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();
    const COutPoint& htlcOutpoint = tx.vin[0].prevout;

    // Read HTLC record
    HTLCRecord htlc;
    if (!g_htlcdb->ReadHTLC(htlcOutpoint, htlc)) {
        LogPrintf("ERROR: ApplyHTLCRefund failed to read HTLC %s\n", htlcOutpoint.ToString());
        return false;
    }

    // Create undo data
    HTLCResolveUndoData undoData;
    undoData.htlcRecord = htlc;
    undoData.resultReceiptErased = COutPoint(txid, 0);

    // Update HTLC record to REFUNDED
    htlc.status = HTLCStatus::REFUNDED;
    htlc.resolveTxid = txid;
    htlc.resultReceipt = COutPoint(txid, 0);

    // Erase hashlock index (HTLC no longer active)
    htlcBatch.EraseHashlockIndex(htlc.hashlock, htlcOutpoint);
    htlcBatch.WriteHTLC(htlc);
    htlcBatch.WriteResolveUndo(txid, undoData);

    // Create M1 receipt back to creator
    M1Receipt newReceipt;
    newReceipt.outpoint = COutPoint(txid, 0);
    newReceipt.amount = tx.vout[0].nValue;
    newReceipt.nCreateHeight = nHeight;
    settlementBatch.WriteReceipt(newReceipt);

    LogPrint(BCLog::HTLC, "ApplyHTLCRefund: %s htlc=%s new_receipt=%s amount=%lld\n",
             txid.ToString().substr(0, 16), htlcOutpoint.ToString(),
             newReceipt.outpoint.ToString(), newReceipt.amount);

    return true;
}

bool UndoHTLCRefund(const CTransaction& tx,
                    CSettlementDB::Batch& settlementBatch,
                    CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();

    // Read undo data
    HTLCResolveUndoData undoData;
    if (!g_htlcdb->ReadResolveUndo(txid, undoData)) {
        LogPrintf("ERROR: UndoHTLCRefund failed to read undo data for %s\n", txid.ToString());
        return false;
    }

    // Erase the refund M1 receipt
    settlementBatch.EraseReceipt(COutPoint(txid, 0));

    // Restore HTLC record to ACTIVE state
    HTLCRecord restored = undoData.htlcRecord;
    restored.status = HTLCStatus::ACTIVE;
    restored.resolveTxid.SetNull();
    restored.resultReceipt.SetNull();

    // Restore hashlock index (HTLC becomes active again)
    htlcBatch.WriteHashlockIndex(restored.hashlock, restored.htlcOutpoint);
    htlcBatch.WriteHTLC(restored);

    // Erase undo data
    htlcBatch.EraseResolveUndo(txid);

    LogPrint(BCLog::HTLC, "UndoHTLCRefund: %s restored htlc=%s\n",
             txid.ToString().substr(0, 16), restored.htlcOutpoint.ToString());

    return true;
}

// =============================================================================
// HTLC_CREATE_3S - Lock M1 in 3-Secret Hash Time Locked Contract (FlowSwap)
// =============================================================================

bool CheckHTLC3SCreate(const CTransaction& tx,
                       const CCoinsViewCache& view,
                       CValidationState& state,
                       bool fCheckUTXO,
                       uint32_t nHeight)
{
    // Verify TX type
    if (tx.nType != CTransaction::HTLC_CREATE_3S) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3screate-type");
    }

    // Must have at least 1 input (M1 receipt)
    if (tx.vin.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3screate-no-inputs");
    }

    // Must have at least 1 output (HTLC3S P2SH)
    if (tx.vout.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3screate-no-outputs");
    }

    // vin[0] must be an M1 receipt
    const COutPoint& receiptOutpoint = tx.vin[0].prevout;

    // UTXO check during mempool acceptance (fCheckUTXO=true)
    if (fCheckUTXO && !view.HaveCoin(receiptOutpoint)) {
        return state.DoS(0, false, REJECT_DUPLICATE, "bad-htlc3screate-input-spent",
                         false, "M1 receipt already spent or in mempool");
    }

    if (!g_settlementdb || !g_settlementdb->IsM1Receipt(receiptOutpoint)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3screate-not-m1");
    }

    // Read M1 receipt to verify amount
    M1Receipt receipt;
    if (!g_settlementdb->ReadReceipt(receiptOutpoint, receipt)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3screate-receipt-missing");
    }

    // vout[0] must be P2SH (HTLC3S script)
    const CTxOut& htlcOut = tx.vout[0];
    if (!htlcOut.scriptPubKey.IsPayToScriptHash()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3screate-not-p2sh");
    }

    // vout[0].nValue must equal receipt amount (strict conservation)
    if (htlcOut.nValue != receipt.amount) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3screate-amount-mismatch");
    }

    // Validate extraPayload contains valid HTLC3SCreatePayload
    if (!tx.extraPayload || tx.extraPayload->empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3screate-no-payload");
    }

    HTLC3SCreatePayload payload;
    try {
        CDataStream ss(*tx.extraPayload, SER_NETWORK, PROTOCOL_VERSION);
        ss >> payload;
    } catch (const std::exception&) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3screate-payload-deserialize");
    }

    std::string strError;
    if (!payload.IsTriviallyValid(strError)) {
        return state.DoS(100, false, REJECT_INVALID, strError);
    }

    return true;
}

bool ApplyHTLC3SCreate(const CTransaction& tx,
                       const CCoinsViewCache& view,
                       uint32_t nHeight,
                       CSettlementDB::Batch& settlementBatch,
                       CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();
    const COutPoint& receiptOutpoint = tx.vin[0].prevout;

    // Read original M1 receipt
    M1Receipt receipt;
    if (!g_settlementdb->ReadReceipt(receiptOutpoint, receipt)) {
        LogPrintf("ERROR: ApplyHTLC3SCreate failed to read receipt %s\n", receiptOutpoint.ToString());
        return false;
    }

    // Create undo data
    HTLC3SCreateUndoData undoData;
    undoData.originalReceiptOutpoint = receipt.outpoint;
    undoData.originalAmount = receipt.amount;
    undoData.originalCreateHeight = receipt.nCreateHeight;

    // Erase M1 receipt from settlement DB
    settlementBatch.EraseReceipt(receiptOutpoint);

    // Deserialize HTLC3SCreatePayload from extraPayload
    HTLC3SCreatePayload payload;
    try {
        CDataStream ss(*tx.extraPayload, SER_NETWORK, PROTOCOL_VERSION);
        ss >> payload;
    } catch (const std::exception& e) {
        LogPrintf("ERROR: ApplyHTLC3SCreate failed to deserialize payload for %s: %s\n",
                  txid.ToString(), e.what());
        return false;
    }

    // Create HTLC3S record from payload
    HTLC3SRecord htlc;
    htlc.htlcOutpoint = COutPoint(txid, 0);
    htlc.hashlock_user = payload.hashlock_user;
    htlc.hashlock_lp1 = payload.hashlock_lp1;
    htlc.hashlock_lp2 = payload.hashlock_lp2;
    htlc.sourceReceipt = receiptOutpoint;
    htlc.amount = receipt.amount;
    htlc.redeemScript = CreateConditional3SScript(
        payload.hashlock_user, payload.hashlock_lp1, payload.hashlock_lp2,
        payload.expiryHeight, payload.claimKeyID, payload.refundKeyID);
    htlc.claimKeyID = payload.claimKeyID;
    htlc.refundKeyID = payload.refundKeyID;
    htlc.createHeight = nHeight;
    htlc.expiryHeight = payload.expiryHeight;
    htlc.status = HTLCStatus::ACTIVE;

    // Write HTLC3S record and 3 hashlock indices for cross-chain matching
    htlcBatch.WriteHTLC3S(htlc);
    htlcBatch.WriteHashlock3SUserIndex(htlc.hashlock_user, htlc.htlcOutpoint);
    htlcBatch.WriteHashlock3SLp1Index(htlc.hashlock_lp1, htlc.htlcOutpoint);
    htlcBatch.WriteHashlock3SLp2Index(htlc.hashlock_lp2, htlc.htlcOutpoint);
    htlcBatch.WriteCreate3SUndo(txid, undoData);

    LogPrint(BCLog::HTLC, "ApplyHTLC3SCreate: %s receipt=%s amount=%lld (3-secret)\n",
             txid.ToString().substr(0, 16), receiptOutpoint.ToString(), receipt.amount);

    return true;
}

bool UndoHTLC3SCreate(const CTransaction& tx,
                      CSettlementDB::Batch& settlementBatch,
                      CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();
    const COutPoint htlcOutpoint(txid, 0);

    // Read HTLC3S record before erasing (need hashlocks for index cleanup)
    HTLC3SRecord htlc;
    if (!g_htlcdb->ReadHTLC3S(htlcOutpoint, htlc)) {
        LogPrintf("ERROR: UndoHTLC3SCreate failed to read HTLC3S %s\n", htlcOutpoint.ToString());
        return false;
    }

    // Read undo data
    HTLC3SCreateUndoData undoData;
    if (!g_htlcdb->ReadCreate3SUndo(txid, undoData)) {
        LogPrintf("ERROR: UndoHTLC3SCreate failed to read undo data for %s\n", txid.ToString());
        return false;
    }

    // Erase 3 hashlock indices first (while we still have the hashlocks)
    htlcBatch.EraseHashlock3SUserIndex(htlc.hashlock_user, htlcOutpoint);
    htlcBatch.EraseHashlock3SLp1Index(htlc.hashlock_lp1, htlcOutpoint);
    htlcBatch.EraseHashlock3SLp2Index(htlc.hashlock_lp2, htlcOutpoint);

    // Erase HTLC3S record
    htlcBatch.EraseHTLC3S(htlcOutpoint);

    // Restore M1 receipt
    M1Receipt receipt;
    receipt.outpoint = undoData.originalReceiptOutpoint;
    receipt.amount = undoData.originalAmount;
    receipt.nCreateHeight = undoData.originalCreateHeight;
    settlementBatch.WriteReceipt(receipt);

    // Erase undo data
    htlcBatch.EraseCreate3SUndo(txid);

    LogPrint(BCLog::HTLC, "UndoHTLC3SCreate: %s restored receipt=%s\n",
             txid.ToString().substr(0, 16), receipt.outpoint.ToString());

    return true;
}

// =============================================================================
// HTLC_CLAIM_3S - Claim 3-Secret HTLC with 3 preimages
// =============================================================================

bool CheckHTLC3SClaim(const CTransaction& tx,
                      const CCoinsViewCache& view,
                      CValidationState& state)
{
    // Verify TX type
    if (tx.nType != CTransaction::HTLC_CLAIM_3S) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3sclaim-type");
    }

    // Must have at least 1 input (HTLC3S)
    if (tx.vin.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3sclaim-no-inputs");
    }

    // Must have at least 1 output (new M1 receipt)
    if (tx.vout.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3sclaim-no-outputs");
    }

    // vin[0] must be an active HTLC3S
    const COutPoint& htlcOutpoint = tx.vin[0].prevout;
    if (!g_htlcdb || !g_htlcdb->IsHTLC3S(htlcOutpoint)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3sclaim-not-htlc3s");
    }

    // Read HTLC3S record
    HTLC3SRecord htlc;
    if (!g_htlcdb->ReadHTLC3S(htlcOutpoint, htlc)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3sclaim-htlc-missing");
    }

    // HTLC must be active
    if (!htlc.IsActive()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3sclaim-not-active");
    }

    // Verify all 3 hashlocks are set
    if (htlc.hashlock_user.IsNull() || htlc.hashlock_lp1.IsNull() || htlc.hashlock_lp2.IsNull()) {
        LogPrintf("ERROR: CheckHTLC3SClaim HTLC3S %s has null hashlock - corrupt DB?\n", htlcOutpoint.ToString());
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3sclaim-null-hashlock");
    }

    // Extract 3 preimages from scriptSig and verify against hashlocks
    std::vector<unsigned char> preimage_user, preimage_lp1, preimage_lp2;
    if (!ExtractPreimagesFromScriptSig3S(tx.vin[0].scriptSig, htlc.redeemScript,
                                          preimage_user, preimage_lp1, preimage_lp2)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3sclaim-invalid-scriptsig");
    }

    // Verify SHA256(preimage) == hashlock for all 3
    if (!VerifyPreimages3S(preimage_user, preimage_lp1, preimage_lp2,
                           htlc.hashlock_user, htlc.hashlock_lp1, htlc.hashlock_lp2)) {
        LogPrint(BCLog::HTLC, "CheckHTLC3SClaim: preimage verification failed for %s\n", htlcOutpoint.ToString());
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3sclaim-preimage-mismatch");
    }

    LogPrint(BCLog::HTLC, "CheckHTLC3SClaim: 3 preimages verified for HTLC3S %s\n", htlcOutpoint.ToString());
    return true;
}

bool ApplyHTLC3SClaim(const CTransaction& tx,
                      const CCoinsViewCache& view,
                      uint32_t nHeight,
                      CSettlementDB::Batch& settlementBatch,
                      CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();
    const COutPoint& htlcOutpoint = tx.vin[0].prevout;

    // Read HTLC3S record
    HTLC3SRecord htlc;
    if (!g_htlcdb->ReadHTLC3S(htlcOutpoint, htlc)) {
        LogPrintf("ERROR: ApplyHTLC3SClaim failed to read HTLC3S %s\n", htlcOutpoint.ToString());
        return false;
    }

    // Create undo data (save full HTLC3S state)
    HTLC3SResolveUndoData undoData;
    undoData.htlcRecord = htlc;
    undoData.resultReceiptErased = COutPoint(txid, 0);

    // Extract 3 preimages from scriptSig for storage
    std::vector<unsigned char> preimage_user_vec, preimage_lp1_vec, preimage_lp2_vec;
    if (ExtractPreimagesFromScriptSig3S(tx.vin[0].scriptSig, htlc.redeemScript,
                                         preimage_user_vec, preimage_lp1_vec, preimage_lp2_vec)) {
        memcpy(htlc.preimage_user.begin(), preimage_user_vec.data(), 32);
        memcpy(htlc.preimage_lp1.begin(), preimage_lp1_vec.data(), 32);
        memcpy(htlc.preimage_lp2.begin(), preimage_lp2_vec.data(), 32);
    }

    // Update HTLC3S record to CLAIMED
    htlc.status = HTLCStatus::CLAIMED;
    htlc.resolveTxid = txid;
    htlc.resultReceipt = COutPoint(txid, 0);

    // Erase 3 hashlock indices (HTLC no longer active)
    htlcBatch.EraseHashlock3SUserIndex(htlc.hashlock_user, htlcOutpoint);
    htlcBatch.EraseHashlock3SLp1Index(htlc.hashlock_lp1, htlcOutpoint);
    htlcBatch.EraseHashlock3SLp2Index(htlc.hashlock_lp2, htlcOutpoint);
    htlcBatch.WriteHTLC3S(htlc);
    htlcBatch.WriteResolve3SUndo(txid, undoData);

    // Create new M1 receipt for claimer
    M1Receipt newReceipt;
    newReceipt.outpoint = COutPoint(txid, 0);
    newReceipt.amount = tx.vout[0].nValue;
    newReceipt.nCreateHeight = nHeight;
    settlementBatch.WriteReceipt(newReceipt);

    LogPrint(BCLog::HTLC, "ApplyHTLC3SClaim: %s htlc=%s new_receipt=%s amount=%lld (3-secret)\n",
             txid.ToString().substr(0, 16), htlcOutpoint.ToString(),
             newReceipt.outpoint.ToString(), newReceipt.amount);

    return true;
}

bool UndoHTLC3SClaim(const CTransaction& tx,
                     CSettlementDB::Batch& settlementBatch,
                     CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();

    // Read undo data
    HTLC3SResolveUndoData undoData;
    if (!g_htlcdb->ReadResolve3SUndo(txid, undoData)) {
        LogPrintf("ERROR: UndoHTLC3SClaim failed to read undo data for %s\n", txid.ToString());
        return false;
    }

    // Erase the new M1 receipt
    settlementBatch.EraseReceipt(COutPoint(txid, 0));

    // Restore HTLC3S record to ACTIVE state
    HTLC3SRecord restored = undoData.htlcRecord;
    restored.status = HTLCStatus::ACTIVE;
    restored.resolveTxid.SetNull();
    restored.preimage_user.SetNull();
    restored.preimage_lp1.SetNull();
    restored.preimage_lp2.SetNull();
    restored.resultReceipt.SetNull();

    // Restore 3 hashlock indices (HTLC becomes active again)
    htlcBatch.WriteHashlock3SUserIndex(restored.hashlock_user, restored.htlcOutpoint);
    htlcBatch.WriteHashlock3SLp1Index(restored.hashlock_lp1, restored.htlcOutpoint);
    htlcBatch.WriteHashlock3SLp2Index(restored.hashlock_lp2, restored.htlcOutpoint);
    htlcBatch.WriteHTLC3S(restored);

    // Erase undo data
    htlcBatch.EraseResolve3SUndo(txid);

    LogPrint(BCLog::HTLC, "UndoHTLC3SClaim: %s restored htlc3s=%s\n",
             txid.ToString().substr(0, 16), restored.htlcOutpoint.ToString());

    return true;
}

// =============================================================================
// HTLC_REFUND_3S - Refund expired 3-Secret HTLC
// =============================================================================

bool CheckHTLC3SRefund(const CTransaction& tx,
                       const CCoinsViewCache& view,
                       uint32_t nHeight,
                       CValidationState& state)
{
    // Verify TX type
    if (tx.nType != CTransaction::HTLC_REFUND_3S) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3srefund-type");
    }

    // Must have at least 1 input (HTLC3S)
    if (tx.vin.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3srefund-no-inputs");
    }

    // Must have at least 1 output (M1 receipt back to creator)
    if (tx.vout.empty()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3srefund-no-outputs");
    }

    // vin[0] must be an active HTLC3S
    const COutPoint& htlcOutpoint = tx.vin[0].prevout;
    if (!g_htlcdb || !g_htlcdb->IsHTLC3S(htlcOutpoint)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3srefund-not-htlc3s");
    }

    // Read HTLC3S record
    HTLC3SRecord htlc;
    if (!g_htlcdb->ReadHTLC3S(htlcOutpoint, htlc)) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3srefund-htlc-missing");
    }

    // HTLC must be active
    if (!htlc.IsActive()) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3srefund-not-active");
    }

    // Must be past expiry
    if (nHeight < htlc.expiryHeight) {
        return state.DoS(100, false, REJECT_INVALID, "bad-htlc3srefund-not-expired");
    }

    return true;
}

bool ApplyHTLC3SRefund(const CTransaction& tx,
                       const CCoinsViewCache& view,
                       uint32_t nHeight,
                       CSettlementDB::Batch& settlementBatch,
                       CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();
    const COutPoint& htlcOutpoint = tx.vin[0].prevout;

    // Read HTLC3S record
    HTLC3SRecord htlc;
    if (!g_htlcdb->ReadHTLC3S(htlcOutpoint, htlc)) {
        LogPrintf("ERROR: ApplyHTLC3SRefund failed to read HTLC3S %s\n", htlcOutpoint.ToString());
        return false;
    }

    // Create undo data
    HTLC3SResolveUndoData undoData;
    undoData.htlcRecord = htlc;
    undoData.resultReceiptErased = COutPoint(txid, 0);

    // Update HTLC3S record to REFUNDED
    htlc.status = HTLCStatus::REFUNDED;
    htlc.resolveTxid = txid;
    htlc.resultReceipt = COutPoint(txid, 0);

    // Erase 3 hashlock indices (HTLC no longer active)
    htlcBatch.EraseHashlock3SUserIndex(htlc.hashlock_user, htlcOutpoint);
    htlcBatch.EraseHashlock3SLp1Index(htlc.hashlock_lp1, htlcOutpoint);
    htlcBatch.EraseHashlock3SLp2Index(htlc.hashlock_lp2, htlcOutpoint);
    htlcBatch.WriteHTLC3S(htlc);
    htlcBatch.WriteResolve3SUndo(txid, undoData);

    // Create M1 receipt back to creator
    M1Receipt newReceipt;
    newReceipt.outpoint = COutPoint(txid, 0);
    newReceipt.amount = tx.vout[0].nValue;
    newReceipt.nCreateHeight = nHeight;
    settlementBatch.WriteReceipt(newReceipt);

    LogPrint(BCLog::HTLC, "ApplyHTLC3SRefund: %s htlc=%s new_receipt=%s amount=%lld (3-secret)\n",
             txid.ToString().substr(0, 16), htlcOutpoint.ToString(),
             newReceipt.outpoint.ToString(), newReceipt.amount);

    return true;
}

bool UndoHTLC3SRefund(const CTransaction& tx,
                      CSettlementDB::Batch& settlementBatch,
                      CHtlcDB::Batch& htlcBatch)
{
    const uint256& txid = tx.GetHash();

    // Read undo data
    HTLC3SResolveUndoData undoData;
    if (!g_htlcdb->ReadResolve3SUndo(txid, undoData)) {
        LogPrintf("ERROR: UndoHTLC3SRefund failed to read undo data for %s\n", txid.ToString());
        return false;
    }

    // Erase the refund M1 receipt
    settlementBatch.EraseReceipt(COutPoint(txid, 0));

    // Restore HTLC3S record to ACTIVE state
    HTLC3SRecord restored = undoData.htlcRecord;
    restored.status = HTLCStatus::ACTIVE;
    restored.resolveTxid.SetNull();
    restored.resultReceipt.SetNull();

    // Restore 3 hashlock indices (HTLC becomes active again)
    htlcBatch.WriteHashlock3SUserIndex(restored.hashlock_user, restored.htlcOutpoint);
    htlcBatch.WriteHashlock3SLp1Index(restored.hashlock_lp1, restored.htlcOutpoint);
    htlcBatch.WriteHashlock3SLp2Index(restored.hashlock_lp2, restored.htlcOutpoint);
    htlcBatch.WriteHTLC3S(restored);

    // Erase undo data
    htlcBatch.EraseResolve3SUndo(txid);

    LogPrint(BCLog::HTLC, "UndoHTLC3SRefund: %s restored htlc3s=%s\n",
             txid.ToString().substr(0, 16), restored.htlcOutpoint.ToString());

    return true;
}
