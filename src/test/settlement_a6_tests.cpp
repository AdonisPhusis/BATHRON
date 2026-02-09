// Copyright (c) 2025-2026 The BATHRON Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

/**
 * A6 Invariant Unit Tests
 *
 * Ref: doc/blueprints/done/BP30-SETTLEMENT.md
 *
 * A6 Invariant: M0_vaulted == M1_supply
 *
 * Tests:
 *   1. add_no_overflow_basic - AddNoOverflow detects overflow
 *   2. a6_valid_state - CheckA6P1 validates A6
 *   3. a6_after_lock - A6 holds after LOCK
 *   4. a6_after_unlock - A6 holds after UNLOCK
 */

#include "state/settlement.h"
#include "state/settlementdb.h"
#include "state/settlement_logic.h"
#include "amount.h"
#include "consensus/validation.h"
#include "test/test_bathron.h"

#include <boost/test/unit_test.hpp>
#include <limits>

BOOST_FIXTURE_TEST_SUITE(settlement_a6_tests, BasicTestingSetup)

// =============================================================================
// Test 1: AddNoOverflow - Overflow detection with __int128
// =============================================================================
BOOST_AUTO_TEST_CASE(add_no_overflow_basic)
{
    CAmount result = 0;

    // Normal addition
    BOOST_CHECK(AddNoOverflow(100 * COIN, 200 * COIN, result));
    BOOST_CHECK_EQUAL(result, 300 * COIN);

    // Zero addition
    BOOST_CHECK(AddNoOverflow(0, 0, result));
    BOOST_CHECK_EQUAL(result, 0);

    // Max safe sum
    CAmount half_max = std::numeric_limits<int64_t>::max() / 2;
    BOOST_CHECK(AddNoOverflow(half_max, half_max, result));
    BOOST_CHECK_EQUAL(result, half_max * 2);
}

BOOST_AUTO_TEST_CASE(add_no_overflow_overflow_detection)
{
    CAmount result = 0;

    // Overflow: INT64_MAX + 1
    CAmount max_val = std::numeric_limits<int64_t>::max();
    BOOST_CHECK(!AddNoOverflow(max_val, 1, result));

    // Overflow: INT64_MAX + INT64_MAX
    BOOST_CHECK(!AddNoOverflow(max_val, max_val, result));

    // Large but not overflowing
    CAmount safe_large = max_val / 2;
    BOOST_CHECK(AddNoOverflow(safe_large, safe_large, result));
}

BOOST_AUTO_TEST_CASE(add_no_overflow_negative)
{
    CAmount result = 0;

    // Negative underflow: INT64_MIN + negative
    CAmount min_val = std::numeric_limits<int64_t>::min();
    BOOST_CHECK(!AddNoOverflow(min_val, -1, result));

    // Normal negative addition
    BOOST_CHECK(AddNoOverflow(-100 * COIN, -200 * COIN, result));
    BOOST_CHECK_EQUAL(result, -300 * COIN);

    // Mixed positive/negative
    BOOST_CHECK(AddNoOverflow(100 * COIN, -50 * COIN, result));
    BOOST_CHECK_EQUAL(result, 50 * COIN);
}

// =============================================================================
// Test 2: CheckA6P1 - Basic A6 invariant validation
// =============================================================================
BOOST_AUTO_TEST_CASE(a6_valid_state)
{
    // A6: M0_vaulted == M1_supply
    SettlementState state;
    state.M0_vaulted = 1000 * COIN;
    state.M1_supply = 1000 * COIN;

    CValidationState validationState;
    BOOST_CHECK(CheckA6P1(state, validationState));
    BOOST_CHECK(validationState.IsValid());
}

BOOST_AUTO_TEST_CASE(a6_broken_detection)
{
    // M0_vaulted != M1_supply
    SettlementState state;
    state.M0_vaulted = 1000 * COIN;
    state.M1_supply = 900 * COIN;  // 900 != 1000

    CValidationState validationState;
    BOOST_CHECK(!CheckA6P1(state, validationState));
    BOOST_CHECK(validationState.GetRejectReason().find("settlement-a6-broken") != std::string::npos);
}

// =============================================================================
// Test 3: A6 after LOCK operation
// =============================================================================
BOOST_AUTO_TEST_CASE(a6_after_lock)
{
    // Simulate LOCK: M0_vaulted += P, M1_supply += P
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;

    // Initial state: A6 should hold (0 == 0)
    CValidationState validationState;
    BOOST_CHECK(CheckA6P1(state, validationState));

    // Apply LOCK (P = 500 COIN)
    CAmount P = 500 * COIN;
    state.M0_vaulted += P;
    state.M1_supply += P;

    // After LOCK: A6 should still hold (500 == 500)
    CValidationState postLockState;
    BOOST_CHECK(CheckA6P1(state, postLockState));
}

// =============================================================================
// Test 4: A6 after UNLOCK operation
// =============================================================================
BOOST_AUTO_TEST_CASE(a6_after_unlock)
{
    // Start with locked state
    SettlementState state;
    state.M0_vaulted = 1000 * COIN;
    state.M1_supply = 1000 * COIN;

    // Initial: A6 holds (1000 == 1000)
    CValidationState validationState;
    BOOST_CHECK(CheckA6P1(state, validationState));

    // Apply UNLOCK (burn 500 M1, release 500 M0)
    CAmount U = 500 * COIN;
    state.M0_vaulted -= U;
    state.M1_supply -= U;

    // After UNLOCK: A6 should still hold (500 == 500)
    CValidationState postUnlockState;
    BOOST_CHECK(CheckA6P1(state, postUnlockState));
}

// =============================================================================
// Test 5: A6 reorg scenario (undo then redo)
// =============================================================================
BOOST_AUTO_TEST_CASE(a6_reorg_cycle)
{
    // Initial state
    SettlementState state;
    state.M0_vaulted = 500 * COIN;
    state.M1_supply = 500 * COIN;

    // Save snapshot for "undo"
    SettlementState snapshot = state;

    // Apply LOCK (P = 200)
    CAmount P = 200 * COIN;
    state.M0_vaulted += P;
    state.M1_supply += P;

    CValidationState afterLock;
    BOOST_CHECK(CheckA6P1(state, afterLock));
    BOOST_CHECK_EQUAL(state.M0_vaulted, 700 * COIN);

    // Simulate reorg: UNDO the LOCK
    state = snapshot;

    CValidationState afterUndo;
    BOOST_CHECK(CheckA6P1(state, afterUndo));
    BOOST_CHECK_EQUAL(state.M0_vaulted, 500 * COIN);

    // Re-apply LOCK
    state.M0_vaulted += P;
    state.M1_supply += P;

    CValidationState afterRedo;
    BOOST_CHECK(CheckA6P1(state, afterRedo));
    BOOST_CHECK_EQUAL(state.M0_vaulted, 700 * COIN);
}

// =============================================================================
// Test 6: Edge case - all zeros
// =============================================================================
BOOST_AUTO_TEST_CASE(a6_all_zeros)
{
    // Edge case: all zeros
    SettlementState state;
    state.M0_vaulted = 0;
    state.M1_supply = 0;

    // A6: 0 == 0
    CValidationState validationState;
    BOOST_CHECK(CheckA6P1(state, validationState));
}

// =============================================================================
// Test 7: Large values (near MAX_MONEY)
// =============================================================================
BOOST_AUTO_TEST_CASE(a6_large_values)
{
    // MAX_MONEY = 21M * COIN = 2.1e15 satoshi
    // Test with values near MAX_MONEY

    SettlementState state;
    state.M0_vaulted = 20000000 * COIN;  // 20M
    state.M1_supply = 20000000 * COIN;   // 20M

    // A6: 20M == 20M
    CValidationState validationState;
    BOOST_CHECK(CheckA6P1(state, validationState));
}

BOOST_AUTO_TEST_SUITE_END()
