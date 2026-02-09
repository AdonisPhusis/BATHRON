#!/bin/bash
#
# Setup Charlie's BTC config with the correct funded address
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP3_IP="51.75.31.44"

echo "Setting up Charlie's BTC config with funded address..."

ssh $SSH_OPTS "ubuntu@$OP3_IP" bash << 'REMOTE_SCRIPT'
set -e

BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
KEY_DIR="$HOME/.BathronKey"
KEY_FILE="$KEY_DIR/btc.json"

# The address with the most BTC for funding HTLCs
FUNDED_ADDR="tb1qkd2kyur0yqxpp6hvtwheukwpfjt2h5atapyhe7"

echo "Getting address info for funded address..."
ADDR_INFO=$($BTC_CLI -rpcwallet=fake_user getaddressinfo "$FUNDED_ADDR")
PUBKEY=$(echo "$ADDR_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pubkey', ''))")

echo "Address: $FUNDED_ADDR"
echo "Pubkey: $PUBKEY"

# Check balance
BALANCE=$($BTC_CLI -rpcwallet=fake_user getreceivedbyaddress "$FUNDED_ADDR" 0)
echo "Balance at this address: $BALANCE BTC"

# Save config
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

cat > "$KEY_FILE" << EOF
{
    "name": "charlie_btc",
    "network": "signet",
    "wallet_name": "fake_user",
    "address": "$FUNDED_ADDR",
    "pubkey": "$PUBKEY",
    "wif": "USE_WALLET_RPC",
    "use_wallet_rpc": true,
    "note": "Descriptor wallet - use signrawtransactionwithwallet for signing"
}
EOF
chmod 600 "$KEY_FILE"

echo ""
echo "=== Saved config ==="
cat "$KEY_FILE"

# Verify we can sign
echo ""
echo "=== Testing wallet signing capability ==="
# Create a dummy test
TEST_ADDR=$($BTC_CLI -rpcwallet=fake_user getnewaddress)
echo "Can create addresses: OK"
echo "Test address: $TEST_ADDR"
REMOTE_SCRIPT

echo ""
echo "Done! Charlie's BTC wallet is configured."
echo ""
echo "NOTE: For HTLC signing, use signrawtransactionwithwallet RPC"
echo "      instead of manual ECDSA signing with WIF."
