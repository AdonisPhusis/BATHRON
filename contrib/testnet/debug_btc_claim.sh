#!/bin/bash
# Debug BTC HTLC claim transaction

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP3_IP="51.75.31.44"

# Get the signed TX from OP1
SIGNED_TX=$(ssh $SSH_OPTS ubuntu@57.131.33.152 "cat /tmp/signed_btc_claim.hex 2>/dev/null")

echo "============================================================"
echo "DEBUG BTC HTLC CLAIM"
echo "============================================================"
echo ""

cat << SCRIPT > /tmp/debug_claim.py
#!/usr/bin/env python3
import subprocess
import json
import hashlib

CLI = "/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

def run_cli(cmd):
    result = subprocess.run(f"{CLI} {cmd}", shell=True, capture_output=True, text=True)
    return result.stdout.strip(), result.stderr.strip()

TXID = "d1c656881e844e6f9ef916ef426abdf451cdd6851cd17dff8d27497c15b44262"

print("=== UTXO Check ===")
out, err = run_cli(f"gettxout {TXID} 0")
if out:
    data = json.loads(out)
    print(f"  Value: {data['value']} BTC")
    print(f"  Confirmations: {data['confirmations']}")
    print(f"  ScriptPubKey: {data['scriptPubKey']['hex']}")
else:
    print(f"  UTXO not found or already spent")
    print(f"  Error: {err}")

print("")
print("=== Script Hash Verification ===")
HTLC_SCRIPT = bytes.fromhex("63a82013ccc7087668869e62146ea776614c6ce10811c926ad583bda3d4a40864e05c088a820bdb432bb6537578e70c37da156b1b38ff7b94fd0c8f194d24f51856fdd2a409d88a820ecfcb6c5a30a876e665a1b7ce99dc1d8a04f38790584dd56cf118e02af5f4df28821039b6d9375838d5d4ad49e5fe75e3c8820dadbd9e601da39caa08132d2ecb8e7d5ac670190b275210370eeb81b88d20c6a9d3cace87c73698998077bc0b4ddf31b10f901e3f79a4378ac68")

script_hash = hashlib.sha256(HTLC_SCRIPT).digest()
expected_spk = "0020" + script_hash.hex()
print(f"  Expected scriptPubKey: {expected_spk}")

print("")
print("=== Decode signed TX ===")
TX_HEX = "$SIGNED_TX"
if TX_HEX:
    out, err = run_cli(f"decoderawtransaction {TX_HEX}")
    if out:
        tx = json.loads(out)
        print(f"  TXID: {tx['txid']}")
        print(f"  Size: {tx['size']} vbytes")
        for i, vin in enumerate(tx['vin']):
            print(f"  Input {i}: {vin['txid'][:20]}... vout {vin['vout']}")
            if 'txinwitness' in vin:
                print(f"    Witness items: {len(vin['txinwitness'])}")
                for j, w in enumerate(vin['txinwitness']):
                    print(f"      [{j}] {w[:40]}..." if len(w) > 40 else f"      [{j}] {w}")
    else:
        print(f"  Decode error: {err}")
else:
    print("  No signed TX available")

print("")
print("=== Test mempool accept ===")
if TX_HEX:
    out, err = run_cli(f"testmempoolaccept '[\"{TX_HEX}\"]'")
    if out:
        result = json.loads(out)
        for r in result:
            print(f"  Allowed: {r.get('allowed', False)}")
            if 'reject-reason' in r:
                print(f"  Reject reason: {r['reject-reason']}")
    else:
        print(f"  Error: {err}")
SCRIPT

scp $SSH_OPTS /tmp/debug_claim.py ubuntu@$OP3_IP:/tmp/
ssh $SSH_OPTS ubuntu@$OP3_IP "python3 /tmp/debug_claim.py"
