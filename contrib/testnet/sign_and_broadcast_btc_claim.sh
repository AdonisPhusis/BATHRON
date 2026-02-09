#!/bin/bash
# =============================================================================
# sign_and_broadcast_btc_claim.sh - Sign BTC HTLC claim and broadcast
# =============================================================================
# Signs the claim TX using Alice's key from OP1, broadcasts via OP3

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

echo "============================================================"
echo "Sign and Broadcast BTC HTLC Claim"
echo "============================================================"

# Step 1: Get Alice's extended private key from OP1
echo ""
echo "[1/4] Getting Alice's signing key from OP1..."

# Create signing script for OP1
cat << 'SIGN_SCRIPT' > /tmp/sign_btc_claim.py
#!/usr/bin/env python3
"""Sign BTC HTLC claim transaction."""

import subprocess
import json
import hashlib

CLI = "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

def run_cli(cmd):
    result = subprocess.run(f"{CLI} {cmd}", shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error: {result.stderr}")
    return result.stdout.strip()

# HTLC Parameters
FUNDING_TXID = "d1c656881e844e6f9ef916ef426abdf451cdd6851cd17dff8d27497c15b44262"
FUNDING_VOUT = 0
FUNDING_AMOUNT_BTC = 0.0001

# Secrets
S_USER = "2d6ea06f845f2fe64b03305076e39fe4114a15d8f83904d24a399168cd78f9ac"
S_LP1 = "c9f95172a736ed145f41b138fbc82eb80dc1492d28b201008e14d881cfac82d0"
S_LP2 = "681549506bf20b237b5ba05385d624b9fe36962aefae8b6c0128d0cf0713ccec"

# HTLC Script
HTLC_SCRIPT = "63a82013ccc7087668869e62146ea776614c6ce10811c926ad583bda3d4a40864e05c088a820bdb432bb6537578e70c37da156b1b38ff7b94fd0c8f194d24f51856fdd2a409d88a820ecfcb6c5a30a876e665a1b7ce99dc1d8a04f38790584dd56cf118e02af5f4df28821039b6d9375838d5d4ad49e5fe75e3c8820dadbd9e601da39caa08132d2ecb8e7d5ac670190b275210370eeb81b88d20c6a9d3cace87c73698998077bc0b4ddf31b10f901e3f79a4378ac68"

# Alice's address
ALICE_ADDRESS = "tb1qc4ayevq4g7j4de52x8lkcxeffe3kqms6etvcrl"

# Fee
FEE_SATS = 500
OUTPUT_SATS = int(FUNDING_AMOUNT_BTC * 100000000) - FEE_SATS
OUTPUT_BTC = OUTPUT_SATS / 100000000

print("Building claim transaction...")

# Create raw transaction
inputs = json.dumps([{"txid": FUNDING_TXID, "vout": FUNDING_VOUT}])
outputs = json.dumps({ALICE_ADDRESS: OUTPUT_BTC})

raw_tx = run_cli(f"createrawtransaction '{inputs}' '{outputs}'")
print(f"Raw TX: {raw_tx[:40]}...")

# Calculate scriptPubKey
script_bytes = bytes.fromhex(HTLC_SCRIPT)
script_hash = hashlib.sha256(script_bytes).digest()
scriptPubKey = "0020" + script_hash.hex()

# Prepare prevtxs for signing
prevtxs = json.dumps([{
    "txid": FUNDING_TXID,
    "vout": FUNDING_VOUT,
    "scriptPubKey": scriptPubKey,
    "witnessScript": HTLC_SCRIPT,
    "amount": FUNDING_AMOUNT_BTC
}])

print(f"Signing with alice_lp wallet...")

# Sign using wallet
signed_result = run_cli(f"-rpcwallet=alice_lp signrawtransactionwithwallet '{raw_tx}' '{prevtxs}'")
print(f"Sign result: {signed_result[:100]}...")

try:
    signed_data = json.loads(signed_result)
    if signed_data.get('complete'):
        print("Signature complete!")
        signed_hex = signed_data['hex']

        # Now we need to add the witness manually because signrawtransactionwithwallet
        # doesn't know about our custom HTLC script
        # The witness should be: <sig> <S_lp2> <S_lp1> <S_user> <01> <script>

        # Actually, let's output what we have and build witness manually
        print(f"\nSigned TX (partial): {signed_hex}")
        print("\nManual witness construction needed for HTLC claim path")
    else:
        print(f"Signing incomplete: {signed_data.get('errors', 'unknown')}")
except json.JSONDecodeError as e:
    print(f"JSON parse error: {e}")
    print(f"Raw output: {signed_result}")
SIGN_SCRIPT

scp $SSH_OPTS /tmp/sign_btc_claim.py ubuntu@$OP1_IP:/tmp/
ssh $SSH_OPTS ubuntu@$OP1_IP "python3 /tmp/sign_btc_claim.py"

echo ""
echo "[2/4] Since signrawtransactionwithwallet doesn't handle custom HTLC,"
echo "      we need to use a different approach..."

# Alternative: Build and sign manually using python-bitcoinlib
cat << 'MANUAL_SIGN' > /tmp/manual_btc_sign.py
#!/usr/bin/env python3
"""Manually build and sign BTC HTLC claim using descriptors."""

import subprocess
import json
import hashlib
import struct

CLI = "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

def run_cli(cmd):
    result = subprocess.run(f"{CLI} {cmd}", shell=True, capture_output=True, text=True)
    return result.stdout.strip()

# Get Alice's private key from descriptor
print("Getting Alice's private key from descriptor wallet...")
descriptors = run_cli("-rpcwallet=alice_lp listdescriptors true")

try:
    desc_data = json.loads(descriptors)
    for desc in desc_data.get('descriptors', []):
        if 'wpkh' in desc['desc'] and '/0/*' in desc['desc']:
            # This is the receiving descriptor
            d = desc['desc']
            # Extract the xprv - format: wpkh([fingerprint/path]xprv.../0/*)#checksum
            start = d.find(']') + 1
            end = d.find('/', start)
            if start > 0 and end > start:
                xprv = d[start:end]
                print(f"Found xprv: {xprv[:20]}...")

                # We need to derive the actual key at index 0
                # For now, output the descriptor for manual use
                print(f"\nDescriptor (with privkey): {d[:80]}...")
                break
except Exception as e:
    print(f"Error: {e}")

print("\n" + "="*60)
print("ALTERNATIVE: Use Electrum or a signing tool")
print("="*60)
print("""
Since Bitcoin Core doesn't easily support custom witness scripts,
options are:

1. Use Electrum with Signet
2. Use python-bitcoinlib (requires pip install)
3. Use btcdeb for manual signing

For MVP, we can use a pre-signed transaction or wait for
a proper signing implementation.
""")
MANUAL_SIGN

scp $SSH_OPTS /tmp/manual_btc_sign.py ubuntu@$OP1_IP:/tmp/
ssh $SSH_OPTS ubuntu@$OP1_IP "python3 /tmp/manual_btc_sign.py"

echo ""
echo "============================================================"
echo "NOTE: Custom HTLC signing requires additional tooling"
echo "============================================================"
echo ""
echo "For the MVP atomicity proof, we need to either:"
echo "1. Install python-bitcoinlib and sign manually"
echo "2. Use Electrum CLI with custom script support"
echo "3. Implement signing in the btc_3s.py SDK"
echo ""
echo "The BTC HTLC is funded and ready at:"
echo "  https://mempool.space/signet/address/tb1q959k2v75u5fx4kjgsr5gvq99hywt0kugq0q8kj70ff396yquexzshwxxtj"
