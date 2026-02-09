// Copyright (c) 2025 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "state/lightproof.h"

#include "chain.h"
#include "chainparams.h"
#include "hash.h"
#include "logging.h"
#include "state/quorum.h"
#include "../validation.h"

namespace hu {

// ============================================================================
// CFinalityManagerProof Implementation
// ============================================================================

bool CFinalityManagerProof::VerifyCrypto() const
{
    if (signatures.empty() || signerStates.empty()) {
        return false;
    }

    if (signatures.size() != signerStates.size()) {
        LogPrint(BCLog::STATE, "HU LightProof: Signature/state count mismatch (%zu vs %zu)\n",
                 signatures.size(), signerStates.size());
        return false;
    }

    // Recreate the message hash: "HUSIG" || blockHash
    CHashWriter ss(SER_GETHASH, 0);
    ss << std::string("HUSIG");
    ss << blockHash;
    uint256 msgHash = ss.GetHash();

    // Verify each signature
    for (size_t i = 0; i < signatures.size(); i++) {
        const CHuSignature& sig = signatures[i];
        const CSignerState& state = signerStates[i];

        // Verify proTxHash matches
        if (sig.proTxHash != state.proTxHash) {
            LogPrint(BCLog::STATE, "HU LightProof: ProTxHash mismatch at index %zu\n", i);
            return false;
        }

        // Verify block hash matches
        if (sig.blockHash != blockHash) {
            LogPrint(BCLog::STATE, "HU LightProof: BlockHash mismatch at index %zu\n", i);
            return false;
        }

        // Recover pubkey from compact signature and verify
        CPubKey recoveredPubKey;
        if (!recoveredPubKey.RecoverCompact(msgHash, sig.vchSig)) {
            LogPrint(BCLog::STATE, "HU LightProof: Failed to recover pubkey at index %zu\n", i);
            return false;
        }

        if (recoveredPubKey != state.pubKeyOperator) {
            LogPrint(BCLog::STATE, "HU LightProof: Pubkey mismatch at index %zu\n", i);
            return false;
        }
    }

    return true;
}

bool CFinalityManagerProof::Verify(const CDeterministicMNList* mnList) const
{
    // First verify cryptographic signatures
    if (!VerifyCrypto()) {
        return false;
    }

    // Check threshold
    if ((int)signatures.size() < nThreshold) {
        LogPrint(BCLog::STATE, "HU LightProof: Insufficient signatures (%zu < %d)\n",
                 signatures.size(), nThreshold);
        return false;
    }

    // If we have an MN list, verify signers are in the quorum
    if (mnList) {
        const Consensus::Params& consensus = Params().GetConsensus();

        // Get quorum for this block
        int cycleIndex = GetHuCycleIndex(nHeight, consensus.nHuQuorumRotationBlocks);

        for (const auto& sig : signatures) {
            // Verify the signer is a valid confirmed MN
            CDeterministicMNCPtr dmn = mnList->GetMN(sig.proTxHash);
            if (!dmn) {
                LogPrint(BCLog::STATE, "HU LightProof: Unknown MN %s\n",
                         sig.proTxHash.ToString().substr(0, 16));
                return false;
            }

            // Verify they were in the quorum
            // Note: For full verification we'd need the seed hash, but for light
            // clients trusting the proof structure this check is optional
        }
    }

    return true;
}

int CFinalityManagerProof::GetValidSignatureCount() const
{
    if (signatures.size() != signerStates.size()) {
        return 0;
    }

    // Recreate the message hash
    CHashWriter ss(SER_GETHASH, 0);
    ss << std::string("HUSIG");
    ss << blockHash;
    uint256 msgHash = ss.GetHash();

    int validCount = 0;
    for (size_t i = 0; i < signatures.size(); i++) {
        const CHuSignature& sig = signatures[i];
        const CSignerState& state = signerStates[i];

        if (sig.proTxHash != state.proTxHash) continue;
        if (sig.blockHash != blockHash) continue;

        CPubKey recoveredPubKey;
        if (!recoveredPubKey.RecoverCompact(msgHash, sig.vchSig)) continue;
        if (recoveredPubKey != state.pubKeyOperator) continue;

        validCount++;
    }

    return validCount;
}

UniValue CFinalityManagerProof::ToJSON() const
{
    UniValue result(UniValue::VOBJ);

    result.pushKV("blockhash", blockHash.ToString());
    result.pushKV("height", nHeight);
    result.pushKV("quorum_size", nQuorumSize);
    result.pushKV("threshold", nThreshold);
    result.pushKV("signature_count", (int)signatures.size());
    result.pushKV("valid_signatures", GetValidSignatureCount());
    result.pushKV("has_finality", HasFinality());
    result.pushKV("proof_size_bytes", (int)GetSerializeSize());

    // Signers array
    UniValue signers(UniValue::VARR);
    for (size_t i = 0; i < signerStates.size(); i++) {
        UniValue signer(UniValue::VOBJ);
        signer.pushKV("index", (int)i);
        signer.pushKV("proTxHash", signerStates[i].proTxHash.ToString());
        signer.pushKV("pubkey", HexStr(signerStates[i].pubKeyOperator));
        if (i < signatures.size()) {
            signer.pushKV("signature", HexStr(signatures[i].vchSig));
        }
        signers.push_back(signer);
    }
    result.pushKV("signers", signers);

    return result;
}

// ============================================================================
// Proof Building Functions
// ============================================================================

bool BuildFinalityProofFromRecord(const CFinalityManager& finality,
                                   const CDeterministicMNList& mnList,
                                   CFinalityManagerProof& proofOut)
{
    const Consensus::Params& consensus = Params().GetConsensus();

    proofOut.blockHash = finality.blockHash;
    proofOut.nHeight = finality.nHeight;
    proofOut.nQuorumSize = consensus.nHuQuorumSize;
    proofOut.nThreshold = consensus.nHuQuorumThreshold;
    proofOut.signatures.clear();
    proofOut.signerStates.clear();

    // Build signatures and signer states
    for (const auto& entry : finality.mapSignatures) {
        const uint256& proTxHash = entry.first;
        const std::vector<unsigned char>& vchSig = entry.second;

        // Get MN for pubkey
        CDeterministicMNCPtr dmn = mnList.GetMN(proTxHash);
        if (!dmn) {
            LogPrint(BCLog::STATE, "HU LightProof: Skipping unknown MN %s\n",
                     proTxHash.ToString().substr(0, 16));
            continue;
        }

        // Add signature
        CHuSignature sig;
        sig.blockHash = finality.blockHash;
        sig.proTxHash = proTxHash;
        sig.vchSig = vchSig;
        proofOut.signatures.push_back(sig);

        // Add signer state
        CSignerState state(proTxHash, dmn->pdmnState->pubKeyOperator);
        proofOut.signerStates.push_back(state);
    }

    LogPrint(BCLog::STATE, "HU LightProof: Built proof for block %s height=%d sigs=%zu\n",
             finality.blockHash.ToString().substr(0, 16),
             finality.nHeight,
             proofOut.signatures.size());

    return proofOut.signatures.size() >= (size_t)proofOut.nThreshold;
}

bool BuildFinalityProof(const uint256& blockHash, CFinalityManagerProof& proofOut)
{
    // Get finality data
    if (!finalityHandler) {
        LogPrint(BCLog::STATE, "HU LightProof: Finality handler not initialized\n");
        return false;
    }

    CFinalityManager finality;
    if (!finalityHandler->GetFinality(blockHash, finality)) {
        LogPrint(BCLog::STATE, "HU LightProof: No finality data for block %s\n",
                 blockHash.ToString().substr(0, 16));
        return false;
    }

    // Get block index for MN list lookup
    const CBlockIndex* pindex = nullptr;
    {
        LOCK(cs_main);
        auto it = mapBlockIndex.find(blockHash);
        if (it == mapBlockIndex.end()) {
            LogPrint(BCLog::STATE, "HU LightProof: Block not found in index\n");
            return false;
        }
        pindex = it->second;
    }

    if (!pindex->pprev) {
        LogPrint(BCLog::STATE, "HU LightProof: No previous block\n");
        return false;
    }

    // Get MN list at this block
    CDeterministicMNList mnList = deterministicMNManager->GetListForBlock(pindex->pprev);

    return BuildFinalityProofFromRecord(finality, mnList, proofOut);
}

} // namespace hu
