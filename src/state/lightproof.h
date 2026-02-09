// Copyright (c) 2025 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BATHRON_LIGHTPROOF_H
#define BATHRON_LIGHTPROOF_H

#include "masternode/deterministicmns.h"
#include "state/finality.h"
#include "serialize.h"
#include "uint256.h"

#include <vector>

namespace hu {

/**
 * O1: Light Client Finality Proof
 *
 * Allows light clients (exchanges, mobile wallets) to verify block finality
 * without downloading the entire chain. Contains:
 * - Block hash and height
 * - Threshold signatures (8/12 required)
 * - Signer public keys for verification
 *
 * Verification process:
 * 1. Verify each signature against the corresponding pubkey
 * 2. Verify signers are in the quorum for this block
 * 3. Check signature count >= threshold
 *
 * This is a "naive" proof (no BLS aggregation) but cryptographically correct.
 */

/**
 * Minimal signer state for proof verification
 * Contains only what's needed to verify: proTxHash and operator pubkey
 */
struct CSignerState {
    uint256 proTxHash;
    CPubKey pubKeyOperator;

    CSignerState() = default;
    CSignerState(const uint256& hash, const CPubKey& key)
        : proTxHash(hash), pubKeyOperator(key) {}

    SERIALIZE_METHODS(CSignerState, obj) {
        READWRITE(obj.proTxHash);
        READWRITE(obj.pubKeyOperator);
    }

    bool operator==(const CSignerState& other) const {
        return proTxHash == other.proTxHash &&
               pubKeyOperator == other.pubKeyOperator;
    }
};

/**
 * Complete finality proof for a block
 */
struct CFinalityManagerProof {
    // Block identification
    uint256 blockHash;
    int nHeight{0};

    // Quorum parameters at this height
    int nQuorumSize{0};      // Total quorum size (e.g., 12)
    int nThreshold{0};       // Required signatures (e.g., 8)

    // Signatures from quorum members
    std::vector<CHuSignature> signatures;

    // Signer states (pubkeys for verification)
    std::vector<CSignerState> signerStates;

    CFinalityManagerProof() = default;

    SERIALIZE_METHODS(CFinalityManagerProof, obj) {
        READWRITE(obj.blockHash);
        READWRITE(obj.nHeight);
        READWRITE(obj.nQuorumSize);
        READWRITE(obj.nThreshold);
        READWRITE(obj.signatures);
        READWRITE(obj.signerStates);
    }

    /**
     * Verify the finality proof
     *
     * @param mnList Optional: MN list to verify signers are valid quorum members
     *               If null, only cryptographic verification is performed
     * @return true if proof is valid
     */
    bool Verify(const CDeterministicMNList* mnList = nullptr) const;

    /**
     * Verify only the cryptographic signatures (no quorum membership check)
     * Useful for light clients that trust the signer states in the proof
     */
    bool VerifyCrypto() const;

    /**
     * Get the number of valid signatures in this proof
     */
    int GetValidSignatureCount() const;

    /**
     * Check if this proof demonstrates finality
     */
    bool HasFinality() const {
        return GetValidSignatureCount() >= nThreshold && nThreshold > 0;
    }

    /**
     * Convert to JSON for RPC
     */
    UniValue ToJSON() const;

    /**
     * Size estimation for network transmission
     */
    size_t GetSerializeSize() const {
        return ::GetSerializeSize(*this, PROTOCOL_VERSION);
    }
};

/**
 * Build a finality proof for a block
 *
 * @param blockHash The block to build proof for
 * @param proofOut [out] The constructed proof
 * @return true if proof was built successfully
 */
bool BuildFinalityProof(const uint256& blockHash, CFinalityManagerProof& proofOut);

/**
 * Build a finality proof from existing finality data
 *
 * @param finality The finality record
 * @param mnList MN list for fetching pubkeys
 * @param proofOut [out] The constructed proof
 * @return true if proof was built successfully
 */
bool BuildFinalityProofFromRecord(const CFinalityManager& finality,
                                   const CDeterministicMNList& mnList,
                                   CFinalityManagerProof& proofOut);

} // namespace hu

#endif // BATHRON_LIGHTPROOF_H
