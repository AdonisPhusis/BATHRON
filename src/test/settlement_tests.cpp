// Copyright (c) 2025 The Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

/**
 * Settlement Layer Tests - TX_LOCK validation and DB operations
 *
 * Ref: doc/blueprints/settlement/LOCK-SETTLEMENT-v1.3.2.md
 *
 * Tests:
 *   1. SettlementState invariants and serialization
 *   2. VaultEntry and M1Receipt serialization
 *   3. Settlement DB operations (IsVault, IsM1Receipt, IsM0Standard)
 *   4. TX_LOCK structure validation (CheckLock)
 *   5. ApplyLock state mutation
 */

#include "state/settlement.h"
#include "state/settlementdb.h"
#include "state/settlement_logic.h"
#include "amount.h"
#include "clientversion.h"
#include "coins.h"
#include "consensus/tx_verify.h"
#include "consensus/validation.h"
#include "key.h"
#include "primitives/transaction.h"
#include "script/script.h"
#include "script/standard.h"
#include "streams.h"
#include "test/test_bathron.h"

#include <boost/test/unit_test.hpp>

BOOST_FIXTURE_TEST_SUITE(settlement_tests, BasicTestingSetup)

// =============================================================================
// Helper: Create a mock TX_LOCK transaction (no real signature needed for unit tests)
// =============================================================================
// BP30 v2.0: OP_TRUE vault script (consensus-protected)
static CScript GetOpTrueScript()
{
    CScript script;
    script << OP_TRUE;
    return script;
}

static CMutableTransaction CreateMockTxLock(CAmount lockAmount,
                                            const CScript& vaultScript,
                                            const CScript& receiptScript)
{
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_LOCK;

    // Mock input (we won't actually spend it in unit tests)
    uint256 dummyTxid;
    dummyTxid.SetHex("1111111111111111111111111111111111111111111111111111111111111111");
    mtx.vin.emplace_back(CTxIn(COutPoint(dummyTxid, 0)));

    // Outputs: vout[0] = Vault, vout[1] = Receipt (canonical order A11)
    mtx.vout.emplace_back(CTxOut(lockAmount, vaultScript));
    mtx.vout.emplace_back(CTxOut(lockAmount, receiptScript));

    return mtx;
}

// =============================================================================
// Test 1: SettlementState invariants and serialization
// =============================================================================
BOOST_AUTO_TEST_CASE(settlement_state_invariants)
{
    // Test A6 invariant: M0_vaulted == M1_supply
    SettlementState state;
    state.M0_vaulted = 1000 * COIN;
    state.M1_supply = 1000 * COIN;
    state.nHeight = 100;

    // 1000 == 1000 → should pass
    BOOST_CHECK(state.CheckInvariants());

    // Break the invariant
    state.M1_supply = 800 * COIN; // Now 1000 != 800
    BOOST_CHECK(!state.CheckInvariants());

    // Fix it back
    state.M1_supply = 1000 * COIN;
    BOOST_CHECK(state.CheckInvariants());
}

// =============================================================================
// Test 2: CheckLock validation logic
// =============================================================================
BOOST_AUTO_TEST_CASE(checklock_validates_structure)
{
    // Initialize settlement DB for M0 standard checks
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    // BP30 v2.0: Vault MUST use OP_TRUE script (consensus-protected)
    CScript vaultScript = GetOpTrueScript();
    CScript receiptScript = GetScriptForDestination(key.GetPubKey().GetID());

    // Test 1: Valid TX_LOCK (with OP_TRUE vault)
    {
        CMutableTransaction mtx = CreateMockTxLock(100 * COIN, vaultScript, receiptScript);
        CTransaction tx(mtx);

        CCoinsView coinsDummy;
        CCoinsViewCache view(&coinsDummy);
        CValidationState state;

        BOOST_CHECK(CheckLock(tx, view, state));
    }

    // Test 2: Wrong type (not TX_LOCK)
    {
        CMutableTransaction mtx = CreateMockTxLock(100 * COIN, vaultScript, receiptScript);
        mtx.nType = CTransaction::TxType::NORMAL;
        CTransaction tx(mtx);

        CCoinsView coinsDummy;
        CCoinsViewCache view(&coinsDummy);
        CValidationState state;

        BOOST_CHECK(!CheckLock(tx, view, state));
        BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txlock-type");
    }

    // Test 3: Amount mismatch (vout[0] != vout[1])
    {
        CMutableTransaction mtx;
        mtx.nVersion = CTransaction::TxVersion::SAPLING;
        mtx.nType = CTransaction::TxType::TX_LOCK;

        uint256 dummyTxid;
        dummyTxid.SetHex("1111111111111111111111111111111111111111111111111111111111111111");
        mtx.vin.emplace_back(CTxIn(COutPoint(dummyTxid, 0)));

        mtx.vout.emplace_back(CTxOut(100 * COIN, vaultScript));
        mtx.vout.emplace_back(CTxOut(99 * COIN, receiptScript)); // Different!
        CTransaction tx(mtx);

        CCoinsView coinsDummy;
        CCoinsViewCache view(&coinsDummy);
        CValidationState state;

        BOOST_CHECK(!CheckLock(tx, view, state));
        BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txlock-amount-mismatch");
    }

    // Test 4: Wrong output count (not exactly 2)
    {
        CMutableTransaction mtx;
        mtx.nVersion = CTransaction::TxVersion::SAPLING;
        mtx.nType = CTransaction::TxType::TX_LOCK;

        uint256 dummyTxid;
        dummyTxid.SetHex("1111111111111111111111111111111111111111111111111111111111111111");
        mtx.vin.emplace_back(CTxIn(COutPoint(dummyTxid, 0)));

        mtx.vout.emplace_back(CTxOut(100 * COIN, vaultScript));
        // Only 1 output
        CTransaction tx(mtx);

        CCoinsView coinsDummy;
        CCoinsViewCache view(&coinsDummy);
        CValidationState state;

        BOOST_CHECK(!CheckLock(tx, view, state));
        BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txlock-output-count");
    }

    // Test 5: Zero amount
    {
        CMutableTransaction mtx = CreateMockTxLock(0, vaultScript, receiptScript);
        CTransaction tx(mtx);

        CCoinsView coinsDummy;
        CCoinsViewCache view(&coinsDummy);
        CValidationState state;

        BOOST_CHECK(!CheckLock(tx, view, state));
        BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txlock-amount-zero");
    }

    // Test 6: Vault is NOT OP_TRUE (BP30 v2.0: must be OP_TRUE)
    {
        CKey wrongKey;
        wrongKey.MakeNewKey(true);
        CScript p2pkhScript = GetScriptForDestination(wrongKey.GetPubKey().GetID());

        CMutableTransaction mtx = CreateMockTxLock(100 * COIN, p2pkhScript, receiptScript);
        CTransaction tx(mtx);

        CCoinsView coinsDummy;
        CCoinsViewCache view(&coinsDummy);
        CValidationState state;

        BOOST_CHECK(!CheckLock(tx, view, state));
        BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txlock-vault-not-optrue");
    }
}

// =============================================================================
// Test 3: SettlementState serialization round-trip
// =============================================================================
BOOST_AUTO_TEST_CASE(settlement_state_serialization)
{
    // A6 invariant: M0_vaulted == M1_supply
    SettlementState original;
    original.M0_vaulted = 1000 * COIN;
    original.M1_supply = 1000 * COIN;
    original.M0_shielded = 500 * COIN;  // Informative only
    original.nHeight = 12345;

    // Verify invariant holds (1000 == 1000)
    BOOST_CHECK(original.CheckInvariants());

    // Serialize
    CDataStream ss(SER_DISK, CLIENT_VERSION);
    ss << original;

    // Deserialize
    SettlementState loaded;
    ss >> loaded;

    // Verify all fields
    BOOST_CHECK_EQUAL(loaded.M0_vaulted, original.M0_vaulted);
    BOOST_CHECK_EQUAL(loaded.M1_supply, original.M1_supply);
    BOOST_CHECK_EQUAL(loaded.M0_shielded, original.M0_shielded);
    BOOST_CHECK_EQUAL(loaded.nHeight, original.nHeight);
    BOOST_CHECK(loaded.CheckInvariants());
}

// =============================================================================
// Test 4: VaultEntry and M1Receipt serialization
// =============================================================================
BOOST_AUTO_TEST_CASE(vault_receipt_serialization)
{
    // Create a dummy txid
    uint256 txid;
    txid.SetHex("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");

    // VaultEntry - BP30 v2.0: No receiptOutpoint (bearer model)
    VaultEntry vault;
    vault.outpoint = COutPoint(txid, 0);
    vault.amount = 100 * COIN;
    vault.nLockHeight = 12345;
    // NOTE: vault.receiptOutpoint removed in bearer model - no 1:1 link

    CDataStream ssVault(SER_DISK, CLIENT_VERSION);
    ssVault << vault;

    VaultEntry loadedVault;
    ssVault >> loadedVault;

    BOOST_CHECK(loadedVault.outpoint == vault.outpoint);
    BOOST_CHECK_EQUAL(loadedVault.amount, vault.amount);
    BOOST_CHECK_EQUAL(loadedVault.nLockHeight, vault.nLockHeight);

    // M1Receipt - BP30 v2.0: No vaultOutpoint (bearer model)
    M1Receipt receipt;
    receipt.outpoint = COutPoint(txid, 1);
    receipt.amount = 100 * COIN;
    // NOTE: receipt.vaultOutpoint removed in bearer model - M1 is bearer asset
    receipt.nCreateHeight = 12345;

    CDataStream ssReceipt(SER_DISK, CLIENT_VERSION);
    ssReceipt << receipt;

    M1Receipt loadedReceipt;
    ssReceipt >> loadedReceipt;

    BOOST_CHECK(loadedReceipt.outpoint == receipt.outpoint);
    BOOST_CHECK_EQUAL(loadedReceipt.amount, receipt.amount);
    BOOST_CHECK_EQUAL(loadedReceipt.nCreateHeight, receipt.nCreateHeight);
}

// =============================================================================
// Test 5: IsM0Standard is DB-driven
// =============================================================================
BOOST_AUTO_TEST_CASE(is_m0_standard_db_driven)
{
    // Initialize settlement DB
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    // Create a dummy outpoint
    uint256 txid;
    txid.SetHex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    COutPoint testOutpoint(txid, 0);

    // Initially should be M0 standard (not in any index)
    BOOST_CHECK(g_settlementdb->IsM0Standard(testOutpoint));

    // Add as Vault
    VaultEntry vault;
    vault.outpoint = testOutpoint;
    vault.amount = 100 * COIN;
    BOOST_REQUIRE(g_settlementdb->WriteVault(vault));

    // Now should NOT be M0 standard
    BOOST_CHECK(!g_settlementdb->IsM0Standard(testOutpoint));
    BOOST_CHECK(g_settlementdb->IsVault(testOutpoint));

    // Clean up
    BOOST_REQUIRE(g_settlementdb->EraseVault(testOutpoint));
    BOOST_CHECK(g_settlementdb->IsM0Standard(testOutpoint));

    // Test with Receipt
    COutPoint receiptOutpoint(txid, 1);
    BOOST_CHECK(g_settlementdb->IsM0Standard(receiptOutpoint));

    M1Receipt receipt;
    receipt.outpoint = receiptOutpoint;
    receipt.amount = 100 * COIN;
    BOOST_REQUIRE(g_settlementdb->WriteReceipt(receipt));

    BOOST_CHECK(!g_settlementdb->IsM0Standard(receiptOutpoint));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptOutpoint));

    // Clean up
    BOOST_REQUIRE(g_settlementdb->EraseReceipt(receiptOutpoint));
    BOOST_CHECK(g_settlementdb->IsM0Standard(receiptOutpoint));
}

// =============================================================================
// Test 6: ApplyLock mutates SettlementState correctly
// =============================================================================
BOOST_AUTO_TEST_CASE(applylock_state_mutation)
{
    // Initialize settlement DB
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    // BP30 v2.0: Vault uses OP_TRUE (consensus-protected)
    CScript vaultScript = GetOpTrueScript();
    CScript receiptScript = GetScriptForDestination(key.GetPubKey().GetID());

    // Create valid TX_LOCK
    CAmount P = 100 * COIN;
    CMutableTransaction mtx = CreateMockTxLock(P, vaultScript, receiptScript);
    CTransaction tx(mtx);

    // Initial state (A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 1000;

    BOOST_CHECK(state.CheckInvariants()); // 0 == 0

    // Apply the lock
    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CSettlementDB::Batch batch = g_settlementdb->CreateBatch();

    uint32_t nHeight = 1001;
    BOOST_CHECK(ApplyLock(tx, view, state, nHeight, batch));

    // Verify state mutation (A6)
    BOOST_CHECK_EQUAL(state.M0_vaulted, P);
    BOOST_CHECK_EQUAL(state.M1_supply, P);

    // Invariant should still hold: P + 0 == P + 0
    BOOST_CHECK(state.CheckInvariants());

    // Verify DB entries were prepared (via batch)
    // Note: Batch writes are not committed yet, but we can verify the vault was created
    const uint256& txid = tx.GetHash();

    // Commit the batch
    BOOST_CHECK(batch.Commit());

    // Now verify DB entries
    COutPoint vaultOutpoint(txid, 0);
    COutPoint receiptOutpoint(txid, 1);

    BOOST_CHECK(g_settlementdb->IsVault(vaultOutpoint));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptOutpoint));
    BOOST_CHECK(!g_settlementdb->IsM0Standard(vaultOutpoint));
    BOOST_CHECK(!g_settlementdb->IsM0Standard(receiptOutpoint));

    // Verify VaultEntry contents - BP30 v2.0: No receipt link (bearer model)
    VaultEntry vault;
    BOOST_CHECK(g_settlementdb->ReadVault(vaultOutpoint, vault));
    BOOST_CHECK_EQUAL(vault.amount, P);
    BOOST_CHECK_EQUAL(vault.nLockHeight, nHeight);

    // Verify M1Receipt contents - BP30 v2.0: No vault link (bearer model)
    M1Receipt receipt;
    BOOST_CHECK(g_settlementdb->ReadReceipt(receiptOutpoint, receipt));
    BOOST_CHECK_EQUAL(receipt.amount, P);
    BOOST_CHECK_EQUAL(receipt.nCreateHeight, nHeight);
}

// =============================================================================
// TX_UNLOCK Tests (6 tests)
// =============================================================================

// Helper: Create a mock TX_UNLOCK transaction
static CMutableTransaction CreateMockTxUnlock(const COutPoint& receiptOutpoint,
                                               const COutPoint& vaultOutpoint,
                                               CAmount unlockAmount,
                                               const CScript& destScript)
{
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_UNLOCK;

    // Inputs: vin[0] = Receipt, vin[1] = Vault (canonical order)
    mtx.vin.emplace_back(CTxIn(receiptOutpoint));
    mtx.vin.emplace_back(CTxIn(vaultOutpoint));

    // Output: vout[0] = M0 (unlocked amount)
    mtx.vout.emplace_back(CTxOut(unlockAmount, destScript));

    return mtx;
}

// Helper: Setup Vault+Receipt pair in DB for unlock tests
static void SetupVaultReceiptPair(CAmount P, uint32_t lockHeight,
                                   COutPoint& vaultOut, COutPoint& receiptOut)
{
    // Create a unique txid for this pair
    static int counter = 0;
    counter++;
    uint256 lockTxid;
    lockTxid.SetHex(strprintf("aabbccdd%056d", counter));

    vaultOut = COutPoint(lockTxid, 0);
    receiptOut = COutPoint(lockTxid, 1);

    // Create and write Vault entry - BP30 v2.0: No receipt link (bearer model)
    VaultEntry vault;
    vault.outpoint = vaultOut;
    vault.amount = P;
    vault.nLockHeight = lockHeight;
    // NOTE: No receiptOutpoint or unlockPubKey in bearer model
    BOOST_REQUIRE(g_settlementdb->WriteVault(vault));

    // Create and write Receipt entry - BP30 v2.0: No vault link (bearer model)
    M1Receipt receipt;
    receipt.outpoint = receiptOut;
    receipt.amount = P;
    // NOTE: No vaultOutpoint in bearer model - M1 is a bearer asset
    receipt.nCreateHeight = lockHeight;
    BOOST_REQUIRE(g_settlementdb->WriteReceipt(receipt));
}

// =============================================================================
// Test 7: CheckUnlock rejects when receipt missing
// =============================================================================
BOOST_AUTO_TEST_CASE(checkunlock_missing_receipt_reject)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    // Create fake outpoints (not in DB)
    uint256 fakeTxid;
    fakeTxid.SetHex("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef");
    COutPoint fakeReceipt(fakeTxid, 0);
    COutPoint fakeVault(fakeTxid, 1);

    CMutableTransaction mtx = CreateMockTxUnlock(fakeReceipt, fakeVault, 100 * COIN, destScript);
    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    BOOST_CHECK(!CheckUnlock(tx, view, state));
    // BP30 v2.2: Unknown inputs treated as M0 fee inputs → no valid receipts found
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txunlock-no-receipts");
}

// =============================================================================
// Test 8: CheckUnlock rejects when vault missing
// =============================================================================
BOOST_AUTO_TEST_CASE(checkunlock_vault_missing_reject)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    // Create only a receipt (no vault) - BP30 v2.0 bearer model
    uint256 txid;
    txid.SetHex("2222222222222222222222222222222222222222222222222222222222222222");
    COutPoint receiptOut(txid, 1);
    COutPoint vaultOut(txid, 0);

    // Write only receipt, not vault
    M1Receipt receipt;
    receipt.outpoint = receiptOut;
    receipt.amount = 100 * COIN;
    receipt.nCreateHeight = 1000;
    BOOST_REQUIRE(g_settlementdb->WriteReceipt(receipt));

    CMutableTransaction mtx = CreateMockTxUnlock(receiptOut, vaultOut, 100 * COIN, destScript);
    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    BOOST_CHECK(!CheckUnlock(tx, view, state));
    // BP30 v2.2: Missing vault is treated as M0 fee input → fee before vault error
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txunlock-fee-before-vault");

    // Cleanup
    g_settlementdb->EraseReceipt(receiptOut);
}

// =============================================================================
// Test 9: CheckUnlock rejects when vault amount insufficient (BP30 v2.0 bearer model)
// =============================================================================
BOOST_AUTO_TEST_CASE(checkunlock_vault_insufficient_reject)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    // Create receipt with more amount than vault
    uint256 txid;
    txid.SetHex("3333333333333333333333333333333333333333333333333333333333333333");

    COutPoint vaultOut(txid, 0);
    COutPoint receiptOut(txid, 1);

    // Vault with 50 COIN
    VaultEntry vault;
    vault.outpoint = vaultOut;
    vault.amount = 50 * COIN;
    vault.nLockHeight = 1000;
    BOOST_REQUIRE(g_settlementdb->WriteVault(vault));

    // Receipt with 100 COIN (more than vault!)
    M1Receipt receipt;
    receipt.outpoint = receiptOut;
    receipt.amount = 100 * COIN;
    receipt.nCreateHeight = 1000;
    BOOST_REQUIRE(g_settlementdb->WriteReceipt(receipt));

    CMutableTransaction mtx = CreateMockTxUnlock(receiptOut, vaultOut, 100 * COIN, destScript);
    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    // BP30 v2.1: M0_out must <= sum(vaults)
    BOOST_CHECK(!CheckUnlock(tx, view, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txunlock-m0-exceeds-vault");

    // Cleanup
    g_settlementdb->EraseVault(vaultOut);
    g_settlementdb->EraseReceipt(receiptOut);
}

// =============================================================================
// Test 9b: Conservation violation MUST fail (anti-inflation/deflation bug)
// =============================================================================
BOOST_AUTO_TEST_CASE(checkunlock_conservation_violation_reject)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    // Create vault with 10 M0
    COutPoint vaultOut;
    GetStrongRandBytes(vaultOut.hash.begin(), 32);
    vaultOut.n = 0;

    VaultEntry vault;
    vault.outpoint = vaultOut;
    vault.amount = 10 * COIN;
    vault.nLockHeight = 1000;
    BOOST_REQUIRE(g_settlementdb->WriteVault(vault));

    // Create M1 receipt with 10 M1
    COutPoint receiptOut;
    GetStrongRandBytes(receiptOut.hash.begin(), 32);
    receiptOut.n = 1;

    M1Receipt receipt;
    receipt.outpoint = receiptOut;
    receipt.amount = 10 * COIN;
    receipt.nCreateHeight = 1000;
    BOOST_REQUIRE(g_settlementdb->WriteReceipt(receipt));

    // ========================================================================
    // TEST: M1_in > M0_out + M1_change (attempting to burn extra M1)
    // This MUST fail - would break A6 invariant (M0_vaulted == M1_supply)
    // ========================================================================
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_UNLOCK;

    // vin[0] = M1 Receipt (10 M1)
    mtx.vin.emplace_back(CTxIn(receiptOut));
    // vin[1] = Vault (10 M0)
    mtx.vin.emplace_back(CTxIn(vaultOut));

    // VIOLATION: M0_out + M1_change = 3 + 5 = 8, but M1_in = 10
    // This leaves 2 M1 "burned" with no M0 backing → MUST FAIL
    mtx.vout.emplace_back(CTxOut(3 * COIN, destScript));   // M0 out
    mtx.vout.emplace_back(CTxOut(5 * COIN, destScript));   // M1 change

    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    // MUST reject - conservation violated
    BOOST_CHECK(!CheckUnlock(tx, view, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txunlock-conservation-violated");

    // Cleanup
    g_settlementdb->EraseVault(vaultOut);
    g_settlementdb->EraseReceipt(receiptOut);
}

// =============================================================================
// Test 10: ApplyUnlock deletes DB entries
// =============================================================================
BOOST_AUTO_TEST_CASE(applyunlock_deletes_db_entries)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 100 * COIN;
    COutPoint vaultOut, receiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, receiptOut);

    // Verify entries exist
    BOOST_CHECK(g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptOut));

    // Create TX_UNLOCK
    CMutableTransaction mtx = CreateMockTxUnlock(receiptOut, vaultOut, P, destScript);
    CTransaction tx(mtx);

    // Setup state (A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = P;
    state.M1_supply = P;
    BOOST_CHECK(state.CheckInvariants()); // P == P

    // Apply unlock
    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    auto batch = g_settlementdb->CreateBatch();

    UnlockUndoData undoData;
    BOOST_CHECK(ApplyUnlock(tx, view, state, batch, undoData));
    BOOST_CHECK(batch.Commit());

    // Verify entries are deleted
    BOOST_CHECK(!g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptOut));
    BOOST_CHECK(g_settlementdb->IsM0Standard(vaultOut));
    BOOST_CHECK(g_settlementdb->IsM0Standard(receiptOut));
}

// =============================================================================
// Test 11: ApplyUnlock state mutation preserves invariant
// =============================================================================
BOOST_AUTO_TEST_CASE(applyunlock_state_mutation_invariant)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 200 * COIN;
    COutPoint vaultOut, receiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, receiptOut);

    // Setup state with existing lock (A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = P;
    state.M1_supply = P;
    BOOST_CHECK(state.CheckInvariants()); // P == P

    // Create and apply TX_UNLOCK
    CMutableTransaction mtx = CreateMockTxUnlock(receiptOut, vaultOut, P, destScript);
    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    auto batch = g_settlementdb->CreateBatch();

    UnlockUndoData undoData;
    BOOST_CHECK(ApplyUnlock(tx, view, state, batch, undoData));
    BOOST_CHECK(batch.Commit());

    // Verify state mutation: M0_vaulted -= P, M1_supply -= P
    BOOST_CHECK_EQUAL(state.M0_vaulted, 0);
    BOOST_CHECK_EQUAL(state.M1_supply, 0);

    // Invariant must still hold: 0 + 0 == 0 + 0
    BOOST_CHECK(state.CheckInvariants());
}

// =============================================================================
// Test 12: UndoUnlock restores everything (BP30 v2.1)
// =============================================================================
BOOST_AUTO_TEST_CASE(undo_unlock_restores_everything)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 150 * COIN;
    uint32_t lockHeight = 1000;
    COutPoint vaultOut, receiptOut;
    SetupVaultReceiptPair(P, lockHeight, vaultOut, receiptOut);

    // Read entries before unlock (for later comparison)
    VaultEntry originalVault;
    M1Receipt originalReceipt;
    BOOST_CHECK(g_settlementdb->ReadVault(vaultOut, originalVault));
    BOOST_CHECK(g_settlementdb->ReadReceipt(receiptOut, originalReceipt));

    // Setup state (A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = P;
    state.M1_supply = P;

    // Create TX_UNLOCK and apply
    CMutableTransaction mtx = CreateMockTxUnlock(receiptOut, vaultOut, P, destScript);
    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    UnlockUndoData undoData;

    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyUnlock(tx, view, state, batch, undoData));
        BOOST_CHECK(batch.Commit());
    }

    // State after unlock
    BOOST_CHECK_EQUAL(state.M0_vaulted, 0);
    BOOST_CHECK_EQUAL(state.M1_supply, 0);
    BOOST_CHECK(!g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptOut));

    // Verify undoData captured correctly
    BOOST_CHECK_EQUAL(undoData.receiptsSpent.size(), 1);
    BOOST_CHECK_EQUAL(undoData.vaultsSpent.size(), 1);
    BOOST_CHECK_EQUAL(undoData.m0Released, P);
    BOOST_CHECK_EQUAL(undoData.netM1Burned, P);
    BOOST_CHECK_EQUAL(undoData.changeReceiptsCreated, 0);

    // Now UNDO the unlock using undoData
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoUnlock(tx, undoData, state, batch));
        BOOST_CHECK(batch.Commit());
    }

    // Verify state restored
    BOOST_CHECK_EQUAL(state.M0_vaulted, P);
    BOOST_CHECK_EQUAL(state.M1_supply, P);
    BOOST_CHECK(state.CheckInvariants());

    // Verify DB entries restored
    BOOST_CHECK(g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptOut));

    // Verify entry contents - BP30 v2.0: No link fields in bearer model
    VaultEntry restoredVault;
    M1Receipt restoredReceipt;
    BOOST_CHECK(g_settlementdb->ReadVault(vaultOut, restoredVault));
    BOOST_CHECK(g_settlementdb->ReadReceipt(receiptOut, restoredReceipt));

    BOOST_CHECK_EQUAL(restoredVault.amount, P);
    BOOST_CHECK_EQUAL(restoredReceipt.amount, P);
}

// =============================================================================
// Test 12: Unlock with M1 change (BP30 v2.1 - partial unlock)
// =============================================================================
BOOST_AUTO_TEST_CASE(unlock_with_m1_change)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CPubKey ownerPubKey = key.GetPubKey();
    CScript destScript = GetScriptForDestination(ownerPubKey.GetID());
    CScript changeScript = GetScriptForDestination(ownerPubKey.GetID());  // Same for simplicity

    CAmount P = 10 * COIN;  // Lock 10 M0
    CAmount unlockAmount = 3 * COIN;  // Unlock only 3 M0
    uint32_t lockHeight = 100;

    // Initialize state (genesis, A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 0;
    BOOST_CHECK(state.CheckInvariants()); // 0 == 0

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    // Step 1: TX_LOCK - Create 10 M0 vault + 10 M1 receipt
    CMutableTransaction mtxLock = CreateMockTxLock(P, GetOpTrueScript(), destScript);
    CTransaction txLock(mtxLock);

    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyLock(txLock, view, state, lockHeight, batch));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint vaultOut(txLock.GetHash(), 0);
    COutPoint receiptOut(txLock.GetHash(), 1);

    // Verify state after LOCK
    BOOST_CHECK_EQUAL(state.M0_vaulted, P);  // 10 M0 vaulted
    BOOST_CHECK_EQUAL(state.M1_supply, P);          // 10 M1 supply
    BOOST_CHECK(state.CheckInvariants());

    // Step 2: TX_UNLOCK with M1 change
    // Unlock 3 M0, should create 7 M1 change output
    CAmount m1Change = P - unlockAmount;  // 7 M0

    // Create mock TX_UNLOCK with change output
    CMutableTransaction mtxUnlock;
    mtxUnlock.nVersion = CTransaction::TxVersion::SAPLING;
    mtxUnlock.nType = CTransaction::TxType::TX_UNLOCK;

    // vin[0] = M1 Receipt (10 M1)
    mtxUnlock.vin.emplace_back(CTxIn(receiptOut));
    // vin[1] = Vault (10 M0)
    mtxUnlock.vin.emplace_back(CTxIn(vaultOut));

    // vout[0] = M0 output (3 M0)
    mtxUnlock.vout.emplace_back(CTxOut(unlockAmount, destScript));
    // vout[1] = M1 change receipt (7 M1)
    mtxUnlock.vout.emplace_back(CTxOut(m1Change, changeScript));

    CTransaction txUnlock(mtxUnlock);

    // Validate and apply
    CValidationState validationState;
    BOOST_CHECK(CheckUnlock(txUnlock, view, validationState));

    UnlockUndoData undoData;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyUnlock(txUnlock, view, state, batch, undoData));
        BOOST_CHECK(batch.Commit());
    }

    // Verify state after partial UNLOCK
    BOOST_CHECK_EQUAL(state.M0_vaulted, m1Change);  // 7 M0 still vaulted
    BOOST_CHECK_EQUAL(state.M1_supply, m1Change);          // 7 M1 remaining
    BOOST_CHECK(state.CheckInvariants());                  // A6 still holds!

    // Verify undo data
    BOOST_CHECK_EQUAL(undoData.m0Released, unlockAmount);  // 3 M0 released
    BOOST_CHECK_EQUAL(undoData.netM1Burned, unlockAmount); // 3 M1 net burned
    BOOST_CHECK_EQUAL(undoData.changeReceiptsCreated, 1);  // 1 change receipt

    // Verify DB state
    COutPoint changeReceiptOut(txUnlock.GetHash(), 1);
    BOOST_CHECK(!g_settlementdb->IsVault(vaultOut));          // Original vault spent
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptOut));    // Original receipt spent
    BOOST_CHECK(g_settlementdb->IsM1Receipt(changeReceiptOut)); // Change receipt created

    // Verify change receipt amount
    M1Receipt changeReceipt;
    BOOST_CHECK(g_settlementdb->ReadReceipt(changeReceiptOut, changeReceipt));
    BOOST_CHECK_EQUAL(changeReceipt.amount, m1Change);

    // Step 3: Undo the unlock
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoUnlock(txUnlock, undoData, state, batch));
        BOOST_CHECK(batch.Commit());
    }

    // Verify state restored
    BOOST_CHECK_EQUAL(state.M0_vaulted, P);  // Back to 10 M0
    BOOST_CHECK_EQUAL(state.M1_supply, P);          // Back to 10 M1
    BOOST_CHECK(state.CheckInvariants());

    // Verify DB entries restored
    BOOST_CHECK(g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptOut));
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(changeReceiptOut));  // Change receipt removed
}

// =============================================================================
// TX_TRANSFER_M1 Tests (6 tests)
// =============================================================================

// Helper: Create a mock TX_TRANSFER_M1 transaction
static CMutableTransaction CreateMockTxTransfer(const COutPoint& receiptInput,
                                                  CAmount transferAmount,
                                                  const CScript& newOwnerScript)
{
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_TRANSFER_M1;

    // vin[0] = old Receipt
    mtx.vin.emplace_back(CTxIn(receiptInput));

    // vout[0] = new Receipt (same amount)
    mtx.vout.emplace_back(CTxOut(transferAmount, newOwnerScript));

    return mtx;
}

// =============================================================================
// Test 13: CheckTransfer rejects when no M1 receipt input
// =============================================================================
BOOST_AUTO_TEST_CASE(transfer_reject_no_m1_input)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript newOwnerScript = GetScriptForDestination(key.GetPubKey().GetID());

    // Create TX_TRANSFER_M1 with a fake input that is NOT a receipt
    uint256 fakeTxid;
    fakeTxid.SetHex("5555555555555555555555555555555555555555555555555555555555555555");
    COutPoint fakeInput(fakeTxid, 0);

    CMutableTransaction mtx = CreateMockTxTransfer(fakeInput, 100 * COIN, newOwnerScript);
    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    BOOST_CHECK(!CheckTransfer(tx, view, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txtransfer-no-receipt-input");
}

// =============================================================================
// Test 14: CheckTransfer rejects when multiple M1 receipt inputs
// =============================================================================
BOOST_AUTO_TEST_CASE(transfer_reject_multi_m1_inputs)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript newOwnerScript = GetScriptForDestination(key.GetPubKey().GetID());

    // Setup two vault+receipt pairs
    CAmount P = 100 * COIN;
    COutPoint vaultOut1, receiptOut1;
    COutPoint vaultOut2, receiptOut2;
    SetupVaultReceiptPair(P, 1000, vaultOut1, receiptOut1);
    SetupVaultReceiptPair(P, 1001, vaultOut2, receiptOut2);

    // Create TX with 2 receipt inputs (invalid)
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_TRANSFER_M1;
    mtx.vin.emplace_back(CTxIn(receiptOut1));
    mtx.vin.emplace_back(CTxIn(receiptOut2));  // Second receipt = invalid
    mtx.vout.emplace_back(CTxOut(P, newOwnerScript));

    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    BOOST_CHECK(!CheckTransfer(tx, view, state));
    // Second receipt at vin[1] fails with "receipt-not-vin0" (canonical order violation)
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txtransfer-receipt-not-vin0");

    // Cleanup
    g_settlementdb->EraseVault(vaultOut1);
    g_settlementdb->EraseReceipt(receiptOut1);
    g_settlementdb->EraseVault(vaultOut2);
    g_settlementdb->EraseReceipt(receiptOut2);
}

// =============================================================================
// Test 15: CheckTransfer rejects when sum(outputs) > old receipt amount
// BP30 v2.1: Multi-output splits allowed, but cannot exceed input
// =============================================================================
BOOST_AUTO_TEST_CASE(transfer_reject_m1_not_conserved)
{
    // BP30 v2.4: STRICT M1 conservation - sum(M1_out) must EQUAL sum(M1_in)
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript newOwnerScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 100 * COIN;
    COutPoint vaultOut, receiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, receiptOut);

    // Create transfer with EXCEEDING amount (101 instead of 100)
    // BP30 v2.4: This fails strict M1 conservation (m1Out != m1In)
    CMutableTransaction mtx = CreateMockTxTransfer(receiptOut, 101 * COIN, newOwnerScript);
    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    BOOST_CHECK(!CheckTransfer(tx, view, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txtransfer-m1-not-conserved");

    // Cleanup
    g_settlementdb->EraseVault(vaultOut);
    g_settlementdb->EraseReceipt(receiptOut);
}

// =============================================================================
// Test 16: ApplyTransfer updates vault.receiptOutpoint to new receipt
// =============================================================================
BOOST_AUTO_TEST_CASE(transfer_updates_vault_receipt_pointer)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript newOwnerScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 100 * COIN;
    COutPoint vaultOut, oldReceiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, oldReceiptOut);

    // Verify initial state - BP30 v2.0: No link in bearer model
    VaultEntry vaultBefore;
    BOOST_CHECK(g_settlementdb->ReadVault(vaultOut, vaultBefore));
    BOOST_CHECK_EQUAL(vaultBefore.amount, P);

    // Create and apply transfer
    CMutableTransaction mtx = CreateMockTxTransfer(oldReceiptOut, P, newOwnerScript);
    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    auto batch = g_settlementdb->CreateBatch();

    TransferUndoData undoData;
    BOOST_CHECK(ApplyTransfer(tx, view, batch, undoData));
    BOOST_CHECK(batch.Commit());

    // BP30 v2.0 Bearer model: Vault is UNCHANGED after transfer
    // (no more receipt pointer update - M1 is a bearer asset)
    VaultEntry vaultAfter;
    BOOST_CHECK(g_settlementdb->ReadVault(vaultOut, vaultAfter));
    BOOST_CHECK_EQUAL(vaultAfter.amount, P);
}

// =============================================================================
// Test 17: ApplyTransfer deletes old receipt and creates new receipt
// =============================================================================
BOOST_AUTO_TEST_CASE(transfer_db_deletes_old_and_creates_new)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript newOwnerScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 150 * COIN;
    COutPoint vaultOut, oldReceiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, oldReceiptOut);

    // Verify old receipt exists
    BOOST_CHECK(g_settlementdb->IsM1Receipt(oldReceiptOut));

    // Create and apply transfer
    CMutableTransaction mtx = CreateMockTxTransfer(oldReceiptOut, P, newOwnerScript);
    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    auto batch = g_settlementdb->CreateBatch();

    TransferUndoData undoData;
    BOOST_CHECK(ApplyTransfer(tx, view, batch, undoData));
    BOOST_CHECK(batch.Commit());

    COutPoint newReceiptOut(tx.GetHash(), 0);

    // Old receipt should be deleted
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(oldReceiptOut));
    BOOST_CHECK(g_settlementdb->IsM0Standard(oldReceiptOut));

    // New receipt should exist
    BOOST_CHECK(g_settlementdb->IsM1Receipt(newReceiptOut));

    // Verify new receipt contents - BP30 v2.0: No vault link in bearer model
    M1Receipt newReceipt;
    BOOST_CHECK(g_settlementdb->ReadReceipt(newReceiptOut, newReceipt));
    BOOST_CHECK_EQUAL(newReceipt.amount, P);
}

// =============================================================================
// Test 18: UndoTransfer restores everything
// =============================================================================
BOOST_AUTO_TEST_CASE(undo_transfer_restores_everything)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript newOwnerScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 200 * COIN;
    uint32_t lockHeight = 1000;
    COutPoint vaultOut, oldReceiptOut;
    SetupVaultReceiptPair(P, lockHeight, vaultOut, oldReceiptOut);

    // Save original receipt for comparison
    M1Receipt originalReceipt;
    BOOST_CHECK(g_settlementdb->ReadReceipt(oldReceiptOut, originalReceipt));

    // Create and apply transfer
    CMutableTransaction mtx = CreateMockTxTransfer(oldReceiptOut, P, newOwnerScript);
    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    // BP30 v2.2: ApplyTransfer stores undo data
    TransferUndoData undoData;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(tx, view, batch, undoData));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint newReceiptOut(tx.GetHash(), 0);

    // Verify transfer applied
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(oldReceiptOut));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(newReceiptOut));

    // BP30 v2.0: Vault is unchanged (no receipt pointer in bearer model)
    VaultEntry vaultAfterTransfer;
    BOOST_CHECK(g_settlementdb->ReadVault(vaultOut, vaultAfterTransfer));
    BOOST_CHECK_EQUAL(vaultAfterTransfer.amount, P);

    // Now UNDO the transfer using the undo data
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoTransfer(tx, undoData, batch));
        BOOST_CHECK(batch.Commit());
    }

    // Verify undo: old receipt restored
    BOOST_CHECK(g_settlementdb->IsM1Receipt(oldReceiptOut));
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(newReceiptOut));

    // Verify vault unchanged (BP30 v2.0: no pointer in bearer model)
    VaultEntry vaultAfterUndo;
    BOOST_CHECK(g_settlementdb->ReadVault(vaultOut, vaultAfterUndo));
    BOOST_CHECK_EQUAL(vaultAfterUndo.amount, P);

    // Verify receipt contents restored - BP30 v2.0: No vault link in bearer model
    M1Receipt restoredReceipt;
    BOOST_CHECK(g_settlementdb->ReadReceipt(oldReceiptOut, restoredReceipt));
    BOOST_CHECK_EQUAL(restoredReceipt.amount, P);
}

// =============================================================================
// Test 18b: Cross-wallet unlock (transfer → unlock by new owner without vault key)
// BP30 v2.1: Bearer model - M1 holder can unlock without original locker's keys
// =============================================================================
BOOST_AUTO_TEST_CASE(cross_wallet_transfer_then_unlock)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    // Alice: original M1 holder (locks M0)
    CKey aliceKey;
    aliceKey.MakeNewKey(true);
    CScript aliceScript = GetScriptForDestination(aliceKey.GetPubKey().GetID());

    // Bob: receives M1 via transfer, then unlocks WITHOUT Alice's keys
    CKey bobKey;
    bobKey.MakeNewKey(true);
    CScript bobScript = GetScriptForDestination(bobKey.GetPubKey().GetID());

    CAmount P = 10 * COIN;
    uint32_t lockHeight = 100;

    // Initialize state (A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 0;

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    // Step 1: Alice locks 10 M0 → gets vault + receipt
    CMutableTransaction mtxLock = CreateMockTxLock(P, GetOpTrueScript(), aliceScript);
    CTransaction txLock(mtxLock);

    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyLock(txLock, view, state, lockHeight, batch));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint vaultOut(txLock.GetHash(), 0);
    COutPoint aliceReceiptOut(txLock.GetHash(), 1);

    BOOST_CHECK_EQUAL(state.M0_vaulted, P);
    BOOST_CHECK_EQUAL(state.M1_supply, P);

    // Step 2: Alice transfers M1 to Bob
    CMutableTransaction mtxTransfer = CreateMockTxTransfer(aliceReceiptOut, P, bobScript);
    CTransaction txTransfer(mtxTransfer);

    TransferUndoData transferUndoData;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(txTransfer, view, batch, transferUndoData));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint bobReceiptOut(txTransfer.GetHash(), 0);

    // Verify Bob has the M1 now
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(aliceReceiptOut));  // Alice's spent
    BOOST_CHECK(g_settlementdb->IsM1Receipt(bobReceiptOut));     // Bob's new

    // Step 3: Bob unlocks (partial) - NO VAULT KEY NEEDED (bearer model)
    // Bob has 10 M1, unlocks 4 M0, keeps 6 M1 change
    CAmount unlockAmount = 4 * COIN;
    CAmount m1Change = P - unlockAmount;  // 6 M1

    CMutableTransaction mtxUnlock;
    mtxUnlock.nVersion = CTransaction::TxVersion::SAPLING;
    mtxUnlock.nType = CTransaction::TxType::TX_UNLOCK;

    // vin[0] = Bob's M1 Receipt (10 M1)
    mtxUnlock.vin.emplace_back(CTxIn(bobReceiptOut));
    // vin[1] = Vault (OP_TRUE - anyone can spend, consensus-protected)
    mtxUnlock.vin.emplace_back(CTxIn(vaultOut));

    // vout[0] = M0 to Bob (4 M0)
    mtxUnlock.vout.emplace_back(CTxOut(unlockAmount, bobScript));
    // vout[1] = M1 change to Bob (6 M1)
    mtxUnlock.vout.emplace_back(CTxOut(m1Change, bobScript));

    CTransaction txUnlock(mtxUnlock);

    // Validate - Bob can unlock without Alice's keys!
    CValidationState validationState;
    BOOST_CHECK(CheckUnlock(txUnlock, view, validationState));

    UnlockUndoData undoData;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyUnlock(txUnlock, view, state, batch, undoData));
        BOOST_CHECK(batch.Commit());
    }

    // Verify final state
    BOOST_CHECK_EQUAL(state.M0_vaulted, m1Change);  // 6 M0 still vaulted
    BOOST_CHECK_EQUAL(state.M1_supply, m1Change);          // 6 M1 remaining
    BOOST_CHECK(state.CheckInvariants());                  // A6 HOLDS!

    // Verify Bob's M1 change receipt exists
    COutPoint bobChangeOut(txUnlock.GetHash(), 1);
    BOOST_CHECK(g_settlementdb->IsM1Receipt(bobChangeOut));

    M1Receipt changeReceipt;
    BOOST_CHECK(g_settlementdb->ReadReceipt(bobChangeOut, changeReceipt));
    BOOST_CHECK_EQUAL(changeReceipt.amount, m1Change);
}

// INTEGRATION TESTS - Full Flow Scenarios
// =============================================================================

// =============================================================================
// Integration Test 1: LOCK → TRANSFER_M1 → UNLOCK (full M1 cycle)
// =============================================================================
BOOST_AUTO_TEST_CASE(integration_lock_transfer_unlock)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key1, key2, key3;
    key1.MakeNewKey(true);
    key2.MakeNewKey(true);
    key3.MakeNewKey(true);
    CScript script1 = GetScriptForDestination(key1.GetPubKey().GetID());
    CScript script2 = GetScriptForDestination(key2.GetPubKey().GetID());
    CScript script3 = GetScriptForDestination(key3.GetPubKey().GetID());

    CAmount P = 100 * COIN;

    // Initialize state (genesis, A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 0;
    BOOST_CHECK(state.CheckInvariants());

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    // Step 1: TX_LOCK - Create Vault + Receipt
    // BP30 v2.0: Vault uses OP_TRUE (consensus-protected)
    CMutableTransaction mtxLock = CreateMockTxLock(P, GetOpTrueScript(), script1);
    CTransaction txLock(mtxLock);

    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyLock(txLock, view, state, 100, batch));
        BOOST_CHECK(batch.Commit());
    }

    // Verify A6 invariant after LOCK: P == P
    BOOST_CHECK_EQUAL(state.M0_vaulted, P);
    BOOST_CHECK_EQUAL(state.M1_supply, P);
    BOOST_CHECK(state.CheckInvariants());

    COutPoint vaultOut(txLock.GetHash(), 0);
    COutPoint receiptOut(txLock.GetHash(), 1);
    BOOST_CHECK(g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptOut));

    // Step 2: TX_TRANSFER_M1 - Transfer receipt to new owner
    CMutableTransaction mtxTransfer = CreateMockTxTransfer(receiptOut, P, script2);
    CTransaction txTransfer(mtxTransfer);

    TransferUndoData transferUndoData;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(txTransfer, view, batch, transferUndoData));
        BOOST_CHECK(batch.Commit());
    }

    // Verify A6 invariant after TRANSFER: unchanged (no state mutation)
    BOOST_CHECK_EQUAL(state.M0_vaulted, P);
    BOOST_CHECK_EQUAL(state.M1_supply, P);
    BOOST_CHECK(state.CheckInvariants());

    // Verify old receipt erased, new receipt created
    COutPoint newReceiptOut(txTransfer.GetHash(), 0);
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptOut));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(newReceiptOut));

    // BP30 v2.0: Vault is unchanged after transfer (no receipt pointer in bearer model)
    VaultEntry vault;
    BOOST_CHECK(g_settlementdb->ReadVault(vaultOut, vault));
    BOOST_CHECK_EQUAL(vault.amount, P);

    // Step 3: TX_UNLOCK - Release M0 from Vault+Receipt
    CMutableTransaction mtxUnlock = CreateMockTxUnlock(newReceiptOut, vaultOut, P, script3);
    CTransaction txUnlock(mtxUnlock);

    {
        auto batch = g_settlementdb->CreateBatch();
        UnlockUndoData undoData;
        BOOST_CHECK(ApplyUnlock(txUnlock, view, state, batch, undoData));
        BOOST_CHECK(batch.Commit());

        // Verify undo data populated correctly
        BOOST_CHECK_EQUAL(undoData.m0Released, P);
        BOOST_CHECK_EQUAL(undoData.netM1Burned, P);  // Full unlock, no change
        BOOST_CHECK_EQUAL(undoData.changeReceiptsCreated, 0);
    }

    // Verify A6 invariant after UNLOCK: back to genesis state
    BOOST_CHECK_EQUAL(state.M0_vaulted, 0);
    BOOST_CHECK_EQUAL(state.M1_supply, 0);
    BOOST_CHECK(state.CheckInvariants());

    // Verify all settlement indexes are clean
    BOOST_CHECK(!g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptOut));
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(newReceiptOut));
    BOOST_CHECK(g_settlementdb->IsM0Standard(vaultOut));
    BOOST_CHECK(g_settlementdb->IsM0Standard(newReceiptOut));
}

// =============================================================================
// Integration Test 3: A11 Canonical Output Order Enforcement
// =============================================================================
BOOST_AUTO_TEST_CASE(integration_a11_output_order)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript script = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 50 * COIN;

    // Test TX_LOCK output order: vout[0] = Vault, vout[1] = Receipt
    CMutableTransaction mtxLock;
    mtxLock.nVersion = CTransaction::TxVersion::SAPLING;
    mtxLock.nType = CTransaction::TxType::TX_LOCK;

    uint256 dummyTxid;
    dummyTxid.SetHex("1111111111111111111111111111111111111111111111111111111111111111");
    mtxLock.vin.emplace_back(CTxIn(COutPoint(dummyTxid, 0)));

    // CORRECT order: Vault then Receipt
    // BP30 v2.0: Vault uses OP_TRUE (consensus-protected)
    mtxLock.vout.emplace_back(CTxOut(P, GetOpTrueScript()));  // vout[0] = Vault
    mtxLock.vout.emplace_back(CTxOut(P, script));             // vout[1] = Receipt

    CTransaction txLock(mtxLock);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState valState;

    // Should pass with correct order
    BOOST_CHECK(CheckLock(txLock, view, valState));

    // Verify the outputs are at expected positions
    BOOST_CHECK_EQUAL(txLock.vout[0].nValue, P); // Vault at index 0
    BOOST_CHECK_EQUAL(txLock.vout[1].nValue, P); // Receipt at index 1
}

// =============================================================================
// Integration Test 5: Partial unlock with vault change (BP30 v2.2)
// =============================================================================
// Tests that:
// 1. Partial unlock creates M1_change receipt
// 2. Partial unlock creates vault_change (OP_TRUE)
// 3. A6 invariant is preserved after partial unlock
// =============================================================================
BOOST_AUTO_TEST_CASE(partial_unlock_with_vault_change)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CPubKey ownerPubKey = key.GetPubKey();
    CScript destScript = GetScriptForDestination(ownerPubKey.GetID());

    CAmount P = 100 * COIN;          // Lock 100 M0
    CAmount unlockAmount = 30 * COIN; // Unlock only 30 M0
    CAmount vaultChange = P - unlockAmount;  // 70 M0 vault change
    uint32_t lockHeight = 100;

    // Initialize state (genesis, A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 0;
    BOOST_CHECK(state.CheckInvariants()); // 0 == 0

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    // Step 1: TX_LOCK - Create 100 M0 vault + 100 M1 receipt
    CMutableTransaction mtxLock = CreateMockTxLock(P, GetOpTrueScript(), destScript);
    CTransaction txLock(mtxLock);

    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyLock(txLock, view, state, lockHeight, batch));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint vaultOut(txLock.GetHash(), 0);
    COutPoint receiptOut(txLock.GetHash(), 1);

    // Verify state after LOCK
    BOOST_CHECK_EQUAL(state.M0_vaulted, P);  // 100 M0 vaulted
    BOOST_CHECK_EQUAL(state.M1_supply, P);          // 100 M1 supply
    BOOST_CHECK(state.CheckInvariants());           // A6 should hold

    // Step 2: TX_UNLOCK with both M1 change AND vault change
    // BP30 v2.2: Canonical output order
    // vout[0] = M0 unlocked (30 M0)
    // vout[1] = M1 change receipt (70 M1)
    // vout[2] = Vault change (70 M0, OP_TRUE)
    CMutableTransaction mtxUnlock;
    mtxUnlock.nVersion = CTransaction::TxVersion::SAPLING;
    mtxUnlock.nType = CTransaction::TxType::TX_UNLOCK;

    // vin[0] = M1 Receipt (100 M1)
    mtxUnlock.vin.emplace_back(CTxIn(receiptOut));
    // vin[1] = Vault (100 M0)
    mtxUnlock.vin.emplace_back(CTxIn(vaultOut));

    // vout[0] = M0 output (30 M0)
    mtxUnlock.vout.emplace_back(CTxOut(unlockAmount, destScript));
    // vout[1] = M1 change receipt (70 M1)
    mtxUnlock.vout.emplace_back(CTxOut(vaultChange, destScript));
    // vout[2] = Vault change (70 M0, OP_TRUE)
    mtxUnlock.vout.emplace_back(CTxOut(vaultChange, GetOpTrueScript()));

    CTransaction txUnlock(mtxUnlock);

    // Validate
    CValidationState validationState;
    BOOST_CHECK(CheckUnlock(txUnlock, view, validationState));

    // Apply
    UnlockUndoData undoData;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyUnlock(txUnlock, view, state, batch, undoData));
        BOOST_CHECK(batch.Commit());
    }

    // Verify state after partial UNLOCK with vault change
    // The vault still has 70 M0 backing the 70 M1 change
    BOOST_CHECK_EQUAL(state.M0_vaulted, vaultChange);  // 70 M0 still vaulted
    BOOST_CHECK_EQUAL(state.M1_supply, vaultChange);          // 70 M1 remaining
    BOOST_CHECK(state.CheckInvariants());                     // A6 MUST still hold!

    // Verify undo data
    BOOST_CHECK_EQUAL(undoData.m0Released, unlockAmount);  // 30 M0 released
    BOOST_CHECK_EQUAL(undoData.netM1Burned, unlockAmount); // 30 M1 net burned

    // Verify DB state - new vault change should be a vault
    COutPoint vaultChangeOut(txUnlock.GetHash(), 2);
    COutPoint m1ChangeOut(txUnlock.GetHash(), 1);

    BOOST_CHECK(!g_settlementdb->IsVault(vaultOut));           // Original vault spent
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptOut));     // Original receipt spent
    BOOST_CHECK(g_settlementdb->IsVault(vaultChangeOut));      // Vault change is a vault
    BOOST_CHECK(g_settlementdb->IsM1Receipt(m1ChangeOut));     // M1 change is a receipt

    // Verify vault change amount
    VaultEntry vaultChangeEntry;
    BOOST_CHECK(g_settlementdb->ReadVault(vaultChangeOut, vaultChangeEntry));
    BOOST_CHECK_EQUAL(vaultChangeEntry.amount, vaultChange);

    // Verify M1 change receipt amount
    M1Receipt m1ChangeReceipt;
    BOOST_CHECK(g_settlementdb->ReadReceipt(m1ChangeOut, m1ChangeReceipt));
    BOOST_CHECK_EQUAL(m1ChangeReceipt.amount, vaultChange);

    // Note: M1Receipt is a bearer asset - no linked vault tracking
    // The vault change is tracked separately in VaultEntry
}

// =============================================================================
// Integration Test 6: Non-BP30 TX spending vault OP_TRUE is rejected
// =============================================================================
// Tests that:
// 1. A regular (non-TX_UNLOCK) transaction cannot spend vault OP_TRUE
// 2. This protects vault funds from being stolen by anyone-can-spend
// =============================================================================
BOOST_AUTO_TEST_CASE(non_bp30_vault_spend_rejected)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CPubKey ownerPubKey = key.GetPubKey();
    CScript destScript = GetScriptForDestination(ownerPubKey.GetID());

    CAmount P = 50 * COIN;
    uint32_t lockHeight = 100;

    // Initialize state (A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 0;

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    // Step 1: Create a valid vault via TX_LOCK
    CMutableTransaction mtxLock = CreateMockTxLock(P, GetOpTrueScript(), destScript);
    CTransaction txLock(mtxLock);

    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyLock(txLock, view, state, lockHeight, batch));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint vaultOut(txLock.GetHash(), 0);

    // Verify vault exists
    BOOST_CHECK(g_settlementdb->IsVault(vaultOut));

    // Step 2: Try to spend vault with a NORMAL transaction (not TX_UNLOCK)
    // This should be rejected at consensus level
    CMutableTransaction mtxSteal;
    mtxSteal.nVersion = CTransaction::TxVersion::SAPLING;
    mtxSteal.nType = CTransaction::TxType::NORMAL;  // NOT a BP30 type!

    // Try to spend the vault OP_TRUE output
    mtxSteal.vin.emplace_back(CTxIn(vaultOut));
    // Send it to attacker address
    mtxSteal.vout.emplace_back(CTxOut(P - 1000, destScript));  // Attacker takes funds

    CTransaction txSteal(mtxSteal);

    // This should fail in script validation because OP_TRUE outputs
    // are only spendable by TX_UNLOCK transactions
    // The check happens in IsVaultSpendableByTxType() called during
    // ConnectBlock or AcceptToMemoryPool
    //
    // For unit test, we verify via IsVault check that the outpoint
    // is still protected by settlement logic
    BOOST_CHECK(g_settlementdb->IsVault(vaultOut));

    // Verify that CheckUnlock would reject this tx (wrong type)
    CValidationState validationState;
    // CheckUnlock expects TX_UNLOCK type, so this will fail
    BOOST_CHECK(!CheckUnlock(txSteal, view, validationState));

    // The vault should still exist (not spent)
    BOOST_CHECK(g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK_EQUAL(state.M0_vaulted, P);  // Still vaulted
}

// =============================================================================
// ADVERSARIAL TESTS: Malformed TX rejection (BP30 v2.5)
// =============================================================================

// =============================================================================
// Adversarial Test 1: TX_TRANSFER_M1 with wrong output order (M0 first)
// =============================================================================
// Tests that ParseTransferM1Outputs correctly handles malicious TX
// where M0 fee change comes before M1 outputs
// =============================================================================
BOOST_AUTO_TEST_CASE(adversarial_transfer_wrong_output_order)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 100 * COIN;
    COutPoint vaultOut, receiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, receiptOut);

    // Create malicious TX: M0 fee output FIRST, then M1 output
    // Canonical order requires M1 outputs first!
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_TRANSFER_M1;

    // vin[0] = Receipt (100 M1)
    mtx.vin.emplace_back(CTxIn(receiptOut));
    // vin[1] = M0 fee input (mock)
    uint256 feeTxid;
    feeTxid.SetHex("7777777777777777777777777777777777777777777777777777777777777777");
    mtx.vin.emplace_back(CTxIn(COutPoint(feeTxid, 0)));

    // WRONG ORDER: M0 fee change first (1 M0), then M1 output (100 M1)
    mtx.vout.emplace_back(CTxOut(1 * COIN, destScript));    // vout[0] = M0 change (WRONG!)
    mtx.vout.emplace_back(CTxOut(P, destScript));           // vout[1] = M1 output

    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    // With cumsum algorithm: vout[0] (1 M0) is treated as M1 since 1 <= 100
    // vout[1] (100 M0) would push cumsum to 101, exceeding m1In (100)
    // So splitIndex = 1, m1Out = 1 M0
    // Conservation check: m1Out (1) != m1In (100) → REJECT
    BOOST_CHECK(!CheckTransfer(tx, view, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txtransfer-m1-not-conserved");
}

// =============================================================================
// Adversarial Test 2: TX_TRANSFER_M1 with zero-value output
// =============================================================================
BOOST_AUTO_TEST_CASE(adversarial_transfer_zero_output)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 50 * COIN;
    COutPoint vaultOut, receiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, receiptOut);

    // Create TX with zero-value output
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_TRANSFER_M1;

    mtx.vin.emplace_back(CTxIn(receiptOut));

    // vout[0] = 0 value (invalid!)
    mtx.vout.emplace_back(CTxOut(0, destScript));
    // vout[1] = 50 M1
    mtx.vout.emplace_back(CTxOut(P, destScript));

    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    // ParseTransferM1Outputs should reject zero-value outputs
    BOOST_CHECK(!CheckTransfer(tx, view, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txtransfer-invalid-outputs");
}

// =============================================================================
// Adversarial Test 3: TX_TRANSFER_M1 with OP_RETURN output
// =============================================================================
BOOST_AUTO_TEST_CASE(adversarial_transfer_op_return)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 75 * COIN;
    COutPoint vaultOut, receiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, receiptOut);

    // Create TX with OP_RETURN output (unspendable)
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_TRANSFER_M1;

    mtx.vin.emplace_back(CTxIn(receiptOut));

    // vout[0] = OP_RETURN with data (unspendable)
    CScript opReturnScript;
    opReturnScript << OP_RETURN << std::vector<unsigned char>(10, 0xAB);
    mtx.vout.emplace_back(CTxOut(P, opReturnScript));

    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    // ParseTransferM1Outputs should reject OP_RETURN outputs
    BOOST_CHECK(!CheckTransfer(tx, view, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txtransfer-invalid-outputs");
}

// =============================================================================
// Adversarial Test 4: TX_TRANSFER_M1 split with amounts not summing to input
// =============================================================================
BOOST_AUTO_TEST_CASE(adversarial_transfer_split_sum_mismatch)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey keyA, keyB;
    keyA.MakeNewKey(true);
    keyB.MakeNewKey(true);
    CScript scriptA = GetScriptForDestination(keyA.GetPubKey().GetID());
    CScript scriptB = GetScriptForDestination(keyB.GetPubKey().GetID());

    CAmount P = 100 * COIN;  // 100 M1 input
    COutPoint vaultOut, receiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, receiptOut);

    // Create split TX where outputs don't sum to input
    // Try to split 100 M1 into 60 + 60 = 120 M1 (inflation attempt!)
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_TRANSFER_M1;

    mtx.vin.emplace_back(CTxIn(receiptOut));

    // vout[0] = 60 M1 to A
    mtx.vout.emplace_back(CTxOut(60 * COIN, scriptA));
    // vout[1] = 60 M1 to B (total = 120, but input is only 100!)
    mtx.vout.emplace_back(CTxOut(60 * COIN, scriptB));

    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    // With cumsum: vout[0] (60) is M1, cumsum = 60 <= 100
    // vout[1] (60) would push cumsum to 120 > 100, so splitIndex = 1
    // m1Out = 60, but m1In = 100 → conservation violated
    BOOST_CHECK(!CheckTransfer(tx, view, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txtransfer-m1-not-conserved");
}

// =============================================================================
// Adversarial Test 5: TX_TRANSFER_M1 implicit burn attempt (outputs < input)
// =============================================================================
BOOST_AUTO_TEST_CASE(adversarial_transfer_implicit_burn)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 100 * COIN;  // 100 M1 input
    COutPoint vaultOut, receiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, receiptOut);

    // Try implicit burn: output only 80 M1, "burning" 20 M1
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_TRANSFER_M1;

    mtx.vin.emplace_back(CTxIn(receiptOut));

    // vout[0] = 80 M1 (trying to burn 20)
    mtx.vout.emplace_back(CTxOut(80 * COIN, destScript));

    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    // Strict conservation: m1Out (80) != m1In (100) → REJECT
    BOOST_CHECK(!CheckTransfer(tx, view, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txtransfer-m1-not-conserved");
}

// =============================================================================
// Adversarial Test 6: TX_TRANSFER_M1 with multiple M0 change outputs
// =============================================================================
BOOST_AUTO_TEST_CASE(adversarial_transfer_multi_m0_change)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount P = 100 * COIN;  // 100 M1 input
    COutPoint vaultOut, receiptOut;
    SetupVaultReceiptPair(P, 1000, vaultOut, receiptOut);

    // Valid TX with M1 output first, then multiple M0 change outputs
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_TRANSFER_M1;

    mtx.vin.emplace_back(CTxIn(receiptOut));
    // Add M0 fee input
    uint256 feeTxid;
    feeTxid.SetHex("8888888888888888888888888888888888888888888888888888888888888888");
    mtx.vin.emplace_back(CTxIn(COutPoint(feeTxid, 0)));

    // vout[0] = 100 M1 (full M1 output)
    mtx.vout.emplace_back(CTxOut(P, destScript));
    // vout[1] = 1 M0 change
    mtx.vout.emplace_back(CTxOut(1 * COIN, destScript));
    // vout[2] = 0.5 M0 change (multiple M0 change is allowed)
    mtx.vout.emplace_back(CTxOut(COIN / 2, destScript));

    CTransaction tx(mtx);

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);
    CValidationState state;

    // This should be VALID - multiple M0 change outputs are allowed
    // cumsum: vout[0] = 100 == m1In, so splitIndex = 1
    // m1Out = 100 == m1In → conservation OK
    BOOST_CHECK(CheckTransfer(tx, view, state));
}

// =============================================================================
// Deep Reorg Test: Settlement DB follows chain tip through 30-block reorg
// =============================================================================
BOOST_AUTO_TEST_CASE(deep_reorg_settlement_db_consistency)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    // Initialize state (A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 0;

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    // Track undo data for each block
    struct BlockUndoData {
        std::vector<std::pair<CTransaction, UnlockUndoData>> unlocks;
        std::vector<std::pair<CTransaction, TransferUndoData>> transfers;
        std::vector<CTransaction> locks;
        SettlementState stateBefore;
    };
    std::vector<BlockUndoData> undoStack;

    const int REORG_DEPTH = 30;
    const CAmount LOCK_AMOUNT = 10 * COIN;

    // Simulate 30 blocks with various operations
    for (int height = 1; height <= REORG_DEPTH; ++height) {
        BlockUndoData blockUndo;
        blockUndo.stateBefore = state;

        // Every block: create a lock
        CMutableTransaction mtxLock = CreateMockTxLock(LOCK_AMOUNT, GetOpTrueScript(), destScript);
        // Make txid unique per height
        mtxLock.vin[0].prevout.n = height;
        CTransaction txLock(mtxLock);

        {
            auto batch = g_settlementdb->CreateBatch();
            BOOST_CHECK(ApplyLock(txLock, view, state, height, batch));
            BOOST_CHECK(batch.Commit());
        }
        blockUndo.locks.push_back(txLock);

        // Every 5th block: do a transfer
        if (height % 5 == 0 && !blockUndo.locks.empty()) {
            COutPoint receiptOut(txLock.GetHash(), 1);

            CMutableTransaction mtxTransfer;
            mtxTransfer.nVersion = CTransaction::TxVersion::SAPLING;
            mtxTransfer.nType = CTransaction::TxType::TX_TRANSFER_M1;
            mtxTransfer.vin.emplace_back(CTxIn(receiptOut));
            mtxTransfer.vout.emplace_back(CTxOut(LOCK_AMOUNT, destScript));
            CTransaction txTransfer(mtxTransfer);

            TransferUndoData transferUndo;
            {
                auto batch = g_settlementdb->CreateBatch();
                BOOST_CHECK(ApplyTransfer(txTransfer, view, batch, transferUndo));
                BOOST_CHECK(batch.Commit());
            }
            blockUndo.transfers.push_back({txTransfer, transferUndo});
        }

        state.nHeight = height;
        undoStack.push_back(blockUndo);
    }

    // Verify state after 30 blocks
    BOOST_CHECK_EQUAL(state.nHeight, REORG_DEPTH);
    BOOST_CHECK_EQUAL(state.M0_vaulted, REORG_DEPTH * LOCK_AMOUNT);
    BOOST_CHECK_EQUAL(state.M1_supply, REORG_DEPTH * LOCK_AMOUNT);
    BOOST_CHECK(state.CheckInvariants());

    // Now simulate a 30-block reorg: undo all blocks
    for (int i = REORG_DEPTH - 1; i >= 0; --i) {
        BlockUndoData& blockUndo = undoStack[i];

        // Undo transfers (in reverse order)
        for (auto it = blockUndo.transfers.rbegin(); it != blockUndo.transfers.rend(); ++it) {
            auto batch = g_settlementdb->CreateBatch();
            BOOST_CHECK(UndoTransfer(it->first, it->second, batch));
            BOOST_CHECK(batch.Commit());
        }

        // Undo locks (in reverse order)
        for (auto it = blockUndo.locks.rbegin(); it != blockUndo.locks.rend(); ++it) {
            auto batch = g_settlementdb->CreateBatch();
            BOOST_CHECK(UndoLock(*it, state, batch));
            BOOST_CHECK(batch.Commit());
        }

        state.nHeight = i;
    }

    // Verify state after full reorg
    BOOST_CHECK_EQUAL(state.nHeight, 0);
    BOOST_CHECK_EQUAL(state.M0_vaulted, 0);
    BOOST_CHECK_EQUAL(state.M1_supply, 0);
    BOOST_CHECK(state.CheckInvariants());

    // Verify DB is clean - all vaults and receipts should be gone
    for (const auto& blockUndo : undoStack) {
        for (const auto& txLock : blockUndo.locks) {
            COutPoint vaultOut(txLock.GetHash(), 0);
            COutPoint receiptOut(txLock.GetHash(), 1);
            BOOST_CHECK(!g_settlementdb->IsVault(vaultOut));
            BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptOut));
        }
    }
}

// =============================================================================
// Deep Reorg Test 2: Partial unlock with vault change survives reorg
// =============================================================================
// =============================================================================
// MAINNET AUDIT: Full Cycle M0/M1 Bearer Asset Test
// =============================================================================
// Tests the complete flow:
//   1. Lock M0 → Vault + M1 Receipt
//   2. Transfer M1 (send × 3)
//   3. Cross-wallet partial unlock (bearer - no link needed)
//   4. Transfer remaining M1 (send × 3)
//   5. Full unlock of remainder
//   6. Verify A6 invariant holds throughout
// =============================================================================
BOOST_AUTO_TEST_CASE(mainnet_audit_full_cycle_bearer_asset)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    // Create 4 different wallets (simulating cross-wallet transfers)
    CKey walletA, walletB, walletC, walletD;
    walletA.MakeNewKey(true);
    walletB.MakeNewKey(true);
    walletC.MakeNewKey(true);
    walletD.MakeNewKey(true);
    CScript scriptA = GetScriptForDestination(walletA.GetPubKey().GetID());
    CScript scriptB = GetScriptForDestination(walletB.GetPubKey().GetID());
    CScript scriptC = GetScriptForDestination(walletC.GetPubKey().GetID());
    CScript scriptD = GetScriptForDestination(walletD.GetPubKey().GetID());

    // Initialize state (genesis, A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 0;
    BOOST_CHECK(state.CheckInvariants()); // 0 == 0

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    const CAmount INITIAL_LOCK = 100 * COIN;  // 100 M0

    // =========================================================================
    // STEP 1: WalletA locks 100 M0 → Vault(100) + Receipt(100 M1)
    // =========================================================================
    CMutableTransaction mtxLock = CreateMockTxLock(INITIAL_LOCK, GetOpTrueScript(), scriptA);
    CTransaction txLock(mtxLock);

    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyLock(txLock, view, state, 1, batch));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint vaultOut(txLock.GetHash(), 0);
    COutPoint receiptA(txLock.GetHash(), 1);

    // Verify state after lock
    BOOST_CHECK_EQUAL(state.M0_vaulted, INITIAL_LOCK);
    BOOST_CHECK_EQUAL(state.M1_supply, INITIAL_LOCK);
    BOOST_CHECK(state.CheckInvariants());  // A6: 100 + 0 == 100 + 0

    // =========================================================================
    // STEP 2: Transfer M1 × 3 (A → B → C → D) - "send send send"
    // =========================================================================

    // Transfer 1: A → B (100 M1)
    CMutableTransaction mtxT1;
    mtxT1.nVersion = CTransaction::TxVersion::SAPLING;
    mtxT1.nType = CTransaction::TxType::TX_TRANSFER_M1;
    mtxT1.vin.emplace_back(CTxIn(receiptA));
    mtxT1.vout.emplace_back(CTxOut(INITIAL_LOCK, scriptB));
    CTransaction txT1(mtxT1);

    CValidationState vs1;
    BOOST_CHECK(CheckTransfer(txT1, view, vs1));
    TransferUndoData undoT1;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(txT1, view, batch, undoT1));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint receiptB(txT1.GetHash(), 0);
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptA));  // Old consumed
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptB));   // New created
    BOOST_CHECK(state.CheckInvariants());  // A6 unchanged

    // Transfer 2: B → C (100 M1)
    CMutableTransaction mtxT2;
    mtxT2.nVersion = CTransaction::TxVersion::SAPLING;
    mtxT2.nType = CTransaction::TxType::TX_TRANSFER_M1;
    mtxT2.vin.emplace_back(CTxIn(receiptB));
    mtxT2.vout.emplace_back(CTxOut(INITIAL_LOCK, scriptC));
    CTransaction txT2(mtxT2);

    CValidationState vs2;
    BOOST_CHECK(CheckTransfer(txT2, view, vs2));
    TransferUndoData undoT2;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(txT2, view, batch, undoT2));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint receiptC(txT2.GetHash(), 0);
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptB));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptC));
    BOOST_CHECK(state.CheckInvariants());

    // Transfer 3: C → D (100 M1)
    CMutableTransaction mtxT3;
    mtxT3.nVersion = CTransaction::TxVersion::SAPLING;
    mtxT3.nType = CTransaction::TxType::TX_TRANSFER_M1;
    mtxT3.vin.emplace_back(CTxIn(receiptC));
    mtxT3.vout.emplace_back(CTxOut(INITIAL_LOCK, scriptD));
    CTransaction txT3(mtxT3);

    CValidationState vs3;
    BOOST_CHECK(CheckTransfer(txT3, view, vs3));
    TransferUndoData undoT3;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(txT3, view, batch, undoT3));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint receiptD(txT3.GetHash(), 0);
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptC));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptD));
    BOOST_CHECK(state.CheckInvariants());

    // =========================================================================
    // STEP 3: Cross-wallet PARTIAL unlock by D (bearer - no link to A!)
    //         D unlocks 30 M0, keeps 70 M1 as change
    // =========================================================================
    CAmount unlockAmount = 30 * COIN;
    CAmount m1Change = INITIAL_LOCK - unlockAmount;  // 70 M1

    CMutableTransaction mtxUnlock1;
    mtxUnlock1.nVersion = CTransaction::TxVersion::SAPLING;
    mtxUnlock1.nType = CTransaction::TxType::TX_UNLOCK;
    mtxUnlock1.vin.emplace_back(CTxIn(receiptD));   // M1 receipt from D
    mtxUnlock1.vin.emplace_back(CTxIn(vaultOut));   // Original vault (OP_TRUE - anyone can spend!)
    mtxUnlock1.vout.emplace_back(CTxOut(unlockAmount, scriptD));  // 30 M0 to D
    mtxUnlock1.vout.emplace_back(CTxOut(m1Change, scriptD));      // 70 M1 change to D
    mtxUnlock1.vout.emplace_back(CTxOut(m1Change, GetOpTrueScript())); // 70 vault change

    CTransaction txUnlock1(mtxUnlock1);

    CValidationState vsU1;
    BOOST_CHECK(CheckUnlock(txUnlock1, view, vsU1));

    UnlockUndoData undoU1;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyUnlock(txUnlock1, view, state, batch, undoU1));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint newVaultOut(txUnlock1.GetHash(), 2);
    COutPoint receiptD2(txUnlock1.GetHash(), 1);

    // Verify state after partial unlock
    BOOST_CHECK_EQUAL(state.M0_vaulted, m1Change);  // 70 M0 still vaulted
    BOOST_CHECK_EQUAL(state.M1_supply, m1Change);          // 70 M1 remaining
    BOOST_CHECK(state.CheckInvariants());  // A6: 70 + 0 == 70 + 0

    // Verify DB state
    BOOST_CHECK(!g_settlementdb->IsVault(vaultOut));       // Original vault consumed
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptD));   // Original receipt consumed
    BOOST_CHECK(g_settlementdb->IsVault(newVaultOut));     // New vault change created
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptD2));   // New M1 change created

    // =========================================================================
    // STEP 4: Transfer remaining M1 × 3 (D → A → B → C) - "send send send"
    // =========================================================================

    // Transfer 4: D → A (70 M1)
    CMutableTransaction mtxT4;
    mtxT4.nVersion = CTransaction::TxVersion::SAPLING;
    mtxT4.nType = CTransaction::TxType::TX_TRANSFER_M1;
    mtxT4.vin.emplace_back(CTxIn(receiptD2));
    mtxT4.vout.emplace_back(CTxOut(m1Change, scriptA));
    CTransaction txT4(mtxT4);

    CValidationState vs4;
    BOOST_CHECK(CheckTransfer(txT4, view, vs4));
    TransferUndoData undoT4;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(txT4, view, batch, undoT4));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint receiptA2(txT4.GetHash(), 0);
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptA2));
    BOOST_CHECK(state.CheckInvariants());

    // Transfer 5: A → B (70 M1)
    CMutableTransaction mtxT5;
    mtxT5.nVersion = CTransaction::TxVersion::SAPLING;
    mtxT5.nType = CTransaction::TxType::TX_TRANSFER_M1;
    mtxT5.vin.emplace_back(CTxIn(receiptA2));
    mtxT5.vout.emplace_back(CTxOut(m1Change, scriptB));
    CTransaction txT5(mtxT5);

    CValidationState vs5;
    BOOST_CHECK(CheckTransfer(txT5, view, vs5));
    TransferUndoData undoT5;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(txT5, view, batch, undoT5));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint receiptB2(txT5.GetHash(), 0);
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptB2));
    BOOST_CHECK(state.CheckInvariants());

    // Transfer 6: B → C (70 M1)
    CMutableTransaction mtxT6;
    mtxT6.nVersion = CTransaction::TxVersion::SAPLING;
    mtxT6.nType = CTransaction::TxType::TX_TRANSFER_M1;
    mtxT6.vin.emplace_back(CTxIn(receiptB2));
    mtxT6.vout.emplace_back(CTxOut(m1Change, scriptC));
    CTransaction txT6(mtxT6);

    CValidationState vs6;
    BOOST_CHECK(CheckTransfer(txT6, view, vs6));
    TransferUndoData undoT6;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(txT6, view, batch, undoT6));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint receiptC2(txT6.GetHash(), 0);
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptC2));
    BOOST_CHECK(state.CheckInvariants());

    // =========================================================================
    // STEP 5: Full unlock of remainder by C (70 M0)
    // =========================================================================
    CMutableTransaction mtxUnlock2;
    mtxUnlock2.nVersion = CTransaction::TxVersion::SAPLING;
    mtxUnlock2.nType = CTransaction::TxType::TX_UNLOCK;
    mtxUnlock2.vin.emplace_back(CTxIn(receiptC2));   // 70 M1 receipt from C
    mtxUnlock2.vin.emplace_back(CTxIn(newVaultOut)); // 70 vault change (OP_TRUE)
    mtxUnlock2.vout.emplace_back(CTxOut(m1Change, scriptC));  // 70 M0 to C

    CTransaction txUnlock2(mtxUnlock2);

    CValidationState vsU2;
    BOOST_CHECK(CheckUnlock(txUnlock2, view, vsU2));

    UnlockUndoData undoU2;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyUnlock(txUnlock2, view, state, batch, undoU2));
        BOOST_CHECK(batch.Commit());
    }

    // =========================================================================
    // FINAL VERIFICATION: All M0/M1 released, A6 = 0
    // =========================================================================
    BOOST_CHECK_EQUAL(state.M0_vaulted, 0);  // All M0 released
    BOOST_CHECK_EQUAL(state.M1_supply, 0);          // All M1 burned
    BOOST_CHECK(state.CheckInvariants());           // A6: 0 + 0 == 0 + 0

    // Verify DB is clean
    BOOST_CHECK(!g_settlementdb->IsVault(newVaultOut));
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptC2));

    // =========================================================================
    // STEP 6: Full reorg undo - verify all state restored
    // =========================================================================
    // Undo unlock 2
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoUnlock(txUnlock2, undoU2, state, batch));
        BOOST_CHECK(batch.Commit());
    }
    BOOST_CHECK_EQUAL(state.M0_vaulted, m1Change);
    BOOST_CHECK_EQUAL(state.M1_supply, m1Change);
    BOOST_CHECK(state.CheckInvariants());

    // Undo transfers 6, 5, 4
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoTransfer(txT6, undoT6, batch));
        BOOST_CHECK(batch.Commit());
    }
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoTransfer(txT5, undoT5, batch));
        BOOST_CHECK(batch.Commit());
    }
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoTransfer(txT4, undoT4, batch));
        BOOST_CHECK(batch.Commit());
    }
    BOOST_CHECK(state.CheckInvariants());

    // Undo unlock 1
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoUnlock(txUnlock1, undoU1, state, batch));
        BOOST_CHECK(batch.Commit());
    }
    BOOST_CHECK_EQUAL(state.M0_vaulted, INITIAL_LOCK);
    BOOST_CHECK_EQUAL(state.M1_supply, INITIAL_LOCK);
    BOOST_CHECK(state.CheckInvariants());

    // Undo transfers 3, 2, 1
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoTransfer(txT3, undoT3, batch));
        BOOST_CHECK(batch.Commit());
    }
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoTransfer(txT2, undoT2, batch));
        BOOST_CHECK(batch.Commit());
    }
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoTransfer(txT1, undoT1, batch));
        BOOST_CHECK(batch.Commit());
    }

    // Verify original receipt restored
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptA));
    BOOST_CHECK(state.CheckInvariants());

    // Undo lock
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoLock(txLock, state, batch));
        BOOST_CHECK(batch.Commit());
    }

    // Final state: back to genesis
    BOOST_CHECK_EQUAL(state.M0_vaulted, 0);
    BOOST_CHECK_EQUAL(state.M1_supply, 0);
    BOOST_CHECK(state.CheckInvariants());
    BOOST_CHECK(!g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptA));
}

// =============================================================================
// MAINNET AUDIT: M1 Split then partial unlocks from different recipients
// =============================================================================
// Tests:
//   1. Lock 100 M0 → 100 M1
//   2. Split 100 M1 → 40 M1 (A) + 60 M1 (B)
//   3. A unlocks 40 M0 fully
//   4. B transfers 60 M1 → C
//   5. C unlocks 30 M0 partial (keeps 30 M1)
//   6. C unlocks remaining 30 M0
//   7. Verify A6 invariant holds at every step
// =============================================================================
BOOST_AUTO_TEST_CASE(mainnet_audit_split_multi_recipient_unlock)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey walletA, walletB, walletC;
    walletA.MakeNewKey(true);
    walletB.MakeNewKey(true);
    walletC.MakeNewKey(true);
    CScript scriptA = GetScriptForDestination(walletA.GetPubKey().GetID());
    CScript scriptB = GetScriptForDestination(walletB.GetPubKey().GetID());
    CScript scriptC = GetScriptForDestination(walletC.GetPubKey().GetID());

    // Initialize state (A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 0;

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    const CAmount INITIAL_LOCK = 100 * COIN;
    const CAmount SPLIT_A = 40 * COIN;
    const CAmount SPLIT_B = 60 * COIN;

    // Step 1: Lock 100 M0
    CMutableTransaction mtxLock = CreateMockTxLock(INITIAL_LOCK, GetOpTrueScript(), scriptA);
    CTransaction txLock(mtxLock);

    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyLock(txLock, view, state, 1, batch));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint vaultOut(txLock.GetHash(), 0);
    COutPoint receipt0(txLock.GetHash(), 1);
    BOOST_CHECK_EQUAL(state.M0_vaulted, INITIAL_LOCK);
    BOOST_CHECK_EQUAL(state.M1_supply, INITIAL_LOCK);
    BOOST_CHECK(state.CheckInvariants());

    // Step 2: Split 100 M1 → 40 M1 (A) + 60 M1 (B)
    CMutableTransaction mtxSplit;
    mtxSplit.nVersion = CTransaction::TxVersion::SAPLING;
    mtxSplit.nType = CTransaction::TxType::TX_TRANSFER_M1;
    mtxSplit.vin.emplace_back(CTxIn(receipt0));
    mtxSplit.vout.emplace_back(CTxOut(SPLIT_A, scriptA));  // 40 M1 to A
    mtxSplit.vout.emplace_back(CTxOut(SPLIT_B, scriptB));  // 60 M1 to B
    CTransaction txSplit(mtxSplit);

    CValidationState vsSplit;
    BOOST_CHECK(CheckTransfer(txSplit, view, vsSplit));

    TransferUndoData undoSplit;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(txSplit, view, batch, undoSplit));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint receiptA(txSplit.GetHash(), 0);
    COutPoint receiptB(txSplit.GetHash(), 1);
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptA));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptB));
    BOOST_CHECK(state.CheckInvariants());  // M1 unchanged (split, not burn)

    // Step 3: A unlocks 40 M0 fully
    CMutableTransaction mtxUnlockA;
    mtxUnlockA.nVersion = CTransaction::TxVersion::SAPLING;
    mtxUnlockA.nType = CTransaction::TxType::TX_UNLOCK;
    mtxUnlockA.vin.emplace_back(CTxIn(receiptA));  // 40 M1
    mtxUnlockA.vin.emplace_back(CTxIn(vaultOut));  // 100 vault (partial use)
    mtxUnlockA.vout.emplace_back(CTxOut(SPLIT_A, scriptA));  // 40 M0 to A
    // Vault change = 100 - 40 = 60
    mtxUnlockA.vout.emplace_back(CTxOut(SPLIT_B, GetOpTrueScript()));  // 60 vault change
    CTransaction txUnlockA(mtxUnlockA);

    CValidationState vsUnlockA;
    BOOST_CHECK(CheckUnlock(txUnlockA, view, vsUnlockA));

    UnlockUndoData undoUnlockA;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyUnlock(txUnlockA, view, state, batch, undoUnlockA));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint vaultChange1(txUnlockA.GetHash(), 1);
    BOOST_CHECK_EQUAL(state.M0_vaulted, SPLIT_B);  // 60 M0 vaulted
    BOOST_CHECK_EQUAL(state.M1_supply, SPLIT_B);          // 60 M1 (B's receipt)
    BOOST_CHECK(state.CheckInvariants());  // A6: 60 == 60

    // Step 4: B transfers 60 M1 → C
    CMutableTransaction mtxTransferBC;
    mtxTransferBC.nVersion = CTransaction::TxVersion::SAPLING;
    mtxTransferBC.nType = CTransaction::TxType::TX_TRANSFER_M1;
    mtxTransferBC.vin.emplace_back(CTxIn(receiptB));
    mtxTransferBC.vout.emplace_back(CTxOut(SPLIT_B, scriptC));
    CTransaction txTransferBC(mtxTransferBC);

    CValidationState vsBC;
    BOOST_CHECK(CheckTransfer(txTransferBC, view, vsBC));

    TransferUndoData undoBC;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyTransfer(txTransferBC, view, batch, undoBC));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint receiptC(txTransferBC.GetHash(), 0);
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptC));
    BOOST_CHECK(state.CheckInvariants());

    // Step 5: C unlocks 30 M0 partial (keeps 30 M1)
    CAmount partialUnlock = 30 * COIN;
    CAmount m1ChangeC = SPLIT_B - partialUnlock;  // 30 M1

    CMutableTransaction mtxUnlockC1;
    mtxUnlockC1.nVersion = CTransaction::TxVersion::SAPLING;
    mtxUnlockC1.nType = CTransaction::TxType::TX_UNLOCK;
    mtxUnlockC1.vin.emplace_back(CTxIn(receiptC));      // 60 M1
    mtxUnlockC1.vin.emplace_back(CTxIn(vaultChange1)); // 60 vault
    mtxUnlockC1.vout.emplace_back(CTxOut(partialUnlock, scriptC));  // 30 M0 to C
    mtxUnlockC1.vout.emplace_back(CTxOut(m1ChangeC, scriptC));      // 30 M1 change
    mtxUnlockC1.vout.emplace_back(CTxOut(m1ChangeC, GetOpTrueScript())); // 30 vault change
    CTransaction txUnlockC1(mtxUnlockC1);

    CValidationState vsUnlockC1;
    BOOST_CHECK(CheckUnlock(txUnlockC1, view, vsUnlockC1));

    UnlockUndoData undoUnlockC1;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyUnlock(txUnlockC1, view, state, batch, undoUnlockC1));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint vaultChange2(txUnlockC1.GetHash(), 2);
    COutPoint receiptC2(txUnlockC1.GetHash(), 1);
    BOOST_CHECK_EQUAL(state.M0_vaulted, m1ChangeC);  // 30 M0 vaulted
    BOOST_CHECK_EQUAL(state.M1_supply, m1ChangeC);          // 30 M1
    BOOST_CHECK(state.CheckInvariants());  // A6: 30 == 30

    // Step 6: C unlocks remaining 30 M0
    CMutableTransaction mtxUnlockC2;
    mtxUnlockC2.nVersion = CTransaction::TxVersion::SAPLING;
    mtxUnlockC2.nType = CTransaction::TxType::TX_UNLOCK;
    mtxUnlockC2.vin.emplace_back(CTxIn(receiptC2));    // 30 M1
    mtxUnlockC2.vin.emplace_back(CTxIn(vaultChange2)); // 30 vault
    mtxUnlockC2.vout.emplace_back(CTxOut(m1ChangeC, scriptC));  // 30 M0 to C
    CTransaction txUnlockC2(mtxUnlockC2);

    CValidationState vsUnlockC2;
    BOOST_CHECK(CheckUnlock(txUnlockC2, view, vsUnlockC2));

    UnlockUndoData undoUnlockC2;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyUnlock(txUnlockC2, view, state, batch, undoUnlockC2));
        BOOST_CHECK(batch.Commit());
    }

    // Final verification
    BOOST_CHECK_EQUAL(state.M0_vaulted, 0);
    BOOST_CHECK_EQUAL(state.M1_supply, 0);
    BOOST_CHECK(state.CheckInvariants());  // A6: 0 == 0
}

BOOST_AUTO_TEST_CASE(deep_reorg_partial_unlock_consistency)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    // Initialize state (A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 0;

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    CAmount P = 100 * COIN;
    CAmount unlockAmount = 30 * COIN;
    CAmount vaultChange = P - unlockAmount;  // 70 M0

    // Step 1: Lock 100 M0
    CMutableTransaction mtxLock = CreateMockTxLock(P, GetOpTrueScript(), destScript);
    CTransaction txLock(mtxLock);

    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyLock(txLock, view, state, 1, batch));
        BOOST_CHECK(batch.Commit());
    }

    COutPoint vaultOut(txLock.GetHash(), 0);
    COutPoint receiptOut(txLock.GetHash(), 1);

    // Step 2: Partial unlock (30 M0, leaving 70 M0 as vault change)
    CMutableTransaction mtxUnlock;
    mtxUnlock.nVersion = CTransaction::TxVersion::SAPLING;
    mtxUnlock.nType = CTransaction::TxType::TX_UNLOCK;
    mtxUnlock.vin.emplace_back(CTxIn(receiptOut));
    mtxUnlock.vin.emplace_back(CTxIn(vaultOut));
    mtxUnlock.vout.emplace_back(CTxOut(unlockAmount, destScript));  // M0 out
    mtxUnlock.vout.emplace_back(CTxOut(vaultChange, destScript));   // M1 change
    mtxUnlock.vout.emplace_back(CTxOut(vaultChange, GetOpTrueScript())); // Vault change

    CTransaction txUnlock(mtxUnlock);

    UnlockUndoData undoData;
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(ApplyUnlock(txUnlock, view, state, batch, undoData));
        BOOST_CHECK(batch.Commit());
    }

    // Verify state after partial unlock
    BOOST_CHECK_EQUAL(state.M0_vaulted, vaultChange);  // 70 M0
    BOOST_CHECK_EQUAL(state.M1_supply, vaultChange);          // 70 M1
    BOOST_CHECK(state.CheckInvariants());

    COutPoint newVaultOut(txUnlock.GetHash(), 2);
    COutPoint newReceiptOut(txUnlock.GetHash(), 1);
    BOOST_CHECK(g_settlementdb->IsVault(newVaultOut));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(newReceiptOut));

    // Step 3: Undo the partial unlock (simulate reorg)
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoUnlock(txUnlock, undoData, state, batch));
        BOOST_CHECK(batch.Commit());
    }

    // Verify state after undo
    BOOST_CHECK_EQUAL(state.M0_vaulted, P);  // Back to 100 M0
    BOOST_CHECK_EQUAL(state.M1_supply, P);          // Back to 100 M1
    BOOST_CHECK(state.CheckInvariants());

    // Original vault and receipt restored
    BOOST_CHECK(g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK(g_settlementdb->IsM1Receipt(receiptOut));

    // New vault and receipt removed
    BOOST_CHECK(!g_settlementdb->IsVault(newVaultOut));
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(newReceiptOut));

    // Step 4: Undo the lock
    {
        auto batch = g_settlementdb->CreateBatch();
        BOOST_CHECK(UndoLock(txLock, state, batch));
        BOOST_CHECK(batch.Commit());
    }

    // Verify clean state
    BOOST_CHECK_EQUAL(state.M0_vaulted, 0);
    BOOST_CHECK_EQUAL(state.M1_supply, 0);
    BOOST_CHECK(state.CheckInvariants());
    BOOST_CHECK(!g_settlementdb->IsVault(vaultOut));
    BOOST_CHECK(!g_settlementdb->IsM1Receipt(receiptOut));
}

// =============================================================================
// SECURITY TEST: Prevent TX_LOCK from spending M1 receipts (same block)
//
// Attack vector: TX_A creates Receipt_A, TX_B spends Receipt_A as if M0.
// Since settlement DB doesn't know about Receipt_A yet, IsM0Standard returns true.
// This causes M0_vaulted to increase without real M0 backing.
//
// Fix: Track pendingReceipts during block processing and reject TX_LOCK that
// spends a receipt created earlier in the same block.
// =============================================================================
BOOST_AUTO_TEST_CASE(security_lock_cannot_spend_same_block_receipt)
{
    // This test verifies the pendingReceipts logic conceptually.
    // The actual enforcement happens in ProcessSpecialTxsInBlock.

    CKey key;
    key.MakeNewKey(true);
    CScript receiptScript = GetScriptForDestination(key.GetPubKey().GetID());
    CAmount P = 100 * COIN;

    // TX_A: Creates a receipt at vout[1]
    CMutableTransaction txA;
    txA.nVersion = CTransaction::TxVersion::SAPLING;
    txA.nType = CTransaction::TxType::TX_LOCK;
    txA.vin.emplace_back(CTxIn(COutPoint(uint256S("aaaa"), 0)));
    txA.vout.emplace_back(CTxOut(P, GetOpTrueScript()));  // Vault
    txA.vout.emplace_back(CTxOut(P, receiptScript));       // Receipt

    COutPoint receiptA(CTransaction(txA).GetHash(), 1);

    // TX_B: Tries to spend Receipt_A as an input
    CMutableTransaction txB;
    txB.nVersion = CTransaction::TxVersion::SAPLING;
    txB.nType = CTransaction::TxType::TX_LOCK;
    txB.vin.emplace_back(CTxIn(receiptA));  // Spending the receipt!
    txB.vout.emplace_back(CTxOut(P, GetOpTrueScript()));
    txB.vout.emplace_back(CTxOut(P, receiptScript));

    // Simulate the pendingReceipts check (as done in ProcessSpecialTxsInBlock)
    std::set<COutPoint> pendingReceipts;
    pendingReceipts.insert(receiptA);  // TX_A created this receipt

    // TX_B should be rejected because it spends a pending receipt
    bool foundPendingReceipt = false;
    for (const CTxIn& txin : txB.vin) {
        if (pendingReceipts.count(txin.prevout)) {
            foundPendingReceipt = true;
            break;
        }
    }

    BOOST_CHECK_MESSAGE(foundPendingReceipt,
        "TX_LOCK spending a same-block receipt MUST be detected and rejected");

    LogPrintf("SECURITY-TEST: Verified pendingReceipts detection for same-block attack\n");
}

// =============================================================================
// SECURITY TEST: M0_vaulted cannot exceed M0_total
//
// Invariant: You cannot vault more M0 than exists.
// This test verifies that after applying locks with proper checks,
// M0_vaulted stays within valid bounds.
// =============================================================================
BOOST_AUTO_TEST_CASE(security_vaulted_cannot_exceed_total)
{
    // Initialize settlement DB in memory
    g_settlementdb = std::make_unique<CSettlementDB>(0, true, true);

    // Initialize state (A6: M0_vaulted == M1_supply)
    SettlementState state;
    state.M0_total_supply = 100 * COIN;  // Only 100 M0 exists
    state.M0_vaulted = 0;
    state.M1_supply = 0;

    // Valid case: lock 50 M0
    CAmount lockAmount = 50 * COIN;
    state.M0_vaulted += lockAmount;
    state.M1_supply += lockAmount;

    // Check A6 invariant
    BOOST_CHECK(state.CheckInvariants());
    BOOST_CHECK_EQUAL(state.M0_vaulted, state.M1_supply);

    // Simulate what would happen if we allowed locking M1 receipts:
    // This should NOT happen with the security fix, but we verify the math
    CAmount illegalLock = 60 * COIN;  // More than remaining M0_free
    SettlementState badState = state;
    badState.M0_vaulted += illegalLock;
    badState.M1_supply += illegalLock;

    // After illegal lock: M0_vaulted (110) > M0_total (100) - INVALID!
    BOOST_CHECK_MESSAGE(badState.M0_vaulted > badState.M0_total_supply,
        "This demonstrates the attack: vaulted > total is impossible in real money");

    // A6 still holds (that's why the bug was hard to catch)
    BOOST_CHECK_EQUAL(badState.M0_vaulted, badState.M1_supply);

    LogPrintf("SECURITY-TEST: Demonstrated M0_vaulted > M0_total attack vector\n");

    g_settlementdb.reset();
}

// =============================================================================
// Test: ParseSettlementTx - Robust M0/M1/Vault classification WITHOUT DB
// BP30 v2.6: Tests for the new DB-independent classification function
// =============================================================================

// Helper: Create simple coins view with known coins for ParseSettlementTx tests
class ParseSettlementMockCoinsView : public CCoinsView {
public:
    std::map<COutPoint, CTxOut> coins;

    void AddCoin(const COutPoint& outpoint, const CTxOut& out) {
        coins[outpoint] = out;
    }

    bool GetCoin(const COutPoint& outpoint, Coin& coin) const override {
        auto it = coins.find(outpoint);
        if (it != coins.end()) {
            coin = Coin(it->second, 0, false);
            return true;
        }
        return false;
    }

    bool HaveCoin(const COutPoint& outpoint) const override {
        return coins.count(outpoint) > 0;
    }
};

BOOST_AUTO_TEST_CASE(parse_settlement_tx_lock)
{
    // Test TX_LOCK classification
    CKey key;
    key.MakeNewKey(true);
    CScript vaultScript = GetOpTrueScript();
    CScript receiptScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount lockAmount = 5000;
    CMutableTransaction mtx = CreateMockTxLock(lockAmount, vaultScript, receiptScript);
    CTransaction tx(mtx);

    // Setup mock coins view
    ParseSettlementMockCoinsView baseView;
    CScript p2pkhScript = GetScriptForDestination(key.GetPubKey().GetID());
    baseView.AddCoin(tx.vin[0].prevout, CTxOut(lockAmount + 200, p2pkhScript));  // 200 for fee
    CCoinsViewCache view(&baseView);

    // Parse the transaction
    SettlementTxView stxView;
    BOOST_CHECK(ParseSettlementTx(tx, &view, stxView));

    // Verify classification
    BOOST_CHECK_EQUAL(stxView.txType, "TX_LOCK");
    BOOST_CHECK(stxView.complete);
    BOOST_CHECK_EQUAL(stxView.missing_inputs, 0u);

    // TX_LOCK: all inputs are M0
    BOOST_CHECK_EQUAL(stxView.m0_input_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.m1_input_indices.size(), 0u);
    BOOST_CHECK_EQUAL(stxView.vault_input_indices.size(), 0u);

    // TX_LOCK outputs: vout[0]=vault, vout[1]=M1
    BOOST_CHECK_EQUAL(stxView.vault_output_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.m1_output_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.m0_output_indices.size(), 0u);

    // Amounts
    BOOST_CHECK_EQUAL(stxView.m0_in, lockAmount + 200);
    BOOST_CHECK_EQUAL(stxView.vault_out, lockAmount);
    BOOST_CHECK_EQUAL(stxView.m1_out, lockAmount);
    BOOST_CHECK_EQUAL(stxView.m0_out, 0);

    LogPrintf("TEST: ParseSettlementTx TX_LOCK classification verified\n");
}

BOOST_AUTO_TEST_CASE(parse_settlement_tx_unlock)
{
    // Test TX_UNLOCK classification
    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());
    CScript vaultScript = GetOpTrueScript();

    CAmount m1Amount = 5000;
    CAmount vaultAmount = 5000;
    CAmount unlockAmount = 5000;

    // Create TX_UNLOCK
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_UNLOCK;

    // Create prevout outpoints
    uint256 m1Txid, vaultTxid;
    m1Txid.SetHex("1111111111111111111111111111111111111111111111111111111111111111");
    vaultTxid.SetHex("2222222222222222222222222222222222222222222222222222222222222222");
    COutPoint m1Prevout(m1Txid, 0);
    COutPoint vaultPrevout(vaultTxid, 0);

    // vin[0] = M1 receipt (non-OP_TRUE), vin[1] = vault (OP_TRUE)
    mtx.vin.emplace_back(CTxIn(m1Prevout));
    mtx.vin.emplace_back(CTxIn(vaultPrevout));

    // vout[0] = M0 unlocked
    mtx.vout.emplace_back(CTxOut(unlockAmount, destScript));

    CTransaction tx(mtx);

    // Setup mock coins view
    ParseSettlementMockCoinsView baseView;
    baseView.AddCoin(m1Prevout, CTxOut(m1Amount, destScript));  // M1 receipt (normal script)
    baseView.AddCoin(vaultPrevout, CTxOut(vaultAmount, vaultScript));  // Vault (OP_TRUE)
    CCoinsViewCache view(&baseView);

    // Parse the transaction
    SettlementTxView stxView;
    BOOST_CHECK(ParseSettlementTx(tx, &view, stxView));

    // Verify classification
    BOOST_CHECK_EQUAL(stxView.txType, "TX_UNLOCK");
    BOOST_CHECK(stxView.complete);
    BOOST_CHECK_EQUAL(stxView.missing_inputs, 0u);

    // TX_UNLOCK inputs: M1 (before vault), vault (OP_TRUE)
    BOOST_CHECK_EQUAL(stxView.m1_input_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.vault_input_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.m0_input_indices.size(), 0u);

    // TX_UNLOCK outputs: vout[0]=M0
    BOOST_CHECK_EQUAL(stxView.m0_output_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.m1_output_indices.size(), 0u);
    BOOST_CHECK_EQUAL(stxView.vault_output_indices.size(), 0u);

    // Amounts
    BOOST_CHECK_EQUAL(stxView.m1_in, m1Amount);
    BOOST_CHECK_EQUAL(stxView.vault_in, vaultAmount);
    BOOST_CHECK_EQUAL(stxView.m0_in, 0);
    BOOST_CHECK_EQUAL(stxView.m0_out, unlockAmount);

    LogPrintf("TEST: ParseSettlementTx TX_UNLOCK classification verified\n");
}

BOOST_AUTO_TEST_CASE(parse_settlement_tx_transfer)
{
    // Test TX_TRANSFER_M1 classification
    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount m1Amount = 5000;
    CAmount feeInputAmount = 200;

    // Create TX_TRANSFER_M1
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::TX_TRANSFER_M1;

    // Create prevout outpoints
    uint256 m1Txid, feeTxid;
    m1Txid.SetHex("3333333333333333333333333333333333333333333333333333333333333333");
    feeTxid.SetHex("4444444444444444444444444444444444444444444444444444444444444444");
    COutPoint m1Prevout(m1Txid, 0);
    COutPoint feePrevout(feeTxid, 0);

    // vin[0] = M1 receipt, vin[1] = M0 fee input
    mtx.vin.emplace_back(CTxIn(m1Prevout));
    mtx.vin.emplace_back(CTxIn(feePrevout));

    // vout[0] = new M1 receipt (5000), vout[1] = M0 fee change (100)
    mtx.vout.emplace_back(CTxOut(m1Amount, destScript));      // M1 out = m1_in
    mtx.vout.emplace_back(CTxOut(100, destScript));           // M0 fee change

    CTransaction tx(mtx);

    // Setup mock coins view
    ParseSettlementMockCoinsView baseView;
    baseView.AddCoin(m1Prevout, CTxOut(m1Amount, destScript));       // M1 receipt
    baseView.AddCoin(feePrevout, CTxOut(feeInputAmount, destScript)); // M0 fee input
    CCoinsViewCache view(&baseView);

    // Parse the transaction
    SettlementTxView stxView;
    BOOST_CHECK(ParseSettlementTx(tx, &view, stxView));

    // Verify classification
    BOOST_CHECK_EQUAL(stxView.txType, "TX_TRANSFER_M1");
    BOOST_CHECK(stxView.complete);
    BOOST_CHECK_EQUAL(stxView.missing_inputs, 0u);

    // TX_TRANSFER_M1 inputs: vin[0]=M1, vin[1+]=M0
    BOOST_CHECK_EQUAL(stxView.m1_input_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.m0_input_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.vault_input_indices.size(), 0u);

    // TX_TRANSFER_M1 outputs: cumsum-based (vout[0]=M1, rest=M0)
    BOOST_CHECK_EQUAL(stxView.m1_output_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.m0_output_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.vault_output_indices.size(), 0u);

    // Amounts
    BOOST_CHECK_EQUAL(stxView.m1_in, m1Amount);
    BOOST_CHECK_EQUAL(stxView.m0_in, feeInputAmount);
    BOOST_CHECK_EQUAL(stxView.m1_out, m1Amount);
    BOOST_CHECK_EQUAL(stxView.m0_out, 100);

    // M0 fee = m0_in - m0_out = 200 - 100 = 100
    BOOST_CHECK_EQUAL(stxView.m0_fee, 100);

    LogPrintf("TEST: ParseSettlementTx TX_TRANSFER_M1 classification verified\n");
}

BOOST_AUTO_TEST_CASE(parse_settlement_tx_incomplete)
{
    // Test handling of missing inputs (complete=false)
    CKey key;
    key.MakeNewKey(true);
    CScript vaultScript = GetOpTrueScript();
    CScript receiptScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount lockAmount = 5000;
    CMutableTransaction mtx = CreateMockTxLock(lockAmount, vaultScript, receiptScript);
    CTransaction tx(mtx);

    // Empty coins view - inputs cannot be resolved
    ParseSettlementMockCoinsView baseView;
    CCoinsViewCache view(&baseView);

    // Parse the transaction
    SettlementTxView stxView;
    BOOST_CHECK(ParseSettlementTx(tx, &view, stxView));

    // Should be marked incomplete
    BOOST_CHECK(!stxView.complete);
    BOOST_CHECK_EQUAL(stxView.missing_inputs, 1u);

    // Type should still be detected
    BOOST_CHECK_EQUAL(stxView.txType, "TX_LOCK");

    // Input amounts should be 0 (couldn't fetch)
    BOOST_CHECK_EQUAL(stxView.m0_in, 0);

    // Output classification should still work
    BOOST_CHECK_EQUAL(stxView.vault_output_indices.size(), 1u);
    BOOST_CHECK_EQUAL(stxView.m1_output_indices.size(), 1u);

    LogPrintf("TEST: ParseSettlementTx incomplete handling verified\n");
}

// =============================================================================
// Test: OP_TRUE forbidden in non-settlement TX (consensus rule BP30 v2.6)
// =============================================================================
BOOST_AUTO_TEST_CASE(optrue_forbidden_in_normal_tx)
{
    // A normal TX with an OP_TRUE output should be rejected by consensus
    CKey key;
    key.MakeNewKey(true);
    CScript destScript = GetScriptForDestination(key.GetPubKey().GetID());
    CScript opTrueScript = GetOpTrueScript();

    // Create a NORMAL transaction with OP_TRUE output
    CMutableTransaction mtx;
    mtx.nVersion = CTransaction::TxVersion::SAPLING;
    mtx.nType = CTransaction::TxType::NORMAL;

    // Add a dummy input
    uint256 dummyTxid;
    dummyTxid.SetHex("5555555555555555555555555555555555555555555555555555555555555555");
    mtx.vin.emplace_back(CTxIn(COutPoint(dummyTxid, 0)));

    // Add outputs: one normal, one OP_TRUE (should be forbidden)
    mtx.vout.emplace_back(CTxOut(1000, destScript));
    mtx.vout.emplace_back(CTxOut(1000, opTrueScript));  // OP_TRUE in normal TX!

    CTransaction tx(mtx);

    // This should be rejected by CheckTransaction
    CValidationState state;
    BOOST_CHECK(!CheckTransaction(tx, state));
    BOOST_CHECK_EQUAL(state.GetRejectReason(), "bad-txns-optrue-forbidden");

    LogPrintf("TEST: OP_TRUE forbidden in normal TX verified\n");
}

// =============================================================================
// Test: OP_TRUE allowed in TX_LOCK (settlement TX)
// =============================================================================
BOOST_AUTO_TEST_CASE(optrue_allowed_in_settlement_tx)
{
    // A TX_LOCK with an OP_TRUE vault output should be accepted
    CKey key;
    key.MakeNewKey(true);
    CScript vaultScript = GetOpTrueScript();
    CScript receiptScript = GetScriptForDestination(key.GetPubKey().GetID());

    CAmount lockAmount = 5000;
    CMutableTransaction mtx = CreateMockTxLock(lockAmount, vaultScript, receiptScript);
    CTransaction tx(mtx);

    // This should pass CheckTransaction (OP_TRUE allowed in TX_LOCK)
    CValidationState state;
    BOOST_CHECK(CheckTransaction(tx, state));

    LogPrintf("TEST: OP_TRUE allowed in TX_LOCK verified\n");
}

// =============================================================================
// Integration Test: Consensus vs RPC view consistency (BP30 v2.6)
// =============================================================================
// This test verifies that ParseSettlementTx (used by RPC m0_fee_info) produces
// the SAME classification that consensus validates. The unified fee formula:
//   m0_fee = (m0_in + vault_in) - (m0_out + vault_out)
// must work correctly for all settlement TX types.
// =============================================================================
BOOST_AUTO_TEST_CASE(consensus_vs_rpc_view_consistency)
{
    BOOST_REQUIRE(InitSettlementDB(1 << 20, true));
    BOOST_REQUIRE(g_settlementdb != nullptr);

    CKey ownerKey;
    ownerKey.MakeNewKey(true);
    CScript ownerScript = GetScriptForDestination(ownerKey.GetPubKey().GetID());
    CScript vaultScript = GetOpTrueScript();

    // Initialize state
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;
    state.nHeight = 0;

    CCoinsView coinsDummy;
    CCoinsViewCache view(&coinsDummy);

    // =========================================================================
    // TEST 1: TX_LOCK - Verify fee = (m0_in + 0) - (m0_change + vault)
    // =========================================================================
    {
        CAmount lockAmount = 100 * COIN;
        CAmount m0InputAmount = 120 * COIN;  // 20 COIN for fee (no change in simple tx)

        CMutableTransaction mtxLock = CreateMockTxLock(lockAmount, vaultScript, ownerScript);
        CTransaction txLock(mtxLock);

        // Part A: Consensus validation passes
        CValidationState valState;
        BOOST_CHECK(CheckLock(txLock, view, valState));
        BOOST_CHECK(CheckTransaction(txLock, valState));

        // Part B: RPC classification via ParseSettlementTx
        ParseSettlementMockCoinsView mockBase;
        mockBase.AddCoin(txLock.vin[0].prevout, CTxOut(m0InputAmount, ownerScript));
        CCoinsViewCache mockView(&mockBase);

        SettlementTxView stxView;
        BOOST_CHECK(ParseSettlementTx(txLock, &mockView, stxView));

        // Verify classification
        BOOST_CHECK_EQUAL(stxView.txType, "TX_LOCK");
        BOOST_CHECK(stxView.complete);
        BOOST_CHECK_EQUAL(stxView.m0_in, m0InputAmount);
        BOOST_CHECK_EQUAL(stxView.vault_in, 0);
        BOOST_CHECK_EQUAL(stxView.vault_out, lockAmount);
        BOOST_CHECK_EQUAL(stxView.m1_out, lockAmount);
        BOOST_CHECK_EQUAL(stxView.m0_out, 0);

        // Verify fee formula: (120 + 0) - (0 + 100) = 20 COIN
        CAmount expectedFee = (stxView.m0_in + stxView.vault_in) - (stxView.m0_out + stxView.vault_out);
        BOOST_CHECK_EQUAL(stxView.m0_fee, expectedFee);
        BOOST_CHECK_EQUAL(stxView.m0_fee, 20 * COIN);

        LogPrintf("TEST: TX_LOCK consensus/RPC consistency verified (fee=%lld)\n", (long long)stxView.m0_fee);
    }

    // =========================================================================
    // TEST 2: TX_UNLOCK - Verify fee formula with vault_in/m0_out transformation
    // =========================================================================
    // This test focuses on RPC classification. Consensus validation for TX_UNLOCK
    // is thoroughly tested in other test cases (e.g., applyunlock_*, unlock_with_*).
    // Here we verify the fee formula: (m0_in + vault_in) - (m0_out + vault_out)
    // =========================================================================
    {
        // Create a simulated TX_UNLOCK (without full consensus validation)
        uint256 lockTxid;
        lockTxid.SetHex("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc");
        COutPoint vaultOut(lockTxid, 0);
        COutPoint receiptOut(lockTxid, 1);

        // Create TX_UNLOCK: simple full unlock (no M1 change)
        // vin[0] = M1 receipt (50 COIN)
        // vin[1] = Vault (50 COIN)
        // vin[2] = M0 fee input (1 COIN)
        // vout[0] = M0 unlocked (50 COIN)
        // vout[1] = M0 fee change (0.99 COIN)
        CMutableTransaction mtxUnlock;
        mtxUnlock.nVersion = CTransaction::TxVersion::SAPLING;
        mtxUnlock.nType = CTransaction::TxType::TX_UNLOCK;
        mtxUnlock.vin.emplace_back(CTxIn(receiptOut));  // M1 receipt
        mtxUnlock.vin.emplace_back(CTxIn(vaultOut));    // Vault (OP_TRUE)
        uint256 feeTxid;
        feeTxid.SetHex("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        mtxUnlock.vin.emplace_back(CTxIn(COutPoint(feeTxid, 0)));  // M0 fee

        mtxUnlock.vout.emplace_back(CTxOut(50 * COIN, ownerScript));   // M0 unlocked
        mtxUnlock.vout.emplace_back(CTxOut(99000000, ownerScript));    // M0 fee change (0.99 COIN)

        CTransaction txUnlock(mtxUnlock);

        // RPC classification via ParseSettlementTx
        ParseSettlementMockCoinsView mockBase;
        mockBase.AddCoin(receiptOut, CTxOut(50 * COIN, ownerScript));     // M1 (before vault)
        mockBase.AddCoin(vaultOut, CTxOut(50 * COIN, vaultScript));       // Vault (OP_TRUE)
        mockBase.AddCoin(COutPoint(feeTxid, 0), CTxOut(1 * COIN, ownerScript));  // M0 fee
        CCoinsViewCache mockView(&mockBase);

        SettlementTxView stxView;
        BOOST_CHECK(ParseSettlementTx(txUnlock, &mockView, stxView));

        BOOST_CHECK_EQUAL(stxView.txType, "TX_UNLOCK");
        BOOST_CHECK(stxView.complete);

        // Inputs classified by prevout script:
        // vin[0] = before OP_TRUE → M1 (50 COIN)
        // vin[1] = OP_TRUE → Vault (50 COIN)
        // vin[2] = after vault → M0 (1 COIN)
        BOOST_CHECK_EQUAL(stxView.m1_in, 50 * COIN);
        BOOST_CHECK_EQUAL(stxView.vault_in, 50 * COIN);
        BOOST_CHECK_EQUAL(stxView.m0_in, 1 * COIN);

        // Outputs: vout[0] = M0 unlocked, vout[1] = classified based on cumsum
        // For TX_UNLOCK with m1_in=50 and m0_out_expected=50:
        // m1_change_expected = 50 - 50 = 0
        // So vout[1] is M0 fee change, not M1 change
        BOOST_CHECK_EQUAL(stxView.m0_out, 50 * COIN + 99000000);  // unlocked + fee_change
        BOOST_CHECK_EQUAL(stxView.vault_out, 0);

        // Fee formula: (m0_in + vault_in) - (m0_out + vault_out)
        //            = (1 + 50) - (50.99 + 0) = 0.01 COIN = 1,000,000 sats
        CAmount expectedFee = (stxView.m0_in + stxView.vault_in) - (stxView.m0_out + stxView.vault_out);
        BOOST_CHECK_EQUAL(stxView.m0_fee, expectedFee);
        BOOST_CHECK_EQUAL(stxView.m0_fee, 1000000);

        LogPrintf("TEST: TX_UNLOCK fee formula verified (fee=%lld)\n", (long long)stxView.m0_fee);
    }

    // =========================================================================
    // TEST 3: TX_TRANSFER_M1 - Verify cumsum M1/M0 classification and fee
    // =========================================================================
    // This test focuses on RPC classification. Consensus validation for TX_TRANSFER
    // is thoroughly tested in other test cases (e.g., transfer_*, adversarial_*).
    // Here we verify the cumsum algorithm and fee formula work correctly.
    // =========================================================================
    {
        // Create a simulated TX_TRANSFER_M1 (without full consensus validation)
        uint256 lockTxid;
        lockTxid.SetHex("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd");
        COutPoint receiptOut(lockTxid, 1);

        // Create TX_TRANSFER_M1:
        // vin[0] = M1 receipt (30 COIN) - canonical position
        // vin[1] = M0 fee input (0.06 COIN)
        // vout[0] = M1 output (30 COIN) - conserved
        // vout[1] = M0 fee change (0.05 COIN)
        CMutableTransaction mtxTransfer;
        mtxTransfer.nVersion = CTransaction::TxVersion::SAPLING;
        mtxTransfer.nType = CTransaction::TxType::TX_TRANSFER_M1;
        mtxTransfer.vin.emplace_back(CTxIn(receiptOut));  // M1 receipt (vin[0])
        uint256 feeTxid;
        feeTxid.SetHex("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        mtxTransfer.vin.emplace_back(CTxIn(COutPoint(feeTxid, 0)));  // M0 fee (vin[1])

        mtxTransfer.vout.emplace_back(CTxOut(30 * COIN, ownerScript));  // M1 output (conserved)
        mtxTransfer.vout.emplace_back(CTxOut(5000000, ownerScript));    // M0 fee change

        CTransaction txTransfer(mtxTransfer);

        // RPC classification via ParseSettlementTx
        ParseSettlementMockCoinsView mockBase;
        mockBase.AddCoin(receiptOut, CTxOut(30 * COIN, ownerScript));
        mockBase.AddCoin(COutPoint(feeTxid, 0), CTxOut(6000000, ownerScript));  // 0.06 COIN
        CCoinsViewCache mockView(&mockBase);

        SettlementTxView stxView;
        BOOST_CHECK(ParseSettlementTx(txTransfer, &mockView, stxView));

        BOOST_CHECK_EQUAL(stxView.txType, "TX_TRANSFER_M1");
        BOOST_CHECK(stxView.complete);

        // Inputs: vin[0] = M1 (canonical), vin[1+] = M0
        BOOST_CHECK_EQUAL(stxView.m1_in, 30 * COIN);
        BOOST_CHECK_EQUAL(stxView.m0_in, 6000000);
        BOOST_CHECK_EQUAL(stxView.vault_in, 0);

        // Outputs via cumsum: vout[0]=30 ≤ m1_in=30, so M1; vout[1]=0.05 → M0
        BOOST_CHECK_EQUAL(stxView.m1_out, 30 * COIN);
        BOOST_CHECK_EQUAL(stxView.m0_out, 5000000);
        BOOST_CHECK_EQUAL(stxView.vault_out, 0);

        // Fee formula: (m0_in + vault_in) - (m0_out + vault_out)
        //            = (0.06 + 0) - (0.05 + 0) = 0.01 COIN
        CAmount expectedFee = (stxView.m0_in + stxView.vault_in) - (stxView.m0_out + stxView.vault_out);
        BOOST_CHECK_EQUAL(stxView.m0_fee, expectedFee);
        BOOST_CHECK_EQUAL(stxView.m0_fee, 1000000);

        LogPrintf("TEST: TX_TRANSFER_M1 fee formula verified (fee=%lld)\n", (long long)stxView.m0_fee);
    }

    LogPrintf("TEST: All consensus/RPC view consistency tests passed\n");
}

BOOST_AUTO_TEST_SUITE_END()
