#!/bin/bash
#
# Check all BTC wallets on OP3 and configure the one with balance
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP3_IP="51.75.31.44"

echo "Checking BTC wallets on OP3..."

ssh $SSH_OPTS "ubuntu@$OP3_IP" bash << 'REMOTE_SCRIPT'
set -e

BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
KEY_DIR="$HOME/.BathronKey"
KEY_FILE="$KEY_DIR/btc.json"

echo "=== All wallets ==="
WALLETS=$($BTC_CLI listwallets)
echo "$WALLETS"

echo ""
echo "=== Checking fake_user wallet ==="
FAKE_USER_BALANCE=$($BTC_CLI -rpcwallet=fake_user getbalance 2>/dev/null || echo "ERROR")
echo "fake_user balance: $FAKE_USER_BALANCE BTC"

echo ""
echo "=== fake_user addresses ==="
$BTC_CLI -rpcwallet=fake_user listaddressgroupings 2>/dev/null || echo "No groupings"

# Get address from fake_user
ADDR=$($BTC_CLI -rpcwallet=fake_user listaddressgroupings 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d and len(d) > 0 and len(d[0]) > 0:
        print(d[0][0][0])
    else:
        print('')
except:
    print('')
" || echo "")

if [ -z "$ADDR" ]; then
    echo "Trying getnewaddress..."
    ADDR=$($BTC_CLI -rpcwallet=fake_user getnewaddress "" bech32 2>/dev/null || echo "")
fi

echo "Address to use: $ADDR"

if [ -n "$ADDR" ]; then
    echo ""
    echo "=== Getting address info ==="
    ADDR_INFO=$($BTC_CLI -rpcwallet=fake_user getaddressinfo "$ADDR" 2>/dev/null || echo "{}")
    PUBKEY=$(echo "$ADDR_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('pubkey', d.get('scriptPubKey', '')))")
    echo "Pubkey: $PUBKEY"

    # Check wallet type
    WALLET_INFO=$($BTC_CLI -rpcwallet=fake_user getwalletinfo 2>/dev/null || echo "{}")
    IS_DESCRIPTOR=$(echo "$WALLET_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('descriptors', False))")
    echo "Descriptor wallet: $IS_DESCRIPTOR"

    # For descriptor wallets, get the xpriv
    if [ "$IS_DESCRIPTOR" == "True" ]; then
        echo ""
        echo "=== Descriptor wallet - getting private key via listdescriptors ==="
        # Get the first receiving descriptor with private key
        DESCS=$($BTC_CLI -rpcwallet=fake_user listdescriptors true 2>/dev/null || echo '{"descriptors":[]}')
        echo "Descriptors (truncated):"
        echo "$DESCS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for desc in d.get('descriptors', [])[:3]:
    s = str(desc)
    if len(s) > 100:
        s = s[:100] + '...'
    print(s)
"
    fi

    # Try dumpprivkey anyway
    echo ""
    echo "=== Trying dumpprivkey ==="
    WIF=$($BTC_CLI -rpcwallet=fake_user dumpprivkey "$ADDR" 2>&1 || echo "FAILED")
    if [[ "$WIF" == *"FAILED"* ]] || [[ "$WIF" == *"Error"* ]]; then
        echo "dumpprivkey failed: $WIF"
        WIF=""
    else
        echo "WIF obtained: ${WIF:0:10}..."
    fi

    # Save config
    mkdir -p "$KEY_DIR"
    chmod 700 "$KEY_DIR"

    cat > "$KEY_FILE" << EOF
{
    "name": "fake_user",
    "network": "signet",
    "wallet_name": "fake_user",
    "address": "$ADDR",
    "pubkey": "$PUBKEY",
    "wif": "${WIF:-USE_WALLET_RPC}",
    "use_wallet_rpc": true
}
EOF
    chmod 600 "$KEY_FILE"

    echo ""
    echo "=== Saved config ==="
    cat "$KEY_FILE" | python3 -c "import sys,json; d=json.load(sys.stdin); w=d.get('wif',''); d['wif']=w[:8]+'...' if len(w)>10 else w; print(json.dumps(d, indent=2))"
fi
REMOTE_SCRIPT

echo ""
echo "Done!"
