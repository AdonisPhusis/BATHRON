// Copyright (c) 2025 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BATHRON_SCRIPT_TEMPLATE_HASH_H
#define BATHRON_SCRIPT_TEMPLATE_HASH_H

#include "hash.h"
#include "primitives/transaction.h"
#include "serialize.h"
#include "uint256.h"

/** Maximum outputs allowed in a CTV template (v1 DoS limit). */
static const size_t CTV_MAX_OUTPUTS = 4;

/** Compute the template hash for OP_TEMPLATEVERIFY (CTV-lite).
 *  Hash = SHA256d(nVersion || nType || locktime || input_count || sequences ||
 *                 output_count || outputs[])
 *  Commits nType to prevent cross-type template collisions (normal vs special TX).
 *  Does NOT commit prevouts or witnesses.
 */
inline uint256 ComputeTemplateHash(const CTransaction& tx)
{
    CHashWriter ss(SER_GETHASH, 0);
    ss << tx.nVersion;
    ss << tx.nType;
    ss << tx.nLockTime;

    WriteCompactSize(ss, tx.vin.size());
    for (const auto& in : tx.vin)
        ss << in.nSequence;

    WriteCompactSize(ss, tx.vout.size());
    for (const auto& out : tx.vout) {
        ss << out.nValue;
        ss << out.scriptPubKey;
    }

    return ss.GetHash();
}

#endif // BATHRON_SCRIPT_TEMPLATE_HASH_H
