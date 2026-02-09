// Copyright (c) 2025 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BATHRON_EVO_MNMATURITY_H
#define BATHRON_EVO_MNMATURITY_H

/**
 * Masternode Vote Maturity System
 * ===============================
 *
 * Prevents "pump & vote" attacks where someone creates a MN just before a vote.
 * MNs must have collateral aged beyond nMasternodeVoteMaturityBlocks to:
 * - Submit DAO_GRANT proposals
 * - Vote on DAO_GRANT proposals
 *
 * Maturity values per network:
 * - Mainnet: 43200 blocks (~30 days)
 * - Testnet: 1440 blocks (~1 day)
 * - Regtest: 10 blocks (~10 minutes)
 *
 * Identity model:
 * Maturity is tied to the COLLATERAL ADDRESS, not proTxHash.
 * This preserves maturity when a MN re-registers (new ProRegTx) with the same collateral.
 */

#include "masternode/deterministicmns.h"
#include "script/standard.h"
#include "validation.h"
#include "chainparams.h"
#include "chain.h"

/**
 * Get the collateral address for a masternode by proTxHash
 * @param proTxHash The ProRegTx hash identifying the MN
 * @return The collateral address (CTxDestination), or CNoDestination if not found
 */
inline CTxDestination GetMasternodeCollateralAddress(const uint256& proTxHash)
{
    auto mnList = deterministicMNManager->GetListAtChainTip();
    auto dmn = mnList.GetMN(proTxHash);
    if (!dmn) {
        return CNoDestination();
    }

    // Get the collateral output script
    COutPoint collateralOutpoint = dmn->collateralOutpoint;

    // Need to find the actual scriptPubKey from the collateral TX
    CTransactionRef collateralTx;
    uint256 blockHash;
    if (!GetTransaction(collateralOutpoint.hash, collateralTx, blockHash, true)) {
        return CNoDestination();
    }

    if (collateralOutpoint.n >= collateralTx->vout.size()) {
        return CNoDestination();
    }

    CTxDestination dest;
    if (!ExtractDestination(collateralTx->vout[collateralOutpoint.n].scriptPubKey, dest)) {
        return CNoDestination();
    }

    return dest;
}

/**
 * Find the block height when a collateral address first had a valid MN collateral
 * This scans for the earliest collateral TX associated with this address across all MNs
 *
 * @param collateralAddress The collateral address to check
 * @return Block height of first collateral, or -1 if not found
 */
inline int FindFirstCollateralHeight(const CTxDestination& collateralAddress)
{
    if (boost::get<CNoDestination>(&collateralAddress)) {
        return -1;
    }

    auto mnList = deterministicMNManager->GetListAtChainTip();
    int earliestHeight = -1;

    mnList.ForEachMN(false, [&](const CDeterministicMNCPtr& dmn) {
        // Get collateral TX destination
        CTransactionRef collateralTx;
        uint256 blockHash;
        if (!GetTransaction(dmn->collateralOutpoint.hash, collateralTx, blockHash, true)) {
            return;
        }

        if (dmn->collateralOutpoint.n >= collateralTx->vout.size()) {
            return;
        }

        CTxDestination dest;
        if (!ExtractDestination(collateralTx->vout[dmn->collateralOutpoint.n].scriptPubKey, dest)) {
            return;
        }

        // Check if this collateral belongs to the same address
        if (dest == collateralAddress) {
            // Find the block height of this collateral TX
            CBlockIndex* pindex = LookupBlockIndex(blockHash);
            if (pindex && (earliestHeight < 0 || pindex->nHeight < earliestHeight)) {
                earliestHeight = pindex->nHeight;
            }
        }
    });

    return earliestHeight;
}

/**
 * Check if a masternode is eligible for voting (DAO_GRANT)
 * Based on the age of the collateral ADDRESS, preserves maturity if MN re-registers
 *
 * @param collateralAddress The collateral address to check
 * @param currentHeight Current blockchain height
 * @return true if the collateral has the required maturity
 */
inline bool IsMasternodeEligibleForVote(const CTxDestination& collateralAddress, int currentHeight)
{
    if (boost::get<CNoDestination>(&collateralAddress)) {
        return false;
    }

    int collateralHeight = FindFirstCollateralHeight(collateralAddress);
    if (collateralHeight < 0) {
        return false;  // No collateral found for this address
    }

    int maturityBlocks = currentHeight - collateralHeight;
    int requiredMaturity = Params().GetConsensus().MasternodeVoteMaturityBlocks();

    return maturityBlocks > requiredMaturity;
}

/**
 * Convenience overload: Check eligibility by proTxHash
 * Converts proTxHash to collateral address, then checks maturity
 *
 * @param proTxHash The ProRegTx hash identifying the MN
 * @param currentHeight Current blockchain height
 * @return true if the MN's collateral has the required maturity
 */
inline bool IsMasternodeEligibleForVote(const uint256& proTxHash, int currentHeight)
{
    CTxDestination collateralAddr = GetMasternodeCollateralAddress(proTxHash);
    return IsMasternodeEligibleForVote(collateralAddr, currentHeight);
}

/**
 * Get the number of mature MNs (eligible for voting)
 * Useful for calculating quorum requirements in DAO_GRANT votes
 *
 * @param currentHeight Current blockchain height
 * @return Number of MNs with sufficient collateral maturity
 */
inline size_t GetMatureMasternodeCount(int currentHeight)
{
    auto mnList = deterministicMNManager->GetListAtChainTip();
    size_t count = 0;

    mnList.ForEachMN(true, [&](const CDeterministicMNCPtr& dmn) {
        if (IsMasternodeEligibleForVote(dmn->proTxHash, currentHeight)) {
            count++;
        }
    });

    return count;
}

/**
 * Get maturity info for a specific masternode (for RPC/debugging)
 *
 * @param proTxHash The ProRegTx hash identifying the MN
 * @param currentHeight Current blockchain height
 * @return Struct with maturity details
 */
struct MasternodeMaturityInfo {
    bool exists;
    CTxDestination collateralAddress;
    int collateralHeight;
    int currentHeight;
    int maturityBlocks;
    int requiredMaturity;
    bool eligible;
    int blocksUntilEligible;  // 0 if already eligible
};

inline MasternodeMaturityInfo GetMasternodeMaturityInfo(const uint256& proTxHash, int currentHeight)
{
    MasternodeMaturityInfo info;
    info.exists = false;
    info.currentHeight = currentHeight;
    info.requiredMaturity = Params().GetConsensus().MasternodeVoteMaturityBlocks();

    auto mnList = deterministicMNManager->GetListAtChainTip();
    auto dmn = mnList.GetMN(proTxHash);
    if (!dmn) {
        return info;
    }

    info.exists = true;
    info.collateralAddress = GetMasternodeCollateralAddress(proTxHash);
    info.collateralHeight = FindFirstCollateralHeight(info.collateralAddress);

    if (info.collateralHeight < 0) {
        info.maturityBlocks = 0;
        info.eligible = false;
        info.blocksUntilEligible = info.requiredMaturity;
        return info;
    }

    info.maturityBlocks = currentHeight - info.collateralHeight;
    info.eligible = info.maturityBlocks > info.requiredMaturity;
    info.blocksUntilEligible = info.eligible ? 0 : (info.requiredMaturity - info.maturityBlocks + 1);

    return info;
}

#endif // BATHRON_EVO_MNMATURITY_H
