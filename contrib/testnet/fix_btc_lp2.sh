#!/bin/bash
# Fix Bitcoin Core on LP2 (OP2) - Fix ownership issue

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP2_IP="57.131.33.214"
SSH="ssh $SSH_OPTS"

echo "=== Fixing Bitcoin Core on LP2 (OP2) ==="

echo ""
echo "Step 1: Stop any running bitcoind..."
$SSH ubuntu@$OP2_IP '
    BTC_CLI=~/bitcoin/bin/bitcoin-cli
    if pgrep -x bitcoind > /dev/null; then
        echo "Stopping bitcoind..."
        sudo $BTC_CLI -signet -datadir=~/.bitcoin-signet stop 2>/dev/null || true
        sleep 3
        sudo pkill -x bitcoind 2>/dev/null || true
        sleep 2
        if pgrep -x bitcoind > /dev/null; then
            echo "Force kill..."
            sudo kill -9 $(pgrep -x bitcoind) 2>/dev/null || true
            sleep 1
        fi
        echo "bitcoind stopped"
    else
        echo "bitcoind not running"
    fi
'

echo ""
echo "Step 2: Fix ownership of .bitcoin-signet directory..."
$SSH ubuntu@$OP2_IP '
    BTC_DIR=~/.bitcoin-signet
    if [ -d "$BTC_DIR" ]; then
        OWNER=$(stat -c "%U" $BTC_DIR)
        if [ "$OWNER" != "ubuntu" ]; then
            echo "Directory owned by $OWNER, fixing with sudo..."
            sudo chown -R ubuntu:ubuntu $BTC_DIR
            echo "Ownership fixed"
        else
            echo "Ownership already correct"
        fi
    else
        echo "Creating $BTC_DIR..."
        mkdir -p $BTC_DIR
    fi
    chmod 755 $BTC_DIR
    echo "Directory OK: $(ls -ld $BTC_DIR)"
'

echo ""
echo "Step 3: Create bitcoin.conf..."
$SSH ubuntu@$OP2_IP '
    BTC_DIR=~/.bitcoin-signet
    rm -f $BTC_DIR/bitcoin.conf
    cat > $BTC_DIR/bitcoin.conf << CONF
signet=1
server=1
txindex=1
[signet]
rpcuser=btcuser
rpcpassword=btcpass123
rpcallowip=127.0.0.1
CONF
    chmod 644 $BTC_DIR/bitcoin.conf
    echo "Created bitcoin.conf:"
    cat $BTC_DIR/bitcoin.conf
'

echo ""
echo "Step 4: Start bitcoind..."
$SSH ubuntu@$OP2_IP '
    BTC_BIN=~/bitcoin/bin
    BTC_DIR=~/.bitcoin-signet
    echo "Starting bitcoind..."
    $BTC_BIN/bitcoind -signet -datadir=$BTC_DIR -daemon
    echo "Started, waiting for RPC..."
'

echo ""
echo "Step 5: Wait for RPC ready..."
$SSH ubuntu@$OP2_IP '
    BTC_CLI=~/bitcoin/bin/bitcoin-cli
    BTC_DIR=~/.bitcoin-signet
    for i in $(seq 1 30); do
        if $BTC_CLI -signet -datadir=$BTC_DIR getblockchaininfo > /dev/null 2>&1; then
            echo "RPC ready!"
            break
        fi
        echo "  Waiting... ($i/30)"
        sleep 2
    done
'

echo ""
echo "Step 6: Create wallet..."
$SSH ubuntu@$OP2_IP '
    BTC_CLI=~/bitcoin/bin/bitcoin-cli
    BTC_DIR=~/.bitcoin-signet
    
    # Create wallet (ignore if exists)
    $BTC_CLI -signet -datadir=$BTC_DIR createwallet "lp2_wallet" 2>&1 | grep -v "already exists" || true
    
    # Load wallet
    $BTC_CLI -signet -datadir=$BTC_DIR loadwallet "lp2_wallet" 2>&1 | grep -v "already loaded" || true
    
    # Verify
    if $BTC_CLI -signet -datadir=$BTC_DIR -rpcwallet=lp2_wallet getwalletinfo > /dev/null 2>&1; then
        echo "Wallet lp2_wallet is ready"
    else
        echo "ERROR: Wallet not accessible"
        exit 1
    fi
'

echo ""
echo "Step 7: Generate address and save to btc.json..."
$SSH ubuntu@$OP2_IP '
    BTC_CLI=~/bitcoin/bin/bitcoin-cli
    BTC_DIR=~/.bitcoin-signet
    
    # Generate address
    ADDR=$($BTC_CLI -signet -datadir=$BTC_DIR -rpcwallet=lp2_wallet getnewaddress "lp_deposit" "bech32")
    echo "Address: $ADDR"
    
    # Get pubkey
    INFO=$($BTC_CLI -signet -datadir=$BTC_DIR -rpcwallet=lp2_wallet getaddressinfo "$ADDR")
    PUBKEY=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)[\"pubkey\"])")
    echo "Pubkey: $PUBKEY"
    
    # Save to BathronKey
    mkdir -p $HOME/.BathronKey
    cat > $HOME/.BathronKey/btc.json << BTCJSON
{
  "name": "dev_btc",
  "role": "liquidity_provider_2",
  "network": "signet",
  "address": "$ADDR",
  "pubkey": "$PUBKEY",
  "wallet": "lp2_wallet"
}
BTCJSON
    chmod 600 $HOME/.BathronKey/btc.json
    echo "Saved ~/.BathronKey/btc.json"
    cat $HOME/.BathronKey/btc.json
'

echo ""
echo "Step 8: Show sync status..."
$SSH ubuntu@$OP2_IP '
    BTC_CLI=~/bitcoin/bin/bitcoin-cli
    BTC_DIR=~/.bitcoin-signet
    $BTC_CLI -signet -datadir=$BTC_DIR getblockchaininfo | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"Chain: {d[\"chain\"]}\")
blocks = d[\"blocks\"]
headers = d[\"headers\"]
sync = blocks / headers * 100 if headers > 0 else 0
print(f\"Blocks: {blocks}/{headers} ({sync:.1f}%)\")
"
'

echo ""
echo "=== Bitcoin Core Fixed on LP2 ==="
