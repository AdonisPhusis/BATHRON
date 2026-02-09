#!/bin/bash
# Kill existing bootstrap and restart with correct BTC paths

set -e

SEED_IP="57.131.33.151"
SEED_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "════════════════════════════════════════════════════════════════"
echo "  Restarting Seed Genesis Bootstrap"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 1. Kill existing bootstrap daemon
echo "[1] Stopping existing bootstrap daemon..."
$SSH_CMD $SEED_USER@$SEED_IP 'pkill -9 bathrond 2>/dev/null || true'
sleep 3
echo "[OK] Daemon stopped"

# 2. Check BTC Signet path
echo ""
echo "[2] Finding BTC Signet datadir..."
BTC_DATADIR=$($SSH_CMD $SEED_USER@$SEED_IP 'find ~ -name "signet" -type d 2>/dev/null | grep -E "(bitcoin|BTCTESTNET)" | head -1')
if [ -z "$BTC_DATADIR" ]; then
    echo "[ERROR] BTC Signet datadir not found"
    echo "        Looking for common paths..."
    $SSH_CMD $SEED_USER@$SEED_IP 'ls -d ~/BTCTESTNET/data 2>/dev/null || ls -d ~/.bitcoin/signet 2>/dev/null || echo "NOT_FOUND"'
    exit 1
fi
echo "[OK] BTC Signet datadir: $BTC_DATADIR"

# 3. Verify BTC binary
echo ""
echo "[3] Finding BTC binary..."
BTC_CLI=$($SSH_CMD $SEED_USER@$SEED_IP 'find ~ -name "bitcoin-cli" -type f -executable 2>/dev/null | grep -E "bitcoin-27" | head -1')
if [ -z "$BTC_CLI" ]; then
    echo "[ERROR] bitcoin-cli not found"
    exit 1
fi
echo "[OK] BTC CLI: $BTC_CLI"

# 4. Test BTC connection
echo ""
echo "[4] Testing BTC Signet connection..."
BTC_TIP=$($SSH_CMD $SEED_USER@$SEED_IP "$BTC_CLI -datadir=$BTC_DATADIR getblockcount 2>&1")
if ! [[ "$BTC_TIP" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] BTC Signet not responding: $BTC_TIP"
    exit 1
fi
echo "[OK] BTC Signet tip: $BTC_TIP"

# 5. Run genesis bootstrap with correct paths
echo ""
echo "[5] Running genesis bootstrap..."
echo "    This will take 2-3 minutes..."
echo ""

# Create wrapper that sets BTC paths
$SSH_CMD $SEED_USER@$SEED_IP "cat > /tmp/run_bootstrap.sh << 'WRAPPER'
#!/bin/bash
export BTC_CLI='$BTC_CLI'
export BTC_DATADIR='$BTC_DATADIR'
cd ~/BATHRON-Core && ./contrib/testnet/genesis_bootstrap_seed.sh 2>&1
WRAPPER
chmod +x /tmp/run_bootstrap.sh
/tmp/run_bootstrap.sh" | tee /tmp/genesis_bootstrap.log | tail -100

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Bootstrap complete"
echo "════════════════════════════════════════════════════════════════"
echo "Full log: /tmp/genesis_bootstrap.log"
