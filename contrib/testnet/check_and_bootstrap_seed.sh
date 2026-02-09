#!/bin/bash
# Check Seed status and run genesis bootstrap if needed

set -e

SEED_IP="57.131.33.151"
SEED_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "════════════════════════════════════════════════════════════════"
echo "  Seed Node Status Check & Bootstrap"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 1. Check daemon status
echo "[1] Checking daemon status on Seed..."
DAEMON_STATUS=$($SSH_CMD $SEED_USER@$SEED_IP 'pgrep -a bathrond || echo "NOT_RUNNING"')
echo "$DAEMON_STATUS"
echo ""

# 2. If running, check blockcount
if echo "$DAEMON_STATUS" | grep -qv "NOT_RUNNING"; then
    echo "[2] Daemon is running, checking blockcount..."
    BLOCKCOUNT=$($SSH_CMD $SEED_USER@$SEED_IP '~/bathron-cli -testnet getblockcount 2>&1' || echo "ERROR")
    echo "Blockcount: $BLOCKCOUNT"
    
    if [ "$BLOCKCOUNT" = "ERROR" ] || [ -z "$BLOCKCOUNT" ]; then
        echo "[WARN] Daemon not responding, will restart"
        $SSH_CMD $SEED_USER@$SEED_IP 'pkill -9 bathrond 2>/dev/null || true'
        sleep 3
        DAEMON_STATUS="NOT_RUNNING"
    fi
fi

# 3. If not running, check if binary exists
if echo "$DAEMON_STATUS" | grep -q "NOT_RUNNING"; then
    echo "[3] Daemon not running, checking binary..."
    BINARY_PATH=$($SSH_CMD $SEED_USER@$SEED_IP 'ls -lh ~/BATHRON-Core/src/bathrond ~/bathrond 2>/dev/null | tail -2' || echo "NOT_FOUND")
    echo "$BINARY_PATH"
    
    if echo "$BINARY_PATH" | grep -q "BATHRON-Core"; then
        echo "[OK] Binary found, will start daemon"
    else
        echo "[ERROR] Binary not found at ~/BATHRON-Core/src/bathrond or ~/bathrond"
        exit 1
    fi
fi

# 4. Check btcspv backup
echo ""
echo "[4] Checking btcspv backup..."
BTCSPV_CHECK=$($SSH_CMD $SEED_USER@$SEED_IP 'ls -lh ~/btcspv_backup_latest.tar.gz 2>/dev/null' || echo "NOT_FOUND")
if echo "$BTCSPV_CHECK" | grep -q "NOT_FOUND"; then
    echo "[ERROR] btcspv backup not found at ~/btcspv_backup_latest.tar.gz"
    echo "        This is required for Block 1 TX_BTC_HEADERS"
    exit 1
else
    echo "[OK] btcspv backup found"
    echo "$BTCSPV_CHECK"
fi

# 5. Check BTC Signet
echo ""
echo "[5] Checking BTC Signet..."
BTC_STATUS=$($SSH_CMD $SEED_USER@$SEED_IP '~/bitcoin-27.0/bin/bitcoin-cli -datadir=~/.bitcoin-signet getblockcount 2>&1' || echo "ERROR")
if [ "$BTC_STATUS" = "ERROR" ] || [ -z "$BTC_STATUS" ]; then
    echo "[ERROR] BTC Signet not responding"
    echo "        Burn detection will fail"
    exit 1
else
    echo "[OK] BTC Signet tip: $BTC_STATUS"
fi

# 6. Check burn_claim_daemon script
echo ""
echo "[6] Checking burn_claim_daemon script..."
DAEMON_SCRIPT=$($SSH_CMD $SEED_USER@$SEED_IP 'ls -lh ~/btc_burn_claim_daemon.sh 2>/dev/null' || echo "NOT_FOUND")
if echo "$DAEMON_SCRIPT" | grep -q "NOT_FOUND"; then
    echo "[ERROR] btc_burn_claim_daemon.sh not found at ~/btc_burn_claim_daemon.sh"
    exit 1
else
    echo "[OK] Daemon script found"
fi

# 7. Run genesis bootstrap
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Ready to run genesis bootstrap"
echo "════════════════════════════════════════════════════════════════"
echo ""
read -p "Run genesis bootstrap on Seed? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted"
    exit 0
fi

echo ""
echo "[7] Running genesis bootstrap on Seed..."
echo "    This will take 2-3 minutes..."
echo ""

$SSH_CMD $SEED_USER@$SEED_IP 'cd ~/BATHRON-Core && ./contrib/testnet/genesis_bootstrap_seed.sh 2>&1' | tee /tmp/genesis_bootstrap.log | tail -100

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Bootstrap complete"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Full log saved to: /tmp/genesis_bootstrap.log"
echo ""
echo "Next steps:"
echo "1. Copy bootstrap chain to all nodes"
echo "2. Start all daemons with -noconnect until all synced"
echo "3. Remove -noconnect flag and verify network"
