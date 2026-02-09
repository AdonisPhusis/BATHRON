#!/bin/bash
# =============================================================================
# claim_btc_htlc.sh - Claim BTC HTLC with 3 secrets (LP1 claims)
# =============================================================================
# This script builds and broadcasts the claim transaction for the BTC HTLC.
# It uses the 3 secrets and Alice's signature.

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

# HTLC Parameters (from MVP test)
FUNDING_TXID="d1c656881e844e6f9ef916ef426abdf451cdd6851cd17dff8d27497c15b44262"
FUNDING_VOUT=0
FUNDING_AMOUNT=10000  # sats

# Secrets
S_USER="2d6ea06f845f2fe64b03305076e39fe4114a15d8f83904d24a399168cd78f9ac"
S_LP1="c9f95172a736ed145f41b138fbc82eb80dc1492d28b201008e14d881cfac82d0"
S_LP2="681549506bf20b237b5ba05385d624b9fe36962aefae8b6c0128d0cf0713ccec"

# HTLC Script
HTLC_SCRIPT="63a82013ccc7087668869e62146ea776614c6ce10811c926ad583bda3d4a40864e05c088a820bdb432bb6537578e70c37da156b1b38ff7b94fd0c8f194d24f51856fdd2a409d88a820ecfcb6c5a30a876e665a1b7ce99dc1d8a04f38790584dd56cf118e02af5f4df28821039b6d9375838d5d4ad49e5fe75e3c8820dadbd9e601da39caa08132d2ecb8e7d5ac670190b275210370eeb81b88d20c6a9d3cace87c73698998077bc0b4ddf31b10f901e3f79a4378ac68"

# Alice's address to receive claimed BTC
ALICE_ADDRESS="tb1qc4ayevq4g7j4de52x8lkcxeffe3kqms6etvcrl"

echo "============================================================"
echo "Claim BTC HTLC (LP1 reveals 3 secrets)"
echo "============================================================"
echo ""
echo "Funding UTXO: ${FUNDING_TXID}:${FUNDING_VOUT}"
echo "Amount: ${FUNDING_AMOUNT} sats"
echo "Destination: ${ALICE_ADDRESS}"
echo ""

# Create claim script on OP3 (where Bitcoin is synced)
cat << 'CLAIM_SCRIPT' > /tmp/build_claim.py
#!/usr/bin/env python3
"""Build BTC HTLC claim transaction."""

import subprocess
import json
import hashlib

# Parameters
FUNDING_TXID = "d1c656881e844e6f9ef916ef426abdf451cdd6851cd17dff8d27497c15b44262"
FUNDING_VOUT = 0
FUNDING_AMOUNT = 10000  # sats

S_USER = bytes.fromhex("2d6ea06f845f2fe64b03305076e39fe4114a15d8f83904d24a399168cd78f9ac")
S_LP1 = bytes.fromhex("c9f95172a736ed145f41b138fbc82eb80dc1492d28b201008e14d881cfac82d0")
S_LP2 = bytes.fromhex("681549506bf20b237b5ba05385d624b9fe36962aefae8b6c0128d0cf0713ccec")

HTLC_SCRIPT = bytes.fromhex("63a82013ccc7087668869e62146ea776614c6ce10811c926ad583bda3d4a40864e05c088a820bdb432bb6537578e70c37da156b1b38ff7b94fd0c8f194d24f51856fdd2a409d88a820ecfcb6c5a30a876e665a1b7ce99dc1d8a04f38790584dd56cf118e02af5f4df28821039b6d9375838d5d4ad49e5fe75e3c8820dadbd9e601da39caa08132d2ecb8e7d5ac670190b275210370eeb81b88d20c6a9d3cace87c73698998077bc0b4ddf31b10f901e3f79a4378ac68")

ALICE_ADDRESS = "tb1qc4ayevq4g7j4de52x8lkcxeffe3kqms6etvcrl"

# Fee: ~200 sats for simple tx
FEE = 500
OUTPUT_AMOUNT = FUNDING_AMOUNT - FEE

CLI = "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

def run_cli(cmd):
    result = subprocess.run(f"{CLI} {cmd}", shell=True, capture_output=True, text=True)
    return result.stdout.strip()

# Verify secrets
print("Verifying secrets...")
for name, secret in [("S_USER", S_USER), ("S_LP1", S_LP1), ("S_LP2", S_LP2)]:
    h = hashlib.sha256(secret).hexdigest()
    print(f"  SHA256({name}) = {h[:16]}...")

# Create raw transaction
print("\nCreating raw transaction...")
inputs = json.dumps([{"txid": FUNDING_TXID, "vout": FUNDING_VOUT}])
outputs = json.dumps({ALICE_ADDRESS: OUTPUT_AMOUNT / 100000000})

raw_tx = run_cli(f'createrawtransaction \'{inputs}\' \'{outputs}\'')
print(f"Raw TX: {raw_tx[:40]}...")

# For P2WSH, we need to sign with the witness script
# The witness for claim is: <sig> <S_lp2> <S_lp1> <S_user> <1> <script>
# We need to build this manually or use signrawtransactionwithwallet with prevtxs

# Get the scriptPubKey from HTLC
script_hash = hashlib.sha256(HTLC_SCRIPT).digest()
scriptPubKey = "0020" + script_hash.hex()

prevtxs = json.dumps([{
    "txid": FUNDING_TXID,
    "vout": FUNDING_VOUT,
    "scriptPubKey": scriptPubKey,
    "witnessScript": HTLC_SCRIPT.hex(),
    "amount": FUNDING_AMOUNT / 100000000
}])

print(f"\nPrevtxs: {prevtxs[:80]}...")

# Try to sign (this will only work if we import the key)
# For MVP, we'll output the unsigned tx and witness structure

print("\n" + "="*60)
print("CLAIM TX STRUCTURE")
print("="*60)
print(f"Unsigned TX: {raw_tx}")
print(f"\nWitness stack (in order):")
print(f"  [0] <alice_signature> (needs signing)")
print(f"  [1] {S_LP2.hex()} (S_lp2)")
print(f"  [2] {S_LP1.hex()} (S_lp1)")
print(f"  [3] {S_USER.hex()} (S_user)")
print(f"  [4] 01 (OP_TRUE for IF branch)")
print(f"  [5] {HTLC_SCRIPT.hex()} (redeemScript)")

# Output the secrets that will be revealed
print("\n" + "="*60)
print("SECRETS REVEALED ON-CHAIN")
print("="*60)
print(f"S_user: {S_USER.hex()}")
print(f"S_lp1:  {S_LP1.hex()}")
print(f"S_lp2:  {S_LP2.hex()}")
print("\nOnce this TX is broadcast, anyone can extract these secrets")
print("and claim the USDC HTLC!")

# Save to file
with open('/tmp/claim_tx_data.json', 'w') as f:
    json.dump({
        'raw_tx': raw_tx,
        'prevtxs': json.loads(prevtxs),
        'secrets': {
            'S_user': S_USER.hex(),
            'S_lp1': S_LP1.hex(),
            'S_lp2': S_LP2.hex()
        },
        'witness_script': HTLC_SCRIPT.hex()
    }, f, indent=2)

print("\nSaved to /tmp/claim_tx_data.json")
CLAIM_SCRIPT

# Upload and run on OP3
echo "[INFO] Building claim transaction on OP3..."
scp $SSH_OPTS /tmp/build_claim.py ubuntu@$OP3_IP:/tmp/
ssh $SSH_OPTS ubuntu@$OP3_IP "python3 /tmp/build_claim.py"

echo ""
echo "============================================================"
echo "Next: Sign and broadcast from OP1 when synced"
echo "Or use the revealed secrets to claim USDC immediately"
echo "============================================================"
