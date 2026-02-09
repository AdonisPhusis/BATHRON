#!/bin/bash
# Test the BTC gettxout RPC call with boolean parameter
# This verifies the fix for JSON boolean handling

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
OP1_IP="57.131.33.152"

echo "=== Testing BTC gettxout with boolean parameter ==="

# Sync the test script first
cat > /tmp/test_gettxout.py << 'PYEOF'
from sdk.chains.btc import BTCClient, BTCConfig
import json

config = BTCConfig()
client = BTCClient(config)

# Get a UTXO to test with
print("Getting a test UTXO...")
utxos = client.list_unspent()
if not utxos:
    print("No UTXOs available for testing")
    exit(1)

txid = utxos[0]["txid"]
vout = utxos[0]["vout"]
print(f"Testing with TXID: {txid}, vout: {vout}")

# Build the command to see what gets passed
cmd = client._build_cmd("gettxout", txid, vout, True)
print("Command:", " ".join(cmd))

# Check if boolean is properly converted
if "true" in cmd:
    print("BOOLEAN FIX VERIFIED: 'true' (lowercase) is in command")
elif "True" in cmd:
    print("BUG STILL PRESENT: 'True' (uppercase) in command - will fail JSON parsing")

# Test the RPC call with boolean True
print("\nCalling gettxout with include_mempool=True...")
try:
    result = client._call("gettxout", txid, vout, True)
    print(f"SUCCESS! Result type: {type(result)}")
    if result:
        print(f"UTXO exists (value: {result.get('value', '?')} BTC)")
    else:
        print("UTXO spent or not found (None returned)")
except Exception as e:
    print(f"ERROR: {e}")
PYEOF

scp -i "$SSH_KEY" /tmp/test_gettxout.py ubuntu@$OP1_IP:~/pna-lp/

ssh -i "$SSH_KEY" ubuntu@$OP1_IP 'cd ~/pna-lp && python3 test_gettxout.py'

# Cleanup
rm /tmp/test_gettxout.py
