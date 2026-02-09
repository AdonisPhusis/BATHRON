#!/bin/bash
#
# Fix Charlie's BTC wallet - use the existing wallet with balance
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP3_IP="51.75.31.44"

echo "Fixing Charlie's BTC wallet on OP3..."

ssh $SSH_OPTS "ubuntu@$OP3_IP" bash << 'REMOTE_SCRIPT'
set -e

BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
KEY_DIR="$HOME/.BathronKey"
KEY_FILE="$KEY_DIR/btc.json"

echo "=== Checking available wallets ==="
echo "Loaded wallets:"
$BTC_CLI listwallets

echo ""
echo "=== Checking default wallet balance ==="
DEFAULT_BALANCE=$($BTC_CLI getbalance 2>/dev/null || echo "0")
echo "Default wallet balance: $DEFAULT_BALANCE BTC"

echo ""
echo "=== Getting addresses from default wallet ==="
# Try to get addresses from the default wallet
ADDRESSES=$($BTC_CLI listaddressgroupings 2>/dev/null || echo "[]")
echo "Address groupings: $ADDRESSES"

# Get first address with balance
ADDR=$(echo "$ADDRESSES" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d and len(d) > 0 and len(d[0]) > 0:
        print(d[0][0][0])
    else:
        print('')
except:
    print('')
")

if [ -z "$ADDR" ]; then
    echo "No address found in default wallet, trying to get new one..."
    ADDR=$($BTC_CLI getnewaddress "" bech32 2>/dev/null || echo "")
fi

if [ -z "$ADDR" ]; then
    echo "ERROR: Could not get address"
    exit 1
fi

echo "Using address: $ADDR"

# Get pubkey
ADDR_INFO=$($BTC_CLI getaddressinfo "$ADDR" 2>/dev/null || echo "{}")
PUBKEY=$(echo "$ADDR_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pubkey', ''))")

echo "Pubkey: $PUBKEY"

# Try to dump private key
WIF=$($BTC_CLI dumpprivkey "$ADDR" 2>/dev/null || echo "")

if [ -z "$WIF" ]; then
    echo ""
    echo "WARNING: Could not dump WIF from default wallet"
    echo "Checking if we have descriptor wallet..."

    # For descriptor wallets, we need different approach
    WALLET_INFO=$($BTC_CLI getwalletinfo 2>/dev/null || echo "{}")
    echo "Wallet info: $WALLET_INFO"

    # Try listdescriptors for modern wallets
    echo ""
    echo "Trying listdescriptors..."
    $BTC_CLI listdescriptors true 2>/dev/null | head -50 || echo "Not supported"
fi

# Save whatever we have
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

cat > "$KEY_FILE" << EOF
{
    "name": "charlie_btc",
    "network": "signet",
    "address": "$ADDR",
    "pubkey": "$PUBKEY",
    "wif": "${WIF:-NOT_AVAILABLE}"
}
EOF

chmod 600 "$KEY_FILE"

echo ""
echo "=== Final config ==="
cat "$KEY_FILE" | python3 -c "import sys,json; d=json.load(sys.stdin); w=d.get('wif',''); d['wif']=w[:8]+'...' if len(w)>10 else w; print(json.dumps(d, indent=2))"

# If WIF available, verify it
if [ -n "$WIF" ] && [ "$WIF" != "NOT_AVAILABLE" ]; then
    echo ""
    echo "WIF available - wallet is ready for signing!"
else
    echo ""
    echo "WARNING: WIF not available - may need to use signrawtransactionwithwallet instead"
fi
REMOTE_SCRIPT

echo ""
echo "Done!"
