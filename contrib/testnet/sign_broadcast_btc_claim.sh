#!/bin/bash
# Sign and broadcast BTC HTLC claim from OP1
# This script runs the corrected signing logic on OP1

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP1_IP="57.131.33.152"

echo "============================================================"
echo "SIGN AND BROADCAST BTC HTLC CLAIM"
echo "============================================================"
echo ""

# Create the corrected signing script
cat << 'PYTHON_SCRIPT' > /tmp/sign_btc_claim_fixed.py
#!/usr/bin/env python3
"""Sign BTC HTLC claim with corrected bech32 decoding."""

import hashlib
import struct
import subprocess

from ecdsa import SigningKey, SECP256k1
from ecdsa.util import sigencode_der_canonize

CLI = "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

def run_cli(cmd):
    result = subprocess.run(f"{CLI} {cmd}", shell=True, capture_output=True, text=True)
    return result.stdout.strip(), result.stderr.strip()

def double_sha256(data):
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()

def var_int(n):
    if n < 0xfd:
        return bytes([n])
    elif n <= 0xffff:
        return bytes([0xfd]) + struct.pack('<H', n)
    return bytes([0xfe]) + struct.pack('<I', n)

# Proper bech32 decoding
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

def bech32_decode(addr):
    """Properly decode bech32 address to witness program."""
    pos = addr.rfind('1')
    hrp = addr[:pos]
    data_part = addr[pos+1:]

    # Decode characters to 5-bit values
    values = [CHARSET.index(c) for c in data_part]

    # Remove checksum (last 6 values)
    values = values[:-6]

    # First value is witness version
    version = values[0]

    # Convert remaining from 5-bit to 8-bit
    acc = 0
    bits = 0
    result = []
    for v in values[1:]:
        acc = (acc << 5) | v
        bits += 5
        while bits >= 8:
            bits -= 8
            result.append((acc >> bits) & 0xff)

    return version, bytes(result)

# Load private key
with open('/tmp/alice_privkey.hex') as f:
    privkey = bytes.fromhex(f.read().strip())

# HTLC Parameters
FUNDING_TXID = "d1c656881e844e6f9ef916ef426abdf451cdd6851cd17dff8d27497c15b44262"
FUNDING_VOUT = 0
FUNDING_VALUE = 10000
FEE = 500
OUTPUT_VALUE = FUNDING_VALUE - FEE

S_USER = bytes.fromhex("2d6ea06f845f2fe64b03305076e39fe4114a15d8f83904d24a399168cd78f9ac")
S_LP1 = bytes.fromhex("c9f95172a736ed145f41b138fbc82eb80dc1492d28b201008e14d881cfac82d0")
S_LP2 = bytes.fromhex("681549506bf20b237b5ba05385d624b9fe36962aefae8b6c0128d0cf0713ccec")

HTLC_SCRIPT = bytes.fromhex("63a82013ccc7087668869e62146ea776614c6ce10811c926ad583bda3d4a40864e05c088a820bdb432bb6537578e70c37da156b1b38ff7b94fd0c8f194d24f51856fdd2a409d88a820ecfcb6c5a30a876e665a1b7ce99dc1d8a04f38790584dd56cf118e02af5f4df28821039b6d9375838d5d4ad49e5fe75e3c8820dadbd9e601da39caa08132d2ecb8e7d5ac670190b275210370eeb81b88d20c6a9d3cace87c73698998077bc0b4ddf31b10f901e3f79a4378ac68")

ALICE_ADDRESS = "tb1qc4ayevq4g7j4de52x8lkcxeffe3kqms6etvcrl"

print("=" * 60)
print("SIGNING BTC HTLC CLAIM (FIXED)")
print("=" * 60)
print()

# Decode alice address with CORRECT bech32
version, witness_program = bech32_decode(ALICE_ADDRESS)
print(f"[0/5] Bech32 decode:")
print(f"  Address: {ALICE_ADDRESS}")
print(f"  Version: {version}")
print(f"  Witness program: {witness_program.hex()}")
print(f"  Length: {len(witness_program)} bytes")

# Build output script - OP_0 <len> <witness_program>
output_script = bytes([version, len(witness_program)]) + witness_program
print(f"  Output script: {output_script.hex()}")

# Verify expected
expected_wp = "c57a4cb01547a556e68a31ff6c1b294e63606e1a"
if witness_program.hex() == expected_wp:
    print("  OK: Correct witness program")
else:
    print(f"  ERROR: Expected {expected_wp}, got {witness_program.hex()}")
    exit(1)

# BIP143 sighash
print()
print("[1/5] Computing BIP143 sighash...")
prevouts = bytes.fromhex(FUNDING_TXID)[::-1] + struct.pack('<I', FUNDING_VOUT)
hashPrevouts = double_sha256(prevouts)
hashSequence = double_sha256(struct.pack('<I', 0xffffffff))

output_data = struct.pack('<Q', OUTPUT_VALUE) + var_int(len(output_script)) + output_script
hashOutputs = double_sha256(output_data)

script_code = var_int(len(HTLC_SCRIPT)) + HTLC_SCRIPT

preimage = struct.pack('<I', 2)  # version
preimage += hashPrevouts
preimage += hashSequence
preimage += bytes.fromhex(FUNDING_TXID)[::-1] + struct.pack('<I', FUNDING_VOUT)
preimage += script_code
preimage += struct.pack('<Q', FUNDING_VALUE)
preimage += struct.pack('<I', 0xffffffff)  # sequence
preimage += hashOutputs
preimage += struct.pack('<I', 0)  # locktime
preimage += struct.pack('<I', 1)  # SIGHASH_ALL

sighash = double_sha256(preimage)
print(f"  Sighash: {sighash.hex()}")

print()
print("[2/5] Signing...")
sk = SigningKey.from_string(privkey, curve=SECP256k1)
signature = sk.sign_digest(sighash, sigencode=sigencode_der_canonize)
sig_with_hashtype = signature + bytes([0x01])  # SIGHASH_ALL
print(f"  Signature: {sig_with_hashtype.hex()[:60]}...")
print(f"  Sig length: {len(sig_with_hashtype)} bytes")

print()
print("[3/5] Building witness...")
# Witness stack for success path (OP_IF branch):
# <sig> <S_lp2> <S_lp1> <S_user> <TRUE> <script>
witness = var_int(6)  # 6 items
witness += var_int(len(sig_with_hashtype)) + sig_with_hashtype
witness += var_int(len(S_LP2)) + S_LP2
witness += var_int(len(S_LP1)) + S_LP1
witness += var_int(len(S_USER)) + S_USER
witness += var_int(1) + bytes([0x01])  # TRUE for OP_IF
witness += var_int(len(HTLC_SCRIPT)) + HTLC_SCRIPT

print(f"  Witness items: 6")
print(f"  [0] sig: {len(sig_with_hashtype)} bytes")
print(f"  [1] S_lp2: {len(S_LP2)} bytes")
print(f"  [2] S_lp1: {len(S_LP1)} bytes")
print(f"  [3] S_user: {len(S_USER)} bytes")
print(f"  [4] TRUE: 1 byte")
print(f"  [5] script: {len(HTLC_SCRIPT)} bytes")

print()
print("[4/5] Building transaction...")

# SegWit transaction format
tx = struct.pack('<I', 2)  # version
tx += bytes([0x00, 0x01])  # marker + flag (segwit)
tx += var_int(1)  # input count

# Input
tx += bytes.fromhex(FUNDING_TXID)[::-1]  # prev txid (LE)
tx += struct.pack('<I', FUNDING_VOUT)  # prev vout
tx += var_int(0)  # empty scriptSig
tx += struct.pack('<I', 0xffffffff)  # sequence

# Output
tx += var_int(1)  # output count
tx += struct.pack('<Q', OUTPUT_VALUE)  # value
tx += var_int(len(output_script)) + output_script

# Witness
tx += witness

# Locktime
tx += struct.pack('<I', 0)

tx_hex = tx.hex()
print(f"  TX size: {len(tx)} bytes")
print(f"  TX hex (first 80): {tx_hex[:80]}...")

# Save for debugging
with open('/tmp/signed_btc_claim.hex', 'w') as f:
    f.write(tx_hex)

print()
print("[5/5] Testing and broadcasting...")

# Decode first
stdout, stderr = run_cli(f"decoderawtransaction {tx_hex}")
if stderr:
    print(f"  Decode error: {stderr}")
else:
    print("  TX decoded OK")

# Test mempool accept
stdout, stderr = run_cli(f"testmempoolaccept '[\"" + tx_hex + "\"]'")
if stdout:
    import json
    result = json.loads(stdout)
    for r in result:
        print(f"  Mempool accept: allowed={r.get('allowed', False)}")
        if 'reject-reason' in r:
            print(f"  Reject reason: {r['reject-reason']}")
        if r.get('allowed'):
            # Broadcast!
            stdout2, stderr2 = run_cli(f"sendrawtransaction {tx_hex}")
            if stderr2:
                print(f"  Broadcast error: {stderr2}")
            else:
                print(f"  BROADCAST SUCCESS!")
                print(f"  TXID: {stdout2}")
                print(f"  Explorer: https://mempool.space/signet/tx/{stdout2}")
else:
    print(f"  Mempool test error: {stderr}")
PYTHON_SCRIPT

# Copy to OP1 and run
echo "[1/2] Copying script to OP1..."
scp $SSH_OPTS /tmp/sign_btc_claim_fixed.py ubuntu@$OP1_IP:/tmp/

echo ""
echo "[2/2] Running on OP1..."
ssh $SSH_OPTS ubuntu@$OP1_IP "cd /tmp && source /tmp/sign_env/bin/activate && python3 /tmp/sign_btc_claim_fixed.py"

echo ""
echo "============================================================"
echo "DONE"
echo "============================================================"
