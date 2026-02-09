// Copyright (c) 2025 The PIVHU Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef PIVHU_HU_QUORUM_H
#define PIVHU_HU_QUORUM_H

#include "masternode/deterministicmns.h"
#include "state/finality.h"
#include "uint256.h"

#include <vector>

class CBlockIndex;

namespace hu {

/**
 * HU Quorum System - OPERATOR-BASED Finality
 *
 * DESIGN PRINCIPLE:
 * - DMM (Production): ALL MNs participate, scored by proTxHash
 * - FINALITY (Signatures): OPERATORS vote, one vote per operator
 *
 * This ensures:
 * - Maximum availability for block production (all MNs compete)
 * - Economic decentralization for finality (operators, not MNs)
 *
 * QUORUM SELECTION:
 * 1. Calculate DMM producer for block N (deterministic)
 * 2. Select quorum OPERATORS, EXCLUDING producer's operator
 * 3. Each operator in quorum can sign once
 * 4. Threshold: 2/3 of quorum operators
 *
 * This prevents the chicken-and-egg problem where producer is in quorum.
 */

/**
 * Get the cycle index for a given block height
 * @param nHeight Block height
 * @param nCycleLength From consensus.nHuQuorumRotationBlocks (default: 12)
 * @return Cycle index (nHeight / nCycleLength)
 */
inline int GetHuCycleIndex(int nHeight, int nCycleLength = HU_CYCLE_LENGTH_DEFAULT)
{
    return nHeight / nCycleLength;
}

/**
 * Get the first block height of a cycle
 * @param cycleIndex Cycle index
 * @param nCycleLength From consensus.nHuQuorumRotationBlocks (default: 12)
 * @return First block height in the cycle
 */
inline int GetHuCycleStartHeight(int cycleIndex, int nCycleLength = HU_CYCLE_LENGTH_DEFAULT)
{
    return cycleIndex * nCycleLength;
}

/**
 * Compute the seed for quorum selection
 * @param seedBlockHash Hash to use for seed (should be lastFinalizedBlockHash per blueprint)
 * @param cycleIndex Current cycle index
 * @return Deterministic seed for MN selection
 *
 * Note: Per BLUEPRINT requirement, the caller should pass lastFinalizedBlockHash
 * for BFT security.
 */
uint256 ComputeHuQuorumSeed(const uint256& seedBlockHash, int cycleIndex);

/**
 * Select the HU quorum for a given cycle
 *
 * @param mnList Deterministic MN list at the cycle start
 * @param cycleIndex Cycle index
 * @param prevCycleBlockHash Hash of last block in previous cycle
 * @return Vector of HU_QUORUM_SIZE MNs (or fewer if not enough valid MNs)
 */
std::vector<CDeterministicMNCPtr> GetHuQuorum(
    const CDeterministicMNList& mnList,
    int cycleIndex,
    const uint256& prevCycleBlockHash);

/**
 * Check if a masternode is in the HU quorum for a given cycle
 *
 * @param mnList Deterministic MN list
 * @param cycleIndex Cycle index
 * @param prevCycleBlockHash Hash of last block in previous cycle
 * @param proTxHash ProRegTx hash of the MN to check
 * @return true if MN is in the quorum
 */
bool IsInHuQuorum(
    const CDeterministicMNList& mnList,
    int cycleIndex,
    const uint256& prevCycleBlockHash,
    const uint256& proTxHash);

/**
 * Compute MN score for quorum selection (used internally)
 * @param seed Quorum seed
 * @param proTxHash MN's proTxHash
 * @return Score for sorting
 */
uint256 ComputeHuQuorumMemberScore(const uint256& seed, const uint256& proTxHash);

// ═══════════════════════════════════════════════════════════════════════════════
// OPERATOR-BASED QUORUM (v3.0)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Get unique operators from MN list
 * @param mnList Deterministic MN list
 * @return Map of operator pubkey -> one representative MN (for signing)
 */
std::map<CPubKey, CDeterministicMNCPtr> GetUniqueOperators(const CDeterministicMNList& mnList);

/**
 * Select the HU quorum of OPERATORS (not MNs) for a given block
 *
 * @param mnList Deterministic MN list
 * @param cycleIndex Cycle index
 * @param prevCycleBlockHash Hash of last block in previous cycle
 * @param excludeOperator Operator pubkey to EXCLUDE (block producer's operator)
 * @return Vector of operator pubkeys in the quorum
 */
std::vector<CPubKey> GetHuQuorumOperators(
    const CDeterministicMNList& mnList,
    int cycleIndex,
    const uint256& prevCycleBlockHash,
    const CPubKey& excludeOperator = CPubKey());

/**
 * Check if an operator is in the HU quorum for a given block
 *
 * @param mnList Deterministic MN list
 * @param cycleIndex Cycle index
 * @param prevCycleBlockHash Hash of last block in previous cycle
 * @param operatorPubKey Operator pubkey to check
 * @param excludeOperator Operator to exclude (producer)
 * @return true if operator is in the quorum
 */
bool IsOperatorInHuQuorum(
    const CDeterministicMNList& mnList,
    int cycleIndex,
    const uint256& prevCycleBlockHash,
    const CPubKey& operatorPubKey,
    const CPubKey& excludeOperator = CPubKey());

/**
 * Compute operator score for quorum selection
 * @param seed Quorum seed
 * @param operatorPubKey Operator's public key
 * @return Score for sorting
 */
uint256 ComputeOperatorScore(const uint256& seed, const CPubKey& operatorPubKey);

} // namespace hu

#endif // PIVHU_HU_QUORUM_H
