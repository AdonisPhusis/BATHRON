#!/bin/bash
# Sign and broadcast BTC HTLC claim from OP3 (with system pip install)

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

echo "============================================================"
echo "SIGN AND BROADCAST BTC HTLC CLAIM (FROM OP3 v2)"
echo "============================================================"
echo ""

# Get the private key from OP1
echo "[1/4] Getting private key from OP1..."
PRIVKEY=$(ssh $SSH_OPTS ubuntu@$OP1_IP "cat /tmp/alice_privkey.hex 2>/dev/null")
if [ -z "$PRIVKEY" ]; then
    echo "ERROR: Could not get private key from OP1"
    exit 1
fi
echo "  Got private key: ${PRIVKEY:0:16}..."

# Install ecdsa on OP3 with --break-system-packages
echo ""
echo "[2/4] Installing ecdsa on OP3..."
ssh $SSH_OPTS ubuntu@$OP3_IP "pip3 install --user --break-system-packages -q ecdsa 2>/dev/null || pip3 install --user -q ecdsa 2>/dev/null || echo 'ecdsa may already be installed'"
echo "  Done"

# Create signing script
echo ""
echo "[3/4] Creating and copying signing script..."
cat << PYTHON_SCRIPT > /tmp/sign_btc_claim_op3.py
#!/usr/bin/env python3
import hashlib
import struct
import subprocess
import json
import sys

# Try to import ecdsa
try:
    from ecdsa import SigningKey, SECP256k1
    from ecdsa.util import sigencode_der_canonize
except ImportError:
    print("ERROR: ecdsa not installed. Run: pip3 install --user ecdsa")
    sys.exit(1)

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

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

def bech32_decode(addr):
    pos = addr.rfind('1')
    data_part = addr[pos+1:]
    values = [CHARSET.index(c) for c in data_part]
    values = values[:-6]
    version = values[0]
    acc, bits, result = 0, 0, []
    for v in values[1:]:
        acc = (acc << 5) | v
        bits += 5
        while bits >= 8:
            bits -= 8
            result.append((acc >> bits) & 0xff)
    return version, bytes(result)

privkey = bytes.fromhex("$PRIVKEY")

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
print("SIGNING BTC HTLC CLAIM (OP3)")
print("=" * 60)

version, witness_program = bech32_decode(ALICE_ADDRESS)
output_script = bytes([version, len(witness_program)]) + witness_program

# BIP143 sighash
prevouts = bytes.fromhex(FUNDING_TXID)[::-1] + struct.pack('<I', FUNDING_VOUT)
hashPrevouts = double_sha256(prevouts)
hashSequence = double_sha256(struct.pack('<I', 0xffffffff))

output_data = struct.pack('<Q', OUTPUT_VALUE) + var_int(len(output_script)) + output_script
hashOutputs = double_sha256(output_data)

script_code = var_int(len(HTLC_SCRIPT)) + HTLC_SCRIPT

preimage = struct.pack('<I', 2)
preimage += hashPrevouts
preimage += hashSequence
preimage += bytes.fromhex(FUNDING_TXID)[::-1] + struct.pack('<I', FUNDING_VOUT)
preimage += script_code
preimage += struct.pack('<Q', FUNDING_VALUE)
preimage += struct.pack('<I', 0xffffffff)
preimage += hashOutputs
preimage += struct.pack('<I', 0)
preimage += struct.pack('<I', 1)

sighash = double_sha256(preimage)
print(f"Sighash: {sighash.hex()[:32]}...")

sk = SigningKey.from_string(privkey, curve=SECP256k1)
signature = sk.sign_digest(sighash, sigencode=sigencode_der_canonize)
sig_with_hashtype = signature + bytes([0x01])
print(f"Signature: {sig_with_hashtype.hex()[:32]}...")

witness = var_int(6)
witness += var_int(len(sig_with_hashtype)) + sig_with_hashtype
witness += var_int(len(S_LP2)) + S_LP2
witness += var_int(len(S_LP1)) + S_LP1
witness += var_int(len(S_USER)) + S_USER
witness += var_int(1) + bytes([0x01])
witness += var_int(len(HTLC_SCRIPT)) + HTLC_SCRIPT

tx = struct.pack('<I', 2)
tx += bytes([0x00, 0x01])
tx += var_int(1)
tx += bytes.fromhex(FUNDING_TXID)[::-1]
tx += struct.pack('<I', FUNDING_VOUT)
tx += var_int(0)
tx += struct.pack('<I', 0xffffffff)
tx += var_int(1)
tx += struct.pack('<Q', OUTPUT_VALUE)
tx += var_int(len(output_script)) + output_script
tx += witness
tx += struct.pack('<I', 0)

tx_hex = tx.hex()
print(f"TX size: {len(tx)} bytes")

# Test and broadcast
stdout, stderr = run_cli(f"testmempoolaccept '[\"" + tx_hex + "\"]'")
if stdout:
    result = json.loads(stdout)
    r = result[0]
    print(f"Mempool accept: {r.get('allowed', False)}")
    if 'reject-reason' in r:
        print(f"Reject: {r['reject-reason']}")
    if r.get('allowed'):
        stdout2, stderr2 = run_cli(f"sendrawtransaction {tx_hex}")
        if stderr2:
            print(f"Broadcast error: {stderr2}")
        else:
            print()
            print("=" * 60)
            print("SUCCESS! BTC CLAIM BROADCAST")
            print("=" * 60)
            print(f"TXID: {stdout2}")
            print(f"https://mempool.space/signet/tx/{stdout2}")
            print()
            print("SECRETS REVEALED IN WITNESS:")
            print(f"  S_user: {S_USER.hex()}")
            print(f"  S_lp1:  {S_LP1.hex()}")
            print(f"  S_lp2:  {S_LP2.hex()}")
else:
    print(f"Error: {stderr}")
PYTHON_SCRIPT

scp $SSH_OPTS /tmp/sign_btc_claim_op3.py ubuntu@$OP3_IP:/tmp/

echo ""
echo "[4/4] Running signing script on OP3..."
ssh $SSH_OPTS ubuntu@$OP3_IP "python3 /tmp/sign_btc_claim_op3.py"

echo ""
echo "============================================================"
