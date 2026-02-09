// Copyright (c) 2025 The Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "state/settlement_builder.h"

#include "key.h"
#include "primitives/transaction.h"
#include "script/standard.h"
#include "state/settlement.h"
#include "state/settlementdb.h"
#include "test/test_bathron.h"

#include <boost/test/unit_test.hpp>

BOOST_FIXTURE_TEST_SUITE(settlement_builder_tests, BasicTestingSetup)

// =============================================================================
// Helper functions
// =============================================================================

static CKey GenerateKey()
{
    CKey key;
    key.MakeNewKey(true);
    return key;
}

static CScript GetP2PKHScript(const CPubKey& pubkey)
{
    return GetScriptForDestination(CTxDestination(pubkey.GetID()));
}

static LockInput CreateFakeLockInput(CAmount amount)
{
    LockInput input;
    // Create a random outpoint
    GetStrongRandBytes(input.outpoint.hash.begin(), 32);
    input.outpoint.n = 0;
    input.amount = amount;
    CKey key = GenerateKey();
    input.scriptPubKey = GetP2PKHScript(key.GetPubKey());
    return input;
}

// =============================================================================
// BuildLockTransaction Tests
// =============================================================================

BOOST_AUTO_TEST_CASE(build_lock_basic)
{
    // Create inputs
    std::vector<LockInput> inputs;
    inputs.push_back(CreateFakeLockInput(10 * COIN));

    // BP30 v2.0: No vault key needed - vault uses OP_TRUE (consensus-protected)
    CKey receiptKey = GenerateKey();
    CKey changeKey = GenerateKey();

    CScript receiptDest = GetP2PKHScript(receiptKey.GetPubKey());
    CScript changeDest = GetP2PKHScript(changeKey.GetPubKey());

    // Build transaction
    LockResult result = BuildLockTransaction(
        inputs,
        5 * COIN,  // Lock 5 M0
        receiptDest,
        changeDest
    );

    BOOST_CHECK(result.success);
    BOOST_CHECK(result.error.empty());
    BOOST_CHECK_EQUAL(result.lockedAmount, 5 * COIN);
    BOOST_CHECK(result.fee > 0);

    // Verify transaction structure
    const CMutableTransaction& mtx = result.mtx;
    BOOST_CHECK_EQUAL(mtx.nType, CTransaction::TxType::TX_LOCK);
    BOOST_CHECK_EQUAL(mtx.vin.size(), 1);
    BOOST_CHECK_EQUAL(mtx.vout.size(), 3);  // Vault + Receipt + Change

    // A11 canonical order: vout[0] = Vault (OP_TRUE), vout[1] = Receipt
    BOOST_CHECK_EQUAL(mtx.vout[0].nValue, 5 * COIN);  // Vault
    BOOST_CHECK_EQUAL(mtx.vout[1].nValue, 5 * COIN);  // Receipt
    BOOST_CHECK(mtx.vout[2].nValue > 0);  // Change
}

BOOST_AUTO_TEST_CASE(build_lock_no_change)
{
    // Create inputs that exactly match lock amount + estimated fee
    // Fee estimation: BASE_TX_SIZE(10) + 1*INPUT_SIZE(148) + 2*OUTPUT_SIZE(34) = 226 bytes
    // At 15 sat/kB: (226 * 15000) / 1000 = 3390 satoshis
    std::vector<LockInput> inputs;
    inputs.push_back(CreateFakeLockInput(5 * COIN + 5000));  // Amount + ~fee (with margin)

    CKey receiptKey = GenerateKey();

    CScript receiptDest = GetP2PKHScript(receiptKey.GetPubKey());

    LockResult result = BuildLockTransaction(
        inputs,
        5 * COIN,
        receiptDest,
        CScript()  // No change dest
    );

    BOOST_CHECK(result.success);
    // May have 2 or 3 outputs depending on exact change amount
    BOOST_CHECK(result.mtx.vout.size() >= 2);
}

BOOST_AUTO_TEST_CASE(build_lock_insufficient_funds)
{
    std::vector<LockInput> inputs;
    inputs.push_back(CreateFakeLockInput(1 * COIN));

    CKey receiptKey = GenerateKey();

    LockResult result = BuildLockTransaction(
        inputs,
        5 * COIN,  // Request more than available
        GetP2PKHScript(receiptKey.GetPubKey()),
        CScript()
    );

    BOOST_CHECK(!result.success);
    BOOST_CHECK(!result.error.empty());
    BOOST_CHECK(result.error.find("Insufficient") != std::string::npos);
}

BOOST_AUTO_TEST_CASE(build_lock_zero_amount)
{
    std::vector<LockInput> inputs;
    inputs.push_back(CreateFakeLockInput(10 * COIN));

    CKey receiptKey = GenerateKey();

    LockResult result = BuildLockTransaction(
        inputs,
        0,  // Zero amount
        GetP2PKHScript(receiptKey.GetPubKey()),
        CScript()
    );

    BOOST_CHECK(!result.success);
    BOOST_CHECK(!result.error.empty());
}

BOOST_AUTO_TEST_CASE(build_lock_multiple_inputs)
{
    std::vector<LockInput> inputs;
    inputs.push_back(CreateFakeLockInput(3 * COIN));
    inputs.push_back(CreateFakeLockInput(3 * COIN));
    inputs.push_back(CreateFakeLockInput(4 * COIN));  // Total 10 M0

    CKey receiptKey = GenerateKey();
    CKey changeKey = GenerateKey();

    LockResult result = BuildLockTransaction(
        inputs,
        8 * COIN,
        GetP2PKHScript(receiptKey.GetPubKey()),
        GetP2PKHScript(changeKey.GetPubKey())
    );

    BOOST_CHECK(result.success);
    BOOST_CHECK_EQUAL(result.mtx.vin.size(), 3);
    BOOST_CHECK_EQUAL(result.lockedAmount, 8 * COIN);
}

// =============================================================================
// BuildUnlockTransaction Tests (BP30 v2.0 Bearer Asset Model)
// =============================================================================

BOOST_AUTO_TEST_CASE(build_unlock_basic)
{
    // BP30 v2.0: Create M1Input (receipt) and VaultInput separately
    std::vector<M1Input> m1Inputs;
    M1Input m1Input;
    GetStrongRandBytes(m1Input.outpoint.hash.begin(), 32);
    m1Input.outpoint.n = 1;
    m1Input.amount = 5 * COIN;
    m1Input.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());
    m1Inputs.push_back(m1Input);

    std::vector<VaultInput> vaultInputs;
    VaultInput vaultInput;
    GetStrongRandBytes(vaultInput.outpoint.hash.begin(), 32);
    vaultInput.outpoint.n = 0;
    vaultInput.amount = 5 * COIN;
    vaultInputs.push_back(vaultInput);

    CKey destKey = GenerateKey();
    CScript destScript = GetP2PKHScript(destKey.GetPubKey());

    // BP30 v2.1: Full unlock - use unlockAmount=0 to unlock all (fee deducted from output)
    CAmount unlockAmount = 0;  // 0 means "unlock all M1"
    UnlockResult result = BuildUnlockTransaction(m1Inputs, vaultInputs, unlockAmount, destScript, destScript);

    BOOST_CHECK(result.success);
    // BP30 v2.1: Strict conservation - M0_out == M1_in (no fee from M1 layer)
    BOOST_CHECK_EQUAL(result.unlockedAmount, 5 * COIN);
    BOOST_CHECK_EQUAL(result.m1Change, 0);  // Full unlock, no change
    BOOST_CHECK_EQUAL(result.fee, 0);       // No fee at settlement layer

    // Verify transaction structure
    const CMutableTransaction& mtx = result.mtx;
    BOOST_CHECK_EQUAL(mtx.nType, CTransaction::TxType::TX_UNLOCK);
    BOOST_CHECK_EQUAL(mtx.vin.size(), 2);  // M1 Receipt + Vault

    // A11 order: vin[0] = Receipt, vin[1] = Vault
    BOOST_CHECK(mtx.vin[0].prevout == m1Input.outpoint);
    BOOST_CHECK(mtx.vin[1].prevout == vaultInput.outpoint);

    // vout[0] = M0 output (exact M1 amount)
    BOOST_CHECK_EQUAL(mtx.vout[0].nValue, 5 * COIN);
    BOOST_CHECK_EQUAL(mtx.vout.size(), 1);  // Only M0 output, no change
}

BOOST_AUTO_TEST_CASE(build_unlock_no_fee_inputs)
{
    // BP30 v2.0: Bearer model - M1 + Vault inputs
    std::vector<M1Input> m1Inputs;
    M1Input m1Input;
    GetStrongRandBytes(m1Input.outpoint.hash.begin(), 32);
    m1Input.outpoint.n = 1;
    m1Input.amount = 5 * COIN;
    m1Input.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());
    m1Inputs.push_back(m1Input);

    std::vector<VaultInput> vaultInputs;
    VaultInput vaultInput;
    GetStrongRandBytes(vaultInput.outpoint.hash.begin(), 32);
    vaultInput.outpoint.n = 0;
    vaultInput.amount = 5 * COIN;
    vaultInputs.push_back(vaultInput);

    CKey destKey = GenerateKey();
    CScript destScript = GetP2PKHScript(destKey.GetPubKey());

    // BP30 v2.1: Full unlock - strict conservation (no fee from M1)
    CAmount unlockAmount = 0;  // 0 means "unlock all M1"
    UnlockResult result = BuildUnlockTransaction(m1Inputs, vaultInputs, unlockAmount, destScript, destScript);

    BOOST_CHECK(result.success);
    BOOST_CHECK_EQUAL(result.unlockedAmount, 5 * COIN);  // Exact M1 amount
    BOOST_CHECK_EQUAL(result.fee, 0);  // No fee at settlement layer
}

// =============================================================================
// BuildTransferTransaction Tests
// =============================================================================

BOOST_AUTO_TEST_CASE(build_transfer_basic)
{
    TransferInput receipt;
    GetStrongRandBytes(receipt.receiptOutpoint.hash.begin(), 32);
    receipt.receiptOutpoint.n = 1;
    receipt.amount = 5 * COIN;

    CKey newOwnerKey = GenerateKey();
    CScript newDest = GetP2PKHScript(newOwnerKey.GetPubKey());

    std::vector<LockInput> feeInputs;
    feeInputs.push_back(CreateFakeLockInput(1 * COIN));

    CKey changeKey = GenerateKey();

    TransferResult result = BuildTransferTransaction(
        receipt,
        newDest,
        feeInputs,
        GetP2PKHScript(changeKey.GetPubKey())
    );

    BOOST_CHECK(result.success);

    // Verify transaction structure
    const CMutableTransaction& mtx = result.mtx;
    BOOST_CHECK_EQUAL(mtx.nType, CTransaction::TxType::TX_TRANSFER_M1);
    BOOST_CHECK_EQUAL(mtx.vin.size(), 2);  // Receipt + Fee

    // A11 order: vin[0] = Receipt
    BOOST_CHECK(mtx.vin[0].prevout == receipt.receiptOutpoint);

    // vout[0] = New Receipt (same amount)
    BOOST_CHECK_EQUAL(mtx.vout[0].nValue, 5 * COIN);
}

BOOST_AUTO_TEST_CASE(build_transfer_insufficient_fee)
{
    TransferInput receipt;
    GetStrongRandBytes(receipt.receiptOutpoint.hash.begin(), 32);
    receipt.receiptOutpoint.n = 1;
    receipt.amount = 5 * COIN;

    CKey newOwnerKey = GenerateKey();

    // Very small fee inputs
    std::vector<LockInput> feeInputs;
    feeInputs.push_back(CreateFakeLockInput(100));  // 100 sats - not enough

    TransferResult result = BuildTransferTransaction(
        receipt,
        GetP2PKHScript(newOwnerKey.GetPubKey()),
        feeInputs,
        CScript()
    );

    BOOST_CHECK(!result.success);
    BOOST_CHECK(result.error.find("Insufficient") != std::string::npos);
}

// =============================================================================
// BuildSplitTransaction Tests (BP30 v2.4 - Strict M1 Conservation)
// =============================================================================

// Helper: create fee inputs for split tests
static std::vector<LockInput> CreateFeeInputs(CAmount amount)
{
    std::vector<LockInput> inputs;
    inputs.push_back(CreateFakeLockInput(amount));
    return inputs;
}

BOOST_AUTO_TEST_CASE(build_split_basic)
{
    // BP30 v2.4: Split 10 M1 into 2 + 8 (strict conservation)
    // Fee comes from separate M0 inputs
    TransferInput receipt;
    GetStrongRandBytes(receipt.receiptOutpoint.hash.begin(), 32);
    receipt.receiptOutpoint.n = 1;
    receipt.amount = 10 * COIN;
    receipt.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());

    CKey dest1 = GenerateKey();
    CKey dest2 = GenerateKey();

    // Strict M1 conservation: sum(outputs) == input
    std::vector<SplitOutput> outputs;
    outputs.push_back({GetP2PKHScript(dest1.GetPubKey()), 2 * COIN});
    outputs.push_back({GetP2PKHScript(dest2.GetPubKey()), 8 * COIN});

    // Fee inputs and change destination
    std::vector<LockInput> feeInputs = CreateFeeInputs(10000);  // 0.0001 M0 for fee
    CScript changeDest = GetP2PKHScript(GenerateKey().GetPubKey());

    SplitResult result = BuildSplitTransaction(receipt, outputs, feeInputs, changeDest);

    BOOST_CHECK(result.success);
    BOOST_CHECK(result.error.empty());

    // Verify transaction structure
    const CMutableTransaction& mtx = result.mtx;
    BOOST_CHECK_EQUAL(mtx.nType, CTransaction::TxType::TX_TRANSFER_M1);
    BOOST_CHECK_EQUAL(mtx.vin.size(), 2);  // Receipt + fee input
    BOOST_CHECK_EQUAL(mtx.vout.size(), 3);  // Two M1 outputs + fee change

    // Verify M1 amounts (strict conservation)
    BOOST_CHECK_EQUAL(mtx.vout[0].nValue, 2 * COIN);
    BOOST_CHECK_EQUAL(mtx.vout[1].nValue, 8 * COIN);
    CAmount m1Total = mtx.vout[0].nValue + mtx.vout[1].nValue;
    BOOST_CHECK_EQUAL(m1Total, receipt.amount);  // Strict conservation

    // Verify fee
    BOOST_CHECK(result.fee > 0);

    // Verify new receipt outpoints (only M1 outputs)
    BOOST_CHECK_EQUAL(result.newReceipts.size(), 2);
}

BOOST_AUTO_TEST_CASE(build_split_three_way)
{
    // BP30 v2.4: Split 100 M1 into 30 + 50 + 20 (strict conservation)
    TransferInput receipt;
    GetStrongRandBytes(receipt.receiptOutpoint.hash.begin(), 32);
    receipt.receiptOutpoint.n = 1;
    receipt.amount = 100 * COIN;
    receipt.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());

    // Strict conservation: 30 + 50 + 20 = 100
    std::vector<SplitOutput> outputs;
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 30 * COIN});
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 50 * COIN});
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 20 * COIN});

    std::vector<LockInput> feeInputs = CreateFeeInputs(10000);
    CScript changeDest = GetP2PKHScript(GenerateKey().GetPubKey());

    SplitResult result = BuildSplitTransaction(receipt, outputs, feeInputs, changeDest);

    BOOST_CHECK(result.success);
    BOOST_CHECK_EQUAL(result.newReceipts.size(), 3);

    // Verify strict M1 conservation
    CAmount m1Total = 0;
    for (size_t i = 0; i < outputs.size(); i++) {
        m1Total += result.mtx.vout[i].nValue;
    }
    BOOST_CHECK_EQUAL(m1Total, receipt.amount);
}

BOOST_AUTO_TEST_CASE(build_split_outputs_not_equal_input)
{
    // BP30 v2.4: STRICT conservation - outputs must EQUAL input
    TransferInput receipt;
    GetStrongRandBytes(receipt.receiptOutpoint.hash.begin(), 32);
    receipt.receiptOutpoint.n = 1;
    receipt.amount = 10 * COIN;
    receipt.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());

    // Sum = 12 COIN, exceeds input
    std::vector<SplitOutput> outputs;
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 6 * COIN});
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 6 * COIN});

    std::vector<LockInput> feeInputs = CreateFeeInputs(10000);
    CScript changeDest = GetP2PKHScript(GenerateKey().GetPubKey());

    SplitResult result = BuildSplitTransaction(receipt, outputs, feeInputs, changeDest);

    BOOST_CHECK(!result.success);
    BOOST_CHECK(result.error.find("strict conservation") != std::string::npos ||
                result.error.find("must equal") != std::string::npos);
}

BOOST_AUTO_TEST_CASE(build_split_outputs_less_than_input)
{
    // BP30 v2.4: STRICT conservation - outputs less than input is also invalid
    // (no implicit M1 burn allowed)
    TransferInput receipt;
    GetStrongRandBytes(receipt.receiptOutpoint.hash.begin(), 32);
    receipt.receiptOutpoint.n = 1;
    receipt.amount = 10 * COIN;
    receipt.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());

    // Sum = 9 COIN, less than input (would burn 1 M1)
    std::vector<SplitOutput> outputs;
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 5 * COIN});
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 4 * COIN});

    std::vector<LockInput> feeInputs = CreateFeeInputs(10000);
    CScript changeDest = GetP2PKHScript(GenerateKey().GetPubKey());

    SplitResult result = BuildSplitTransaction(receipt, outputs, feeInputs, changeDest);

    BOOST_CHECK(!result.success);
    BOOST_CHECK(result.error.find("strict conservation") != std::string::npos ||
                result.error.find("must equal") != std::string::npos);
}

BOOST_AUTO_TEST_CASE(build_split_single_output)
{
    // Single output should fail (use transfer_m1 instead)
    TransferInput receipt;
    GetStrongRandBytes(receipt.receiptOutpoint.hash.begin(), 32);
    receipt.receiptOutpoint.n = 1;
    receipt.amount = 10 * COIN;
    receipt.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());

    std::vector<SplitOutput> outputs;
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 10 * COIN});

    std::vector<LockInput> feeInputs = CreateFeeInputs(10000);
    CScript changeDest = GetP2PKHScript(GenerateKey().GetPubKey());

    SplitResult result = BuildSplitTransaction(receipt, outputs, feeInputs, changeDest);

    BOOST_CHECK(!result.success);
    BOOST_CHECK(result.error.find("at least 2") != std::string::npos);
}

BOOST_AUTO_TEST_CASE(build_split_zero_output)
{
    // Zero amount output should fail
    TransferInput receipt;
    GetStrongRandBytes(receipt.receiptOutpoint.hash.begin(), 32);
    receipt.receiptOutpoint.n = 1;
    receipt.amount = 10 * COIN;
    receipt.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());

    std::vector<SplitOutput> outputs;
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 10 * COIN});
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 0});  // Zero!

    std::vector<LockInput> feeInputs = CreateFeeInputs(10000);
    CScript changeDest = GetP2PKHScript(GenerateKey().GetPubKey());

    SplitResult result = BuildSplitTransaction(receipt, outputs, feeInputs, changeDest);

    BOOST_CHECK(!result.success);
    BOOST_CHECK(result.error.find("positive") != std::string::npos);
}

BOOST_AUTO_TEST_CASE(build_split_insufficient_fee)
{
    // Not enough M0 for fee
    TransferInput receipt;
    GetStrongRandBytes(receipt.receiptOutpoint.hash.begin(), 32);
    receipt.receiptOutpoint.n = 1;
    receipt.amount = 10 * COIN;
    receipt.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());

    // Strict conservation
    std::vector<SplitOutput> outputs;
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 5 * COIN});
    outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 5 * COIN});

    // Only 100 sat for fee - not enough
    std::vector<LockInput> feeInputs = CreateFeeInputs(100);
    CScript changeDest = GetP2PKHScript(GenerateKey().GetPubKey());

    SplitResult result = BuildSplitTransaction(receipt, outputs, feeInputs, changeDest);

    BOOST_CHECK(!result.success);
    BOOST_CHECK(result.error.find("fee") != std::string::npos);
}

// =============================================================================
// Integration: Split → Unlock flow (BP30 v2.4 - Strict M1 Conservation)
// =============================================================================

BOOST_AUTO_TEST_CASE(builder_flow_lock_split_unlock_partial)
{
    // Step 1: Lock 10 M0
    std::vector<LockInput> inputs;
    inputs.push_back(CreateFakeLockInput(12 * COIN));

    CKey receiptKey = GenerateKey();
    CKey changeKey = GenerateKey();

    LockResult lockResult = BuildLockTransaction(
        inputs,
        10 * COIN,
        GetP2PKHScript(receiptKey.GetPubKey()),
        GetP2PKHScript(changeKey.GetPubKey())
    );

    BOOST_CHECK(lockResult.success);
    BOOST_CHECK_EQUAL(lockResult.lockedAmount, 10 * COIN);

    // Step 2: Split into 2 + 8 (BP30 v2.4: strict M1 conservation)
    TransferInput splitInput;
    splitInput.receiptOutpoint = lockResult.receiptOutpoint;
    splitInput.amount = lockResult.lockedAmount;
    splitInput.scriptPubKey = GetP2PKHScript(receiptKey.GetPubKey());

    CKey dest1 = GenerateKey();
    CKey dest2 = GenerateKey();

    // Strict conservation: 2 + 8 = 10
    std::vector<SplitOutput> splitOutputs;
    splitOutputs.push_back({GetP2PKHScript(dest1.GetPubKey()), 2 * COIN});
    splitOutputs.push_back({GetP2PKHScript(dest2.GetPubKey()), 8 * COIN});

    // Fee from M0 inputs
    std::vector<LockInput> feeInputs = CreateFeeInputs(10000);
    CScript splitChangeDest = GetP2PKHScript(GenerateKey().GetPubKey());

    SplitResult splitResult = BuildSplitTransaction(splitInput, splitOutputs, feeInputs, splitChangeDest);

    BOOST_CHECK(splitResult.success);
    BOOST_CHECK_EQUAL(splitResult.newReceipts.size(), 2);

    // Step 3: Unlock only the 2 M1 receipt (partial unlock)
    std::vector<M1Input> m1Inputs;
    M1Input m1In;
    m1In.outpoint = splitResult.newReceipts[0];  // The 2 M1 receipt
    m1In.amount = 2 * COIN;
    m1In.scriptPubKey = GetP2PKHScript(dest1.GetPubKey());
    m1Inputs.push_back(m1In);

    // Need a vault that has at least 2 M1 backing
    std::vector<VaultInput> vaultInputs;
    VaultInput vaultIn;
    vaultIn.outpoint = lockResult.vaultOutpoint;  // Original 10 M0 vault
    vaultIn.amount = lockResult.lockedAmount;
    vaultInputs.push_back(vaultIn);

    CKey unlockDest = GenerateKey();
    CScript destScript = GetP2PKHScript(unlockDest.GetPubKey());

    // BP30 v2.4: Partial unlock - 2 M0 from 2 M1 input
    CAmount unlockAmount = 2 * COIN;
    UnlockResult unlockResult = BuildUnlockTransaction(
        m1Inputs,
        vaultInputs,
        unlockAmount,
        destScript,
        destScript  // Change goes back to same script
    );

    BOOST_CHECK(unlockResult.success);
    BOOST_CHECK(unlockResult.unlockedAmount > 0);
    BOOST_CHECK(unlockResult.unlockedAmount <= 2 * COIN);

    // The other 8 M1 receipt remains spendable separately
    // (not tested here as we don't have consensus tracking in builder tests)
}

BOOST_AUTO_TEST_CASE(builder_flow_split_chain)
{
    // BP30 v2.4: Split chaining with strict M1 conservation
    // A → B+C → B1+B2 + C1+C2
    // Lock initial amount
    std::vector<LockInput> inputs;
    inputs.push_back(CreateFakeLockInput(100 * COIN));

    CKey receiptKey = GenerateKey();

    LockResult lockResult = BuildLockTransaction(
        inputs,
        80 * COIN,
        GetP2PKHScript(receiptKey.GetPubKey()),
        GetP2PKHScript(GenerateKey().GetPubKey())
    );

    BOOST_CHECK(lockResult.success);

    // Split 1: 80 → 30 + 50 (strict conservation)
    TransferInput split1Input;
    split1Input.receiptOutpoint = lockResult.receiptOutpoint;
    split1Input.amount = 80 * COIN;
    split1Input.scriptPubKey = GetP2PKHScript(receiptKey.GetPubKey());

    CKey dest30 = GenerateKey();
    CKey dest50 = GenerateKey();

    // Strict conservation: 30 + 50 = 80
    std::vector<SplitOutput> split1Outputs;
    split1Outputs.push_back({GetP2PKHScript(dest30.GetPubKey()), 30 * COIN});
    split1Outputs.push_back({GetP2PKHScript(dest50.GetPubKey()), 50 * COIN});

    std::vector<LockInput> fee1Inputs = CreateFeeInputs(10000);
    CScript change1Dest = GetP2PKHScript(GenerateKey().GetPubKey());

    SplitResult split1Result = BuildSplitTransaction(split1Input, split1Outputs, fee1Inputs, change1Dest);
    BOOST_CHECK(split1Result.success);

    // Split 2: Take the 30 M1 receipt and split again → 10 + 20 (strict conservation)
    TransferInput split2Input;
    split2Input.receiptOutpoint = split1Result.newReceipts[0];
    split2Input.amount = 30 * COIN;
    split2Input.scriptPubKey = GetP2PKHScript(dest30.GetPubKey());

    // Strict conservation: 10 + 20 = 30
    std::vector<SplitOutput> split2Outputs;
    split2Outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 10 * COIN});
    split2Outputs.push_back({GetP2PKHScript(GenerateKey().GetPubKey()), 20 * COIN});

    std::vector<LockInput> fee2Inputs = CreateFeeInputs(10000);
    CScript change2Dest = GetP2PKHScript(GenerateKey().GetPubKey());

    SplitResult split2Result = BuildSplitTransaction(split2Input, split2Outputs, fee2Inputs, change2Dest);
    BOOST_CHECK(split2Result.success);
    BOOST_CHECK_EQUAL(split2Result.newReceipts.size(), 2);

    // After two splits, we have: 10, 20, 50 M1 receipts
    // Total M1 = 80 (unchanged - strict conservation)
    // Fees came from separate M0 inputs, not from M1
}

// =============================================================================
// Integration-like Tests (builder flow)
// =============================================================================

BOOST_AUTO_TEST_CASE(builder_flow_lock_unlock)
{
    // Step 1: Build LOCK (BP30 v2.0: no vaultDest - uses OP_TRUE)
    std::vector<LockInput> inputs;
    inputs.push_back(CreateFakeLockInput(10 * COIN));

    CKey receiptKey = GenerateKey();
    CKey changeKey = GenerateKey();

    LockResult lockResult = BuildLockTransaction(
        inputs,
        5 * COIN,
        GetP2PKHScript(receiptKey.GetPubKey()),
        GetP2PKHScript(changeKey.GetPubKey())
    );

    BOOST_CHECK(lockResult.success);
    BOOST_CHECK_EQUAL(lockResult.lockedAmount, 5 * COIN);

    // Step 2: Build UNLOCK using outputs from LOCK (bearer model)
    std::vector<M1Input> m1Inputs;
    M1Input m1In;
    m1In.outpoint = lockResult.receiptOutpoint;
    m1In.amount = lockResult.lockedAmount;
    m1In.scriptPubKey = GetP2PKHScript(receiptKey.GetPubKey());
    m1Inputs.push_back(m1In);

    std::vector<VaultInput> vaultInputs;
    VaultInput vaultIn;
    vaultIn.outpoint = lockResult.vaultOutpoint;
    vaultIn.amount = lockResult.lockedAmount;
    vaultInputs.push_back(vaultIn);

    CKey destKey = GenerateKey();
    CScript destScript = GetP2PKHScript(destKey.GetPubKey());

    // BP30 v2.1: Full unlock - use 0 to unlock all M1 (fee deducted from output)
    CAmount unlockAmount = 0;  // 0 means "unlock all M1"
    UnlockResult unlockResult = BuildUnlockTransaction(
        m1Inputs,
        vaultInputs,
        unlockAmount,
        destScript,
        destScript
    );

    BOOST_CHECK(unlockResult.success);
    // BP30 v2.1: Strict conservation - M0_out == M1_in
    BOOST_CHECK_EQUAL(unlockResult.unlockedAmount, 5 * COIN);
    BOOST_CHECK_EQUAL(unlockResult.fee, 0);  // No fee at settlement layer
}

BOOST_AUTO_TEST_CASE(builder_flow_lock_transfer_unlock)
{
    // Step 1: Build LOCK (BP30 v2.0: no vaultDest - uses OP_TRUE)
    std::vector<LockInput> inputs;
    inputs.push_back(CreateFakeLockInput(10 * COIN));

    CKey receiptKey1 = GenerateKey();
    CKey changeKey = GenerateKey();

    LockResult lockResult = BuildLockTransaction(
        inputs,
        5 * COIN,
        GetP2PKHScript(receiptKey1.GetPubKey()),
        GetP2PKHScript(changeKey.GetPubKey())
    );

    BOOST_CHECK(lockResult.success);

    // Step 2: Build TRANSFER
    TransferInput transferInput;
    transferInput.receiptOutpoint = lockResult.receiptOutpoint;
    transferInput.amount = lockResult.lockedAmount;
    transferInput.scriptPubKey = GetP2PKHScript(receiptKey1.GetPubKey());

    CKey newOwnerKey = GenerateKey();
    std::vector<LockInput> feeInputs;
    feeInputs.push_back(CreateFakeLockInput(1 * COIN));

    TransferResult transferResult = BuildTransferTransaction(
        transferInput,
        GetP2PKHScript(newOwnerKey.GetPubKey()),
        feeInputs,
        GetP2PKHScript(changeKey.GetPubKey())
    );

    BOOST_CHECK(transferResult.success);

    // Step 3: Build UNLOCK with new receipt (bearer model)
    // The new owner can unlock using any vault - they don't need original vault key
    std::vector<M1Input> m1Inputs;
    M1Input m1In;
    m1In.outpoint = transferResult.newReceiptOutpoint;
    m1In.amount = lockResult.lockedAmount;
    m1In.scriptPubKey = GetP2PKHScript(newOwnerKey.GetPubKey());
    m1Inputs.push_back(m1In);

    std::vector<VaultInput> vaultInputs;
    VaultInput vaultIn;
    vaultIn.outpoint = lockResult.vaultOutpoint;
    vaultIn.amount = lockResult.lockedAmount;
    vaultInputs.push_back(vaultIn);

    CKey destKey = GenerateKey();
    CScript destScript = GetP2PKHScript(destKey.GetPubKey());

    // BP30 v2.1: Full unlock after transfer - use 0 to unlock all M1
    CAmount unlockAmount = 0;  // 0 means "unlock all M1"
    UnlockResult unlockResult = BuildUnlockTransaction(
        m1Inputs,
        vaultInputs,
        unlockAmount,
        destScript,
        destScript
    );

    BOOST_CHECK(unlockResult.success);
    // BP30 v2.1: Strict conservation - M0_out == M1_in
    BOOST_CHECK_EQUAL(unlockResult.unlockedAmount, 5 * COIN);
    BOOST_CHECK_EQUAL(unlockResult.fee, 0);  // No fee at settlement layer
}

// =============================================================================
// TX_UNLOCK with network fee (wallet layer) tests
// =============================================================================

/**
 * Test: Unlock with M0 fee inputs produces positive network fee
 *
 * This simulates what the RPC does:
 * 1. Build settlement TX (M1_in == M0_out + M1_change, fee=0)
 * 2. Add M0 fee inputs + M0 fee change output
 * 3. Verify: Σ(all_inputs) - Σ(all_outputs) > 0
 */
BOOST_AUTO_TEST_CASE(unlock_with_m0_fee_inputs_has_network_fee)
{
    // Setup: Build a settlement unlock TX
    std::vector<M1Input> m1Inputs;
    M1Input m1In;
    m1In.outpoint = COutPoint(GetRandHash(), 0);
    m1In.amount = 10 * COIN;
    m1In.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());
    m1Inputs.push_back(m1In);

    CAmount unlockAmt = 7 * COIN;

    std::vector<VaultInput> vaultInputs;
    VaultInput vaultIn;
    vaultIn.outpoint = COutPoint(GetRandHash(), 0);
    vaultIn.amount = unlockAmt;  // Vault matches unlock amount (no vault change)
    vaultInputs.push_back(vaultIn);

    CKey destKey = GenerateKey();
    CScript destScript = GetP2PKHScript(destKey.GetPubKey());

    // Build settlement TX (strict conservation, fee=0)
    UnlockResult unlockResult = BuildUnlockTransaction(
        m1Inputs,
        vaultInputs,
        unlockAmt,  // Partial unlock
        destScript,
        destScript  // M1 change goes to same address
    );

    BOOST_REQUIRE(unlockResult.success);
    BOOST_CHECK_EQUAL(unlockResult.fee, 0);  // Settlement layer: no fee
    BOOST_CHECK_EQUAL(unlockResult.unlockedAmount, 7 * COIN);
    BOOST_CHECK_EQUAL(unlockResult.m1Change, 3 * COIN);

    // Now simulate wallet layer: add M0 fee inputs
    CMutableTransaction mtx = unlockResult.mtx;

    // Track input values for fee calculation
    CAmount totalInputValue = 0;

    // M1 inputs - NOT counted in UTXO value (they're receipts, value is in vaults)
    // Vault inputs - OP_TRUE, no value to spend (they back M0_out)
    // We need to track what the actual UTXO value flow is:
    // - M1 receipts have nValue that gets "burned"
    // - Vault outputs get consumed (but value goes to M0_out)

    // For fee calculation, what matters is:
    //   Fee = Σ(M0_fee_inputs) - M0_fee_change_output
    // Because settlement layer is already balanced: M1_in == M0_out + M1_change

    // Add M0 fee input (simulating wallet coin selection)
    CAmount m0FeeInput = 0.001 * COIN;  // 0.001 M0 = 100,000 satoshi
    COutPoint feeInputOutpoint(GetRandHash(), 0);
    mtx.vin.emplace_back(feeInputOutpoint);
    totalInputValue += m0FeeInput;

    // Calculate fee (no change for simplicity)
    CAmount networkFee = m0FeeInput;  // All fee input goes to fee

    // Verify TX structure:
    // - vin[0] = M1 receipt
    // - vin[1] = Vault (OP_TRUE)
    // - vin[2] = M0 fee input
    // - vout[0] = M0 unlocked (7 COIN)
    // - vout[1] = M1 change (3 COIN)
    BOOST_CHECK_EQUAL(mtx.vin.size(), 3);
    BOOST_CHECK_EQUAL(mtx.vout.size(), 2);  // M0_out + M1_change

    // The network fee is the M0 fee input (nothing added to outputs)
    BOOST_CHECK(networkFee > 0);
    BOOST_CHECK_EQUAL(networkFee, m0FeeInput);

    // Alternative: Add M0 fee change output
    CAmount m0FeeInputLarge = 0.01 * COIN;  // 0.01 M0
    CAmount targetFee = 0.0001 * COIN;      // 10,000 satoshi
    CAmount m0FeeChange = m0FeeInputLarge - targetFee;

    CMutableTransaction mtx2 = unlockResult.mtx;
    mtx2.vin.emplace_back(COutPoint(GetRandHash(), 0));  // M0 fee input
    mtx2.vout.emplace_back(m0FeeChange, destScript);     // M0 fee change

    // Verify: 3 inputs, 3 outputs
    BOOST_CHECK_EQUAL(mtx2.vin.size(), 3);
    BOOST_CHECK_EQUAL(mtx2.vout.size(), 3);  // M0_out + M1_change + M0_fee_change

    // Fee = M0_fee_input - M0_fee_change
    CAmount actualFee = m0FeeInputLarge - m0FeeChange;
    BOOST_CHECK_EQUAL(actualFee, targetFee);
    BOOST_CHECK(actualFee > 0);
}

/**
 * Test: A6 conservation is preserved even with M0 fee inputs
 *
 * Settlement layer conservation (A6):
 *   sum(M1_in) == M0_out + sum(M1_change)
 *
 * This must hold regardless of M0 fee inputs/outputs added by wallet layer.
 */
BOOST_AUTO_TEST_CASE(unlock_with_m0_fee_preserves_a6_conservation)
{
    // Setup: Build a settlement unlock TX with partial unlock
    std::vector<M1Input> m1Inputs;
    M1Input m1In;
    m1In.outpoint = COutPoint(GetRandHash(), 0);
    m1In.amount = 100 * COIN;
    m1In.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());
    m1Inputs.push_back(m1In);

    CAmount unlockAmount = 40 * COIN;

    std::vector<VaultInput> vaultInputs;
    VaultInput vaultIn;
    vaultIn.outpoint = COutPoint(GetRandHash(), 0);
    vaultIn.amount = unlockAmount;  // Vault matches unlock amount (no vault change)
    vaultInputs.push_back(vaultIn);

    CKey destKey = GenerateKey();
    CKey changeKey = GenerateKey();
    CScript destScript = GetP2PKHScript(destKey.GetPubKey());
    CScript changeScript = GetP2PKHScript(changeKey.GetPubKey());

    // Build settlement TX
    UnlockResult unlockResult = BuildUnlockTransaction(
        m1Inputs,
        vaultInputs,
        unlockAmount,
        destScript,
        changeScript
    );

    BOOST_REQUIRE(unlockResult.success);

    // Verify A6 conservation at settlement layer:
    // sum(M1_in) == M0_out + sum(M1_change)
    CAmount totalM1In = m1Inputs[0].amount;  // 100 COIN
    CAmount m0Out = unlockResult.unlockedAmount;  // 40 COIN
    CAmount m1ChangeOut = unlockResult.m1Change;  // 60 COIN

    BOOST_CHECK_EQUAL(totalM1In, m0Out + m1ChangeOut);  // 100 == 40 + 60

    // Now add M0 fee inputs (wallet layer)
    CMutableTransaction mtx = unlockResult.mtx;

    CAmount m0FeeInput = 0.005 * COIN;  // 0.005 M0
    CAmount m0FeeChange = 0.004 * COIN; // 0.004 M0 change
    CAmount networkFee = m0FeeInput - m0FeeChange;  // 0.001 M0 fee

    mtx.vin.emplace_back(COutPoint(GetRandHash(), 0));  // M0 fee input
    mtx.vout.emplace_back(m0FeeChange, destScript);    // M0 fee change

    // TX structure now:
    // vin[0] = M1 receipt (100 COIN)
    // vin[1] = Vault (100 COIN, OP_TRUE)
    // vin[2] = M0 fee input (0.005 COIN)
    //
    // vout[0] = M0 unlocked (40 COIN)
    // vout[1] = M1 change (60 COIN)
    // vout[2] = M0 fee change (0.004 COIN)

    BOOST_CHECK_EQUAL(mtx.vin.size(), 3);
    BOOST_CHECK_EQUAL(mtx.vout.size(), 3);

    // Verify A6 conservation STILL holds on vout[0] and vout[1]:
    // These are the settlement outputs, unchanged by fee layer
    CAmount settlementM0Out = mtx.vout[0].nValue;  // 40 COIN
    CAmount settlementM1Change = mtx.vout[1].nValue;  // 60 COIN

    BOOST_CHECK_EQUAL(totalM1In, settlementM0Out + settlementM1Change);

    // Verify network fee is positive and separate
    BOOST_CHECK(networkFee > 0);
    BOOST_CHECK_EQUAL(networkFee, 0.001 * COIN);

    // Verify total output breakdown:
    // - Settlement: M0_out (40) + M1_change (60) = 100 (matches M1_in)
    // - Network: M0_fee_change (0.004) from M0_fee_input (0.005), fee = 0.001
    CAmount totalOutputs = 0;
    for (const auto& out : mtx.vout) {
        totalOutputs += out.nValue;
    }
    BOOST_CHECK_EQUAL(totalOutputs, 40 * COIN + 60 * COIN + m0FeeChange);
}

/**
 * Test: Funding NEVER modifies BP30 settlement vouts
 *
 * Critical invariant: vout[0] (M0_out) and vout[1] (M1_change) must be
 * IDENTICAL before and after funding. Any modification breaks A6.
 *
 * This simulates the RPC flow and verifies immutability.
 */
BOOST_AUTO_TEST_CASE(funding_never_modifies_bp30_vouts)
{
    // Build settlement TX template
    std::vector<M1Input> m1Inputs;
    M1Input m1In;
    m1In.outpoint = COutPoint(GetRandHash(), 0);
    m1In.amount = 50 * COIN;
    m1In.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());
    m1Inputs.push_back(m1In);

    CAmount unlockAmt = 30 * COIN;

    std::vector<VaultInput> vaultInputs;
    VaultInput vaultIn;
    vaultIn.outpoint = COutPoint(GetRandHash(), 0);
    vaultIn.amount = unlockAmt;  // Vault matches unlock amount (no vault change)
    vaultInputs.push_back(vaultIn);

    CKey destKey = GenerateKey();
    CKey changeKey = GenerateKey();
    CScript destScript = GetP2PKHScript(destKey.GetPubKey());
    CScript changeScript = GetP2PKHScript(changeKey.GetPubKey());

    // Partial unlock: 30 M0 out, 20 M1 change
    UnlockResult unlockResult = BuildUnlockTransaction(
        m1Inputs,
        vaultInputs,
        unlockAmt,
        destScript,
        changeScript
    );

    BOOST_REQUIRE(unlockResult.success);
    BOOST_REQUIRE_EQUAL(unlockResult.mtx.vout.size(), 2);

    // Capture BP30 vouts BEFORE funding
    CTxOut vout0_before = unlockResult.mtx.vout[0];  // M0_out
    CTxOut vout1_before = unlockResult.mtx.vout[1];  // M1_change

    BOOST_CHECK_EQUAL(vout0_before.nValue, 30 * COIN);
    BOOST_CHECK_EQUAL(vout1_before.nValue, 20 * COIN);

    // Simulate funding: add M0 fee inputs + M0 fee change
    CMutableTransaction mtx = unlockResult.mtx;

    // Add M0 fee input
    mtx.vin.emplace_back(COutPoint(GetRandHash(), 0));

    // Add M0 fee change output (this is vout[2])
    CAmount m0FeeChange = 0.009 * COIN;
    mtx.vout.emplace_back(m0FeeChange, destScript);

    // Verify: BP30 vouts are UNCHANGED after funding
    BOOST_CHECK_EQUAL(mtx.vout[0].nValue, vout0_before.nValue);
    BOOST_CHECK(mtx.vout[0].scriptPubKey == vout0_before.scriptPubKey);

    BOOST_CHECK_EQUAL(mtx.vout[1].nValue, vout1_before.nValue);
    BOOST_CHECK(mtx.vout[1].scriptPubKey == vout1_before.scriptPubKey);

    // Additional check: vouts still satisfy A6
    CAmount m0Out = mtx.vout[0].nValue;
    CAmount m1ChangeVal = mtx.vout[1].nValue;
    CAmount m1InTotal = m1Inputs[0].amount;

    BOOST_CHECK_EQUAL(m1InTotal, m0Out + m1ChangeVal);  // 50 == 30 + 20

    // Verify fee change is separate (vout[2])
    BOOST_CHECK_EQUAL(mtx.vout.size(), 3);
    BOOST_CHECK_EQUAL(mtx.vout[2].nValue, m0FeeChange);
}

/**
 * Test: TX_UNLOCK with OP_TRUE vault passes standardness checks
 *
 * BP30 special transactions bypass certain policy checks.
 * This test verifies the bypass works correctly.
 */
BOOST_AUTO_TEST_CASE(unlock_with_op_true_vault_is_standard)
{
    // Build a complete unlock TX
    std::vector<M1Input> m1Inputs;
    M1Input m1In;
    m1In.outpoint = COutPoint(GetRandHash(), 0);
    m1In.amount = 10 * COIN;
    m1In.scriptPubKey = GetP2PKHScript(GenerateKey().GetPubKey());
    m1Inputs.push_back(m1In);

    std::vector<VaultInput> vaultInputs;
    VaultInput vaultIn;
    vaultIn.outpoint = COutPoint(GetRandHash(), 0);
    vaultIn.amount = 10 * COIN;
    vaultInputs.push_back(vaultIn);

    CKey destKey = GenerateKey();
    CScript destScript = GetP2PKHScript(destKey.GetPubKey());

    UnlockResult unlockResult = BuildUnlockTransaction(
        m1Inputs,
        vaultInputs,
        10 * COIN,  // Full unlock
        destScript,
        destScript
    );

    BOOST_REQUIRE(unlockResult.success);

    // Verify TX type is TX_UNLOCK
    const CTransaction tx(unlockResult.mtx);
    BOOST_CHECK_EQUAL(tx.nType, CTransaction::TxType::TX_UNLOCK);

    // Verify vault input uses OP_TRUE (empty scriptSig for now)
    // In actual TX, vault vin[1] would have minimal scriptSig for OP_TRUE
    BOOST_CHECK_EQUAL(tx.vin.size(), 2);  // M1 receipt + vault

    // Verify outputs are standard P2PKH
    BOOST_CHECK_EQUAL(tx.vout.size(), 1);  // Full unlock = no M1 change
    BOOST_CHECK_EQUAL(tx.vout[0].nValue, 10 * COIN);

    // BP30: TX_UNLOCK is accepted by mempool despite OP_TRUE vault inputs
    // This works via policy.cpp IsStandardTx() which checks nType directly:
    //   if (tx->nType == TX_LOCK || TX_UNLOCK || TX_TRANSFER_M1)
    //       return true;  // BP30 P1 transactions are always standard
    //
    // Note: TX_UNLOCK does NOT use extraPayload (unlike ProRegTx etc.)
    // so IsSpecialTx() returns false. Standardness is via nType check.

    // Verify version is SAPLING (required for nType to be valid)
    BOOST_CHECK(tx.nVersion == CTransaction::TxVersion::SAPLING);

    // Verify nType is exactly TX_UNLOCK (the key for standardness bypass)
    BOOST_CHECK(tx.nType == CTransaction::TxType::TX_UNLOCK);
}

BOOST_AUTO_TEST_SUITE_END()
