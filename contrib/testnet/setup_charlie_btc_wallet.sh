#!/bin/bash
#
# Setup Charlie's BTC wallet config on OP3
# Extracts pubkey from existing Bitcoin Core wallet and saves to ~/.BathronKey/btc.json
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP3_IP="51.75.31.44"

BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

echo "Setting up Charlie's BTC wallet on OP3..."

# Get or create address
ssh $SSH_OPTS "ubuntu@$OP3_IP" bash << 'REMOTE_SCRIPT'
set -e

BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
KEY_DIR="$HOME/.BathronKey"
KEY_FILE="$KEY_DIR/btc.json"

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

# Check if wallet exists
if ! $BTC_CLI listwallets | grep -q "charlie_btc"; then
    echo "Creating charlie_btc wallet..."
    $BTC_CLI createwallet "charlie_btc" false false "" false true
fi

# Load wallet if not loaded
if ! $BTC_CLI listwallets | grep -q "charlie_btc"; then
    $BTC_CLI loadwallet "charlie_btc"
fi

# Get or create address
ADDR=$($BTC_CLI -rpcwallet=charlie_btc listaddressgroupings 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0][0][0] if d else '')" || echo "")

if [ -z "$ADDR" ]; then
    echo "Creating new address..."
    ADDR=$($BTC_CLI -rpcwallet=charlie_btc getnewaddress "" bech32)
fi

echo "Address: $ADDR"

# Get address info for pubkey
ADDR_INFO=$($BTC_CLI -rpcwallet=charlie_btc getaddressinfo "$ADDR")
PUBKEY=$(echo "$ADDR_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pubkey', ''))")

if [ -z "$PUBKEY" ]; then
    echo "ERROR: Could not get pubkey for address"
    exit 1
fi

echo "Pubkey: $PUBKEY"

# Get private key (WIF)
WIF=$($BTC_CLI -rpcwallet=charlie_btc dumpprivkey "$ADDR" 2>/dev/null || echo "")

if [ -z "$WIF" ]; then
    echo "WARNING: Could not dump private key (wallet may be watch-only)"
    WIF="NOT_AVAILABLE"
fi

# Save to JSON
cat > "$KEY_FILE" << EOF
{
    "name": "charlie_btc",
    "network": "signet",
    "address": "$ADDR",
    "pubkey": "$PUBKEY",
    "wif": "$WIF"
}
EOF

chmod 600 "$KEY_FILE"

echo ""
echo "BTC wallet config saved to $KEY_FILE"
cat "$KEY_FILE" | python3 -c "import sys,json; d=json.load(sys.stdin); d['wif']='***HIDDEN***'; print(json.dumps(d, indent=2))"
REMOTE_SCRIPT

echo ""
echo "Done! Charlie's BTC wallet is now configured."
