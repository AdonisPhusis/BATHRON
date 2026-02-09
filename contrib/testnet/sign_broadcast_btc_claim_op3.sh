#!/bin/bash
# Sign and broadcast BTC HTLC claim from OP3 (which is synced)

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

echo "============================================================"
echo "SIGN AND BROADCAST BTC HTLC CLAIM (FROM OP3)"
echo "============================================================"
echo ""

# Get the private key from OP1 where it was derived
echo "[1/4] Getting private key from OP1..."
PRIVKEY=$(ssh $SSH_OPTS ubuntu@$OP1_IP "cat /tmp/alice_privkey.hex 2>/dev/null")
if [ -z "$PRIVKEY" ]; then
    echo "ERROR: Could not get private key from OP1"
    exit 1
fi
echo "  Got private key: ${PRIVKEY:0:16}..."

# Setup venv on OP3 and install ecdsa
echo ""
echo "[2/4] Setting up Python environment on OP3..."
ssh $SSH_OPTS ubuntu@$OP3_IP "
    if [ ! -d /tmp/sign_env ]; then
        python3 -m venv /tmp/sign_env
        /tmp/sign_env/bin/pip install -q ecdsa base58
    fi
"
echo "  Done"

# Create the signing script with embedded private key
echo ""
echo "[3/4] Creating signing script..."
cat << PYTHON_SCRIPT > /tmp/sign_btc_claim_op3.py
#!/usr/bin/env python3
"""Sign BTC HTLC claim with corrected bech32 decoding."""

import hashlib
import struct
import subprocess
import json

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
    data_part = addr[pos+1:]
    values = [CHARSET.index(c) for c in data_part]
    values = values[:-6]  # Remove checksum
    version = values[0]
    acc, bits, result = 0, 0, []
    for v in values[1:]:
        acc = (acc << 5) | v
        bits += 5
        while bits >= 8:
            bits -= 8
            result.append((acc >> bits) & 0xff)
    return version, bytes(result)

# Private key from OP1
privkey = bytes.fromhex("$PRIVKEY")

# HTLC Parameters
FUNDING_TXID = "d1c656881e844e6f9ef916ef426abdf451cdd6851cd17dff8d27497c15b44262"
FUNDING_VOUT = 0
FUNDING_VALUE = 10000  # 0.0001 BTC
FEE = 500
OUTPUT_VALUE = FUNDING_VALUE - FEE

# The 3 secrets
S_USER = bytes.fromhex("2d6ea06f845f2fe64b03305076e39fe4114a15d8f83904d24a399168cd78f9ac")
S_LP1 = bytes.fromhex("c9f95172a736ed145f41b138fbc82eb80dc1492d28b201008e14d881cfac82d0")
S_LP2 = bytes.fromhex("681549506bf20b237b5ba05385d624b9fe36962aefae8b6c0128d0cf0713ccec")

# HTLC redeem script
HTLC_SCRIPT = bytes.fromhex("63a82013ccc7087668869e62146ea776614c6ce10811c926ad583bda3d4a40864e05c088a820bdb432bb6537578e70c37da156b1b38ff7b94fd0c8f194d24f51856fdd2a409d88a820ecfcb6c5a30a876e665a1b7ce99dc1d8a04f38790584dd56cf118e02af5f4df28821039b6d9375838d5d4ad49e5fe75e3c8820dadbd9e601da39caa08132d2ecb8e7d5ac670190b275210370eeb81b88d20c6a9d3cace87c73698998077bc0b4ddf31b10f901e3f79a4378ac68")

# Alice's address (where claimed BTC goes)
ALICE_ADDRESS = "tb1qc4ayevq4g7j4de52x8lkcxeffe3kqms6etvcrl"

print("=" * 60)
print("SIGNING BTC HTLC CLAIM (FROM OP3)")
print("=" * 60)
print()

# Decode alice address
version, witness_program = bech32_decode(ALICE_ADDRESS)
output_script = bytes([version, len(witness_program)]) + witness_program
print(f"Output script: {output_script.hex()}")

# BIP143 sighash
print()
print("[1/4] Computing BIP143 sighash...")
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
print("[2/4] Signing...")
sk = SigningKey.from_string(privkey, curve=SECP256k1)
signature = sk.sign_digest(sighash, sigencode=sigencode_der_canonize)
sig_with_hashtype = signature + bytes([0x01])
print(f"  Signature: {sig_with_hashtype.hex()[:60]}...")

print()
print("[3/4] Building transaction...")

# Witness: <sig> <S_lp2> <S_lp1> <S_user> <TRUE> <script>
witness = var_int(6)
witness += var_int(len(sig_with_hashtype)) + sig_with_hashtype
witness += var_int(len(S_LP2)) + S_LP2
witness += var_int(len(S_LP1)) + S_LP1
witness += var_int(len(S_USER)) + S_USER
witness += var_int(1) + bytes([0x01])  # TRUE
witness += var_int(len(HTLC_SCRIPT)) + HTLC_SCRIPT

# SegWit TX
tx = struct.pack('<I', 2)  # version
tx += bytes([0x00, 0x01])  # segwit marker
tx += var_int(1)  # input count
tx += bytes.fromhex(FUNDING_TXID)[::-1]
tx += struct.pack('<I', FUNDING_VOUT)
tx += var_int(0)  # empty scriptSig
tx += struct.pack('<I', 0xffffffff)
tx += var_int(1)  # output count
tx += struct.pack('<Q', OUTPUT_VALUE)
tx += var_int(len(output_script)) + output_script
tx += witness
tx += struct.pack('<I', 0)  # locktime

tx_hex = tx.hex()
print(f"  TX size: {len(tx)} bytes")

print()
print("[4/4] Broadcasting...")

# Test first
stdout, stderr = run_cli(f"testmempoolaccept '[\"" + tx_hex + "\"]'")
if stdout:
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
                print()
                print("=" * 60)
                print("SUCCESS! BTC HTLC CLAIMED")
                print("=" * 60)
                print(f"  TXID: {stdout2}")
                print(f"  Explorer: https://mempool.space/signet/tx/{stdout2}")
                print()
                print("WITNESS CONTAINS 3 SECRETS:")
                print(f"  S_user: {S_USER.hex()}")
                print(f"  S_lp1:  {S_LP1.hex()}")
                print(f"  S_lp2:  {S_LP2.hex()}")

                # Save txid
                with open('/tmp/btc_claim_txid.txt', 'w') as f:
                    f.write(stdout2)
else:
    print(f"  Mempool error: {stderr}")
PYTHON_SCRIPT

# Copy to OP3 and run
echo ""
echo "[4/4] Running on OP3..."
scp $SSH_OPTS /tmp/sign_btc_claim_op3.py ubuntu@$OP3_IP:/tmp/
ssh $SSH_OPTS ubuntu@$OP3_IP "source /tmp/sign_env/bin/activate && python3 /tmp/sign_btc_claim_op3.py"

echo ""
echo "============================================================"
