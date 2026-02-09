// Copyright (c) 2025 The PIVHU Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "state/quorum.h"

#include "arith_uint256.h"
#include "chain.h"
#include "chainparams.h"
#include "hash.h"
#include "logging.h"
#include "utilstrencodings.h"

#include <algorithm>
#include <map>

namespace hu {

uint256 ComputeHuQuorumSeed(const uint256& prevCycleBlockHash, int cycleIndex)
{
    // seed = SHA256(prevCycleBlockHash || cycleIndex || "HU_QUORUM")
    CHashWriter ss(SER_GETHASH, PROTOCOL_VERSION);
    ss << prevCycleBlockHash;
    ss << cycleIndex;
    ss << std::string("HU_QUORUM");
    return ss.GetHash();
}

uint256 ComputeHuQuorumMemberScore(const uint256& seed, const uint256& proTxHash)
{
    // score = SHA256(seed || proTxHash)
    CHashWriter ss(SER_GETHASH, PROTOCOL_VERSION);
    ss << seed;
    ss << proTxHash;
    return ss.GetHash();
}

std::vector<CDeterministicMNCPtr> GetHuQuorum(
    const CDeterministicMNList& mnList,
    int cycleIndex,
    const uint256& prevCycleBlockHash)
{
    std::vector<CDeterministicMNCPtr> result;

    // Compute seed for this cycle
    uint256 seed = ComputeHuQuorumSeed(prevCycleBlockHash, cycleIndex);

    // Collect all valid, confirmed MNs with their scores
    // Using arith_uint256 for comparison operators
    std::vector<std::pair<arith_uint256, CDeterministicMNCPtr>> scoredMns;

    mnList.ForEachMN(true /* onlyValid */, [&](const CDeterministicMNCPtr& dmn) {
        // Skip unconfirmed MNs
        if (dmn->pdmnState->confirmedHash.IsNull()) {
            return;
        }

        uint256 scoreHash = ComputeHuQuorumMemberScore(seed, dmn->proTxHash);
        arith_uint256 score = UintToArith256(scoreHash);
        scoredMns.emplace_back(score, dmn);
    });

    if (scoredMns.empty()) {
        LogPrint(BCLog::STATE, "HU Quorum: No valid MNs for cycle %d\n", cycleIndex);
        return result;
    }

    // Sort by score (descending)
    std::sort(scoredMns.begin(), scoredMns.end(),
        [](const auto& a, const auto& b) {
            if (a.first == b.first) {
                // Tie-breaker: proTxHash lexicographically
                return a.second->proTxHash < b.second->proTxHash;
            }
            return a.first > b.first;
        });

    // Take top nHuQuorumSize MNs (from consensus params)
    const Consensus::Params& consensus = Params().GetConsensus();
    size_t quorumSize = std::min(static_cast<size_t>(consensus.nHuQuorumSize), scoredMns.size());
    result.reserve(quorumSize);

    for (size_t i = 0; i < quorumSize; i++) {
        result.push_back(scoredMns[i].second);
    }

    // Log selected quorum with proTxHashes for debugging
    std::string quorumList;
    for (const auto& mn : result) {
        if (!quorumList.empty()) quorumList += ", ";
        quorumList += mn->proTxHash.ToString().substr(0, 12);
    }
    LogPrint(BCLog::STATE, "HU Quorum: Selected %zu MNs for cycle %d (seed: %s): [%s]\n",
             result.size(), cycleIndex, seed.ToString().substr(0, 16), quorumList);

    return result;
}

bool IsInHuQuorum(
    const CDeterministicMNList& mnList,
    int cycleIndex,
    const uint256& prevCycleBlockHash,
    const uint256& proTxHash)
{
    auto quorum = GetHuQuorum(mnList, cycleIndex, prevCycleBlockHash);

    for (const auto& mn : quorum) {
        if (mn->proTxHash == proTxHash) {
            return true;
        }
    }

    return false;
}

// ═══════════════════════════════════════════════════════════════════════════════
// OPERATOR-BASED QUORUM (v3.0)
// ═══════════════════════════════════════════════════════════════════════════════

std::map<CPubKey, CDeterministicMNCPtr> GetUniqueOperators(const CDeterministicMNList& mnList)
{
    std::map<CPubKey, CDeterministicMNCPtr> operators;

    mnList.ForEachMN(true /* onlyValid */, [&](const CDeterministicMNCPtr& dmn) {
        // Skip unconfirmed MNs
        if (dmn->pdmnState->confirmedHash.IsNull()) {
            return;
        }

        const CPubKey& opKey = dmn->pdmnState->pubKeyOperator;
        // Keep first MN per operator (for signing purposes)
        if (operators.find(opKey) == operators.end()) {
            operators[opKey] = dmn;
        }
    });

    return operators;
}

uint256 ComputeOperatorScore(const uint256& seed, const CPubKey& operatorPubKey)
{
    // score = SHA256(seed || operatorPubKey)
    CHashWriter ss(SER_GETHASH, PROTOCOL_VERSION);
    ss << seed;
    ss << operatorPubKey;
    return ss.GetHash();
}

std::vector<CPubKey> GetHuQuorumOperators(
    const CDeterministicMNList& mnList,
    int cycleIndex,
    const uint256& prevCycleBlockHash,
    const CPubKey& excludeOperator)
{
    std::vector<CPubKey> result;

    // Compute seed for this cycle
    uint256 seed = ComputeHuQuorumSeed(prevCycleBlockHash, cycleIndex);

    // Get all unique operators
    auto operators = GetUniqueOperators(mnList);

    if (operators.empty()) {
        LogPrint(BCLog::STATE, "HU Quorum: No valid operators for cycle %d\n", cycleIndex);
        return result;
    }

    // Score each operator (excluding producer's operator)
    std::vector<std::pair<arith_uint256, CPubKey>> scoredOperators;

    for (const auto& entry : operators) {
        const CPubKey& opKey = entry.first;
        // Exclude block producer's operator
        if (excludeOperator.IsValid() && opKey == excludeOperator) {
            LogPrint(BCLog::STATE, "HU Quorum: Excluding producer operator %s from quorum\n",
                     HexStr(opKey).substr(0, 16));
            continue;
        }

        uint256 scoreHash = ComputeOperatorScore(seed, opKey);
        arith_uint256 score = UintToArith256(scoreHash);
        scoredOperators.emplace_back(score, opKey);
    }

    if (scoredOperators.empty()) {
        LogPrint(BCLog::STATE, "HU Quorum: No operators left after exclusion for cycle %d\n", cycleIndex);
        return result;
    }

    // Sort by score (descending)
    std::sort(scoredOperators.begin(), scoredOperators.end(),
        [](const auto& a, const auto& b) {
            if (a.first == b.first) {
                // Tie-breaker: operator pubkey lexicographically
                return a.second < b.second;
            }
            return a.first > b.first;
        });

    // Take top nHuQuorumSize operators
    const Consensus::Params& consensus = Params().GetConsensus();
    size_t quorumSize = std::min(static_cast<size_t>(consensus.nHuQuorumSize), scoredOperators.size());
    result.reserve(quorumSize);

    for (size_t i = 0; i < quorumSize; i++) {
        result.push_back(scoredOperators[i].second);
    }

    // Log selected quorum
    std::string quorumList;
    for (const auto& opKey : result) {
        if (!quorumList.empty()) quorumList += ", ";
        quorumList += HexStr(opKey).substr(0, 12);
    }
    LogPrint(BCLog::STATE, "HU Quorum: Selected %zu OPERATORS for cycle %d (seed: %s): [%s]\n",
             result.size(), cycleIndex, seed.ToString().substr(0, 16), quorumList);

    return result;
}

bool IsOperatorInHuQuorum(
    const CDeterministicMNList& mnList,
    int cycleIndex,
    const uint256& prevCycleBlockHash,
    const CPubKey& operatorPubKey,
    const CPubKey& excludeOperator)
{
    auto quorum = GetHuQuorumOperators(mnList, cycleIndex, prevCycleBlockHash, excludeOperator);

    for (const auto& opKey : quorum) {
        if (opKey == operatorPubKey) {
            return true;
        }
    }

    return false;
}

} // namespace hu
