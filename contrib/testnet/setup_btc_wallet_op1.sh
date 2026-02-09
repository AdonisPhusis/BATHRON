#!/bin/bash
# =============================================================================
# setup_btc_wallet_op1.sh - Setup Bitcoin Signet wallet on OP1 for LP
# =============================================================================

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"

echo "============================================================"
echo "Setup Bitcoin Signet Wallet on OP1 (LP)"
echo "============================================================"
echo ""

# Copy setup script to OP1
cat << 'SETUP_SCRIPT' > /tmp/btc_setup_op1.sh
#!/bin/bash
set -e

BTC_DIR="/home/ubuntu/.bitcoin-signet"
BTC_BIN="/home/ubuntu/bitcoin/bin"
CLI="$BTC_BIN/bitcoin-cli -signet -datadir=$BTC_DIR"

echo "[1/5] Checking Bitcoin Core installation..."
if [ ! -f "$BTC_BIN/bitcoind" ]; then
    echo "ERROR: Bitcoin Core not installed at $BTC_BIN"
    exit 1
fi

echo "[2/5] Creating data directory..."
mkdir -p $BTC_DIR

# Create config if not exists
if [ ! -f "$BTC_DIR/bitcoin.conf" ]; then
    cat > $BTC_DIR/bitcoin.conf << 'CONF'
# Signet config
signet=1
server=1
txindex=1
[signet]
rpcuser=btcuser
rpcpassword=btcpass123
rpcallowip=127.0.0.1
CONF
fi

echo "[3/5] Starting Bitcoin Core..."
if pgrep -x bitcoind > /dev/null; then
    echo "  bitcoind already running"
else
    $BTC_BIN/bitcoind -signet -datadir=$BTC_DIR -daemon
    echo "  Started, waiting for init..."
    sleep 10
fi

# Wait for RPC
for i in {1..30}; do
    if $CLI getblockchaininfo > /dev/null 2>&1; then
        break
    fi
    echo "  Waiting for RPC... ($i/30)"
    sleep 2
done

echo "[4/5] Checking blockchain sync..."
$CLI getblockchaininfo | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  Chain: {d['chain']}\")
print(f\"  Blocks: {d['blocks']}\")
print(f\"  Headers: {d['headers']}\")
sync = d['blocks'] / d['headers'] * 100 if d['headers'] > 0 else 0
print(f\"  Sync: {sync:.1f}%\")
"

echo "[5/5] Setting up wallet..."
# Create or load wallet
$CLI createwallet "lp_wallet" false false "" false false 2>/dev/null || \
$CLI loadwallet "lp_wallet" 2>/dev/null || echo "  Wallet already loaded"

# Get address
ADDR=$($CLI -rpcwallet=lp_wallet getnewaddress "htlc_claim" "bech32")
echo ""
echo "============================================================"
echo "LP Bitcoin Wallet Ready"
echo "============================================================"
echo "Address: $ADDR"

# Get pubkey
INFO=$($CLI -rpcwallet=lp_wallet getaddressinfo "$ADDR")
PUBKEY=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['pubkey'])")
echo "Pubkey: $PUBKEY"

# Save to file
cat > ~/.BathronKey/btc.json << BTCJSON
{
  "name": "alice_btc",
  "role": "liquidity_provider",
  "network": "signet",
  "address": "$ADDR",
  "pubkey": "$PUBKEY",
  "wallet": "lp_wallet"
}
BTCJSON
chmod 600 ~/.BathronKey/btc.json

echo ""
echo "Saved to ~/.BathronKey/btc.json"
SETUP_SCRIPT

# Upload and execute
echo "[INFO] Uploading setup script to OP1..."
scp $SSH_OPTS /tmp/btc_setup_op1.sh ubuntu@$OP1_IP:/tmp/

echo "[INFO] Executing setup..."
ssh $SSH_OPTS ubuntu@$OP1_IP "chmod +x /tmp/btc_setup_op1.sh && /tmp/btc_setup_op1.sh"

echo ""
echo "============================================================"
echo "Done! Get pubkey with:"
echo "  ssh ubuntu@$OP1_IP 'cat ~/.BathronKey/btc.json'"
echo "============================================================"
