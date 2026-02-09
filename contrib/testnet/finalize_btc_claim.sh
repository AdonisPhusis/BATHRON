#!/bin/bash
# =============================================================================
# finalize_btc_claim.sh - Sign and broadcast BTC HTLC claim
# =============================================================================
# This gets Alice's key from OP1 and broadcasts the claim via OP3

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

echo "============================================================"
echo "Finalize BTC HTLC Claim"
echo "============================================================"
echo ""

# Create a Python script that handles everything
cat << 'FINALIZE_PY' > /tmp/finalize_btc_claim.py
#!/usr/bin/env python3
"""
Sign and broadcast BTC HTLC claim.

Uses descriptor wallet export + manual signing.
"""

import subprocess
import json
import hashlib
import struct
import sys
import os

# Config
CLI = "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

# HTLC Parameters
FUNDING_TXID = "d1c656881e844e6f9ef916ef426abdf451cdd6851cd17dff8d27497c15b44262"
FUNDING_VOUT = 0
FUNDING_VALUE = 10000  # sats
FEE = 500
OUTPUT_VALUE = FUNDING_VALUE - FEE

# Secrets (will be revealed on-chain)
S_USER = bytes.fromhex("2d6ea06f845f2fe64b03305076e39fe4114a15d8f83904d24a399168cd78f9ac")
S_LP1 = bytes.fromhex("c9f95172a736ed145f41b138fbc82eb80dc1492d28b201008e14d881cfac82d0")
S_LP2 = bytes.fromhex("681549506bf20b237b5ba05385d624b9fe36962aefae8b6c0128d0cf0713ccec")

# HTLC Script
HTLC_SCRIPT = bytes.fromhex("63a82013ccc7087668869e62146ea776614c6ce10811c926ad583bda3d4a40864e05c088a820bdb432bb6537578e70c37da156b1b38ff7b94fd0c8f194d24f51856fdd2a409d88a820ecfcb6c5a30a876e665a1b7ce99dc1d8a04f38790584dd56cf118e02af5f4df28821039b6d9375838d5d4ad49e5fe75e3c8820dadbd9e601da39caa08132d2ecb8e7d5ac670190b275210370eeb81b88d20c6a9d3cace87c73698998077bc0b4ddf31b10f901e3f79a4378ac68")

# Alice's receiving address
ALICE_ADDRESS = "tb1qc4ayevq4g7j4de52x8lkcxeffe3kqms6etvcrl"

def run_cli(cmd):
    result = subprocess.run(f"{CLI} {cmd}", shell=True, capture_output=True, text=True)
    return result.stdout.strip()

def double_sha256(data):
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()

def var_int(n):
    if n < 0xfd:
        return bytes([n])
    elif n <= 0xffff:
        return bytes([0xfd]) + struct.pack('<H', n)
    else:
        return bytes([0xfe]) + struct.pack('<I', n)

print("=" * 60)
print("BTC HTLC CLAIM - Sign & Broadcast")
print("=" * 60)
print()

# Step 1: Get Alice's private key from descriptor
print("[1/4] Getting Alice's private key...")

descriptors = run_cli("-rpcwallet=alice_lp listdescriptors true")
if not descriptors:
    print("ERROR: Cannot get descriptors. Is wallet loaded?")
    sys.exit(1)

desc_data = json.loads(descriptors)
xprv = None
for desc in desc_data.get('descriptors', []):
    if 'wpkh' in desc['desc'] and '/0/*' in desc['desc']:
        # Extract xprv from descriptor
        d = desc['desc']
        # Format: wpkh([fingerprint/path]xprv.../0/*)#checksum
        import re
        match = re.search(r'\](tprv[a-zA-Z0-9]+)/', d)
        if match:
            xprv = match.group(1)
            print(f"  Found xprv: {xprv[:20]}...")
            break

if not xprv:
    print("ERROR: Could not extract xprv from descriptors")
    print("Trying alternative: import HTLC script into wallet...")

    # Alternative: Use importdescriptors to import the HTLC
    # This is complex, so let's try a different approach

    # Get the WIF for the first address
    print("\n  Trying to derive private key at index 0...")

    # Use deriveaddresses to get the first address, then try to get its key
    # Actually, for descriptor wallets, we need to use the xprv to derive

    print("\n  NOTE: Descriptor wallet key derivation requires BIP32 library")
    print("  Installing bip32...")

    os.system("pip3 install --user bip32 base58 2>/dev/null")

    # Now derive the key
    try:
        from bip32 import BIP32
        import base58

        # Remove tprv prefix and decode
        raw = base58.b58decode_check(xprv)
        # BIP32 xprv format: 4 bytes version, 1 byte depth, 4 bytes fingerprint,
        # 4 bytes child number, 32 bytes chain code, 33 bytes key (00 + 32 bytes privkey)
        privkey = raw[46:78]

        print(f"  Private key derived: {privkey.hex()[:16]}...")

    except Exception as e:
        print(f"  BIP32 derivation error: {e}")
        print("\n  Falling back to signing via wallet...")

        # Create a PSBT instead
        print("\n[Alternative] Creating PSBT for signing...")

        # Build the raw transaction first
        inputs = json.dumps([{"txid": FUNDING_TXID, "vout": FUNDING_VOUT}])
        outputs = json.dumps({ALICE_ADDRESS: OUTPUT_VALUE / 100000000})

        raw_tx = run_cli(f"createrawtransaction '{inputs}' '{outputs}'")
        print(f"  Raw TX: {raw_tx[:40]}...")

        # Convert to PSBT
        psbt = run_cli(f"converttopsbt '{raw_tx}'")
        print(f"  PSBT: {psbt[:40]}...")

        # Update PSBT with UTXO info
        script_hash = hashlib.sha256(HTLC_SCRIPT).digest()
        scriptPubKey = "0020" + script_hash.hex()

        utxo_update = json.dumps([{
            "txid": FUNDING_TXID,
            "vout": FUNDING_VOUT,
            "scriptPubKey": scriptPubKey,
            "witnessScript": HTLC_SCRIPT.hex(),
            "amount": FUNDING_VALUE / 100000000
        }])

        # Try to process/sign the PSBT
        processed = run_cli(f"-rpcwallet=alice_lp walletprocesspsbt '{psbt}'")
        print(f"  Processed: {processed[:100]}...")

        sys.exit(1)

print()
print("[2/4] Building sighash...")

# We need to implement BIP143 sighash calculation
# For P2WSH, the sighash commits to the witnessScript

# Decode alice's address to get output script
# tb1qc4ayevq4g7j4de52x8lkcxeffe3kqms6etvcrl
# This is bech32 for witness program

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

def bech32_decode(addr):
    hrp = addr[:2]
    data_part = addr[3:]  # Skip hrp + '1'
    values = [CHARSET.index(c) for c in data_part]

    # Convert from 5-bit to 8-bit
    acc = 0
    bits = 0
    result = []
    for v in values[:-6]:  # Exclude checksum
        acc = (acc << 5) | v
        bits += 5
        while bits >= 8:
            bits -= 8
            result.append((acc >> bits) & 0xff)

    return bytes(result)

witness_program = bech32_decode(ALICE_ADDRESS)
output_script = bytes([0x00, len(witness_program)]) + witness_program

print(f"  Output script: {output_script.hex()}")

# Build the sighash preimage (BIP143)
# nVersion (4) + hashPrevouts (32) + hashSequence (32) + outpoint (36) +
# scriptCode (var) + value (8) + nSequence (4) + hashOutputs (32) +
# nLockTime (4) + sighashType (4)

# hashPrevouts
prevouts = bytes.fromhex(FUNDING_TXID)[::-1] + struct.pack('<I', FUNDING_VOUT)
hashPrevouts = double_sha256(prevouts)

# hashSequence
hashSequence = double_sha256(struct.pack('<I', 0xffffffff))

# hashOutputs
output_data = struct.pack('<Q', OUTPUT_VALUE) + var_int(len(output_script)) + output_script
hashOutputs = double_sha256(output_data)

# scriptCode for P2WSH is the witnessScript with length prefix
script_code = var_int(len(HTLC_SCRIPT)) + HTLC_SCRIPT

# Build preimage
preimage = b''
preimage += struct.pack('<I', 2)  # nVersion
preimage += hashPrevouts
preimage += hashSequence
preimage += bytes.fromhex(FUNDING_TXID)[::-1] + struct.pack('<I', FUNDING_VOUT)  # outpoint
preimage += script_code
preimage += struct.pack('<Q', FUNDING_VALUE)  # value
preimage += struct.pack('<I', 0xffffffff)  # nSequence
preimage += hashOutputs
preimage += struct.pack('<I', 0)  # nLockTime
preimage += struct.pack('<I', 1)  # SIGHASH_ALL

sighash = double_sha256(preimage)
print(f"  Sighash: {sighash.hex()}")

print()
print("[3/4] Signing...")

try:
    from ecdsa import SigningKey, SECP256k1
    from ecdsa.util import sigencode_der_canonize

    sk = SigningKey.from_string(privkey, curve=SECP256k1)
    signature = sk.sign_digest(sighash, sigencode=sigencode_der_canonize)
    signature_with_hashtype = signature + bytes([0x01])  # SIGHASH_ALL

    print(f"  Signature: {signature_with_hashtype.hex()[:40]}...")

except NameError:
    print("  ERROR: Private key not available")
    sys.exit(1)

print()
print("[4/4] Building final transaction...")

# Build witness: <sig> <S_lp2> <S_lp1> <S_user> <01> <script>
witness = b''
witness += var_int(6)  # 6 witness items

# Signature
witness += var_int(len(signature_with_hashtype)) + signature_with_hashtype
# S_lp2
witness += var_int(len(S_LP2)) + S_LP2
# S_lp1
witness += var_int(len(S_LP1)) + S_LP1
# S_user
witness += var_int(len(S_USER)) + S_USER
# OP_TRUE
witness += var_int(1) + bytes([0x01])
# Witness script
witness += var_int(len(HTLC_SCRIPT)) + HTLC_SCRIPT

# Build complete transaction
tx = b''
tx += struct.pack('<I', 2)  # Version
tx += bytes([0x00, 0x01])  # Marker, Flag (witness)
tx += var_int(1)  # Input count

# Input
tx += bytes.fromhex(FUNDING_TXID)[::-1]  # txid
tx += struct.pack('<I', FUNDING_VOUT)  # vout
tx += var_int(0)  # empty scriptSig
tx += struct.pack('<I', 0xffffffff)  # sequence

# Output count
tx += var_int(1)

# Output
tx += struct.pack('<Q', OUTPUT_VALUE)
tx += var_int(len(output_script)) + output_script

# Witness
tx += witness

# Locktime
tx += struct.pack('<I', 0)

print(f"  Final TX: {tx.hex()[:80]}...")
print(f"  TX size: {len(tx)} bytes")

# Save to file
with open('/tmp/signed_btc_claim.hex', 'w') as f:
    f.write(tx.hex())

print()
print("=" * 60)
print("SIGNED TRANSACTION READY")
print("=" * 60)
print(f"Saved to: /tmp/signed_btc_claim.hex")
print()
print("To broadcast:")
print(f"  bitcoin-cli -signet sendrawtransaction $(cat /tmp/signed_btc_claim.hex)")
FINALIZE_PY

# Upload and run on OP1
echo "[INFO] Running claim script on OP1..."
scp $SSH_OPTS /tmp/finalize_btc_claim.py ubuntu@$OP1_IP:/tmp/
ssh $SSH_OPTS ubuntu@$OP1_IP "pip3 install --user ecdsa bip32 base58 2>/dev/null; python3 /tmp/finalize_btc_claim.py"

# If successful, copy the signed TX and broadcast from OP3
echo ""
echo "[INFO] Getting signed TX..."
SIGNED_TX=$(ssh $SSH_OPTS ubuntu@$OP1_IP "cat /tmp/signed_btc_claim.hex 2>/dev/null")

if [ -n "$SIGNED_TX" ]; then
    echo "[INFO] Broadcasting via OP3..."
    ssh $SSH_OPTS ubuntu@$OP3_IP "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet sendrawtransaction '$SIGNED_TX'"
else
    echo "[WARN] No signed TX found - check OP1 output above"
fi
