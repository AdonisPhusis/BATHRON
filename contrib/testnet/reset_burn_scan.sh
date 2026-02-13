#!/bin/bash
# =============================================================================
# reset_burn_scan.sh - Reset burn scan progress on Seed and restart daemon
# Copies a reset script to Seed, executes it there, reports results.
# =============================================================================

RESCAN_HEIGHT="${1:-289200}"
SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCP="scp -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

echo "=== Reset Burn Scan to Height $RESCAN_HEIGHT ==="
echo ""

# 1. Create the remote script locally
cat > /tmp/reset_burn_scan_remote.sh << 'ENDSCRIPT'
#!/bin/bash
RESCAN_HEIGHT="$1"
CLI="$HOME/BATHRON-Core/src/bathron-cli -testnet"
BTC_CMD="$HOME/bitcoin-27.0/bin/bitcoin-cli -conf=$HOME/.bitcoin-signet/bitcoin.conf"
BTC_DAEMON="$HOME/bitcoin-27.0/bin/bitcoind -conf=$HOME/.bitcoin-signet/bitcoin.conf"

echo "[1] Stopping burn daemon..."
pkill -f 'btc_burn_claim_daemon' 2>/dev/null || true
sleep 2
echo "  Done."

echo "[2] Getting SPV hash for height $RESCAN_HEIGHT..."
BLOCK_HASH=$($CLI getbtcheader "$RESCAN_HEIGHT" 2>/dev/null | jq -r '.hash // empty')
if [ -n "$BLOCK_HASH" ]; then
    echo "  Hash: ${BLOCK_HASH:0:20}..."
    echo "[3] Setting scan progress via RPC..."
    RESULT=$($CLI setburnscanprogress "$RESCAN_HEIGHT" "$BLOCK_HASH" 2>&1)
    echo "  RPC result: $RESULT"
else
    echo "  WARNING: Cannot get SPV hash for height $RESCAN_HEIGHT"
    echo "  Checking if height is in range..."
    $CLI getbtcheadersstatus 2>/dev/null | jq '{tip_height, min_height: .spv_min_height}'
fi

echo "[4] Updating statefile..."
echo "$RESCAN_HEIGHT" > /tmp/btc_burn_claim_daemon.state
echo "  Statefile: $(cat /tmp/btc_burn_claim_daemon.state)"

echo "[5] Checking BTC Signet..."
BTC_TIP=$($BTC_CMD getblockcount 2>/dev/null)
if [ -n "$BTC_TIP" ]; then
    echo "  BTC Signet OK (tip=$BTC_TIP)"
else
    echo "  BTC Signet DOWN - attempting restart..."
    pkill -f 'bitcoind.*signet' 2>/dev/null || true
    sleep 2
    rm -f "$HOME/.bitcoin-signet/signet/.lock" 2>/dev/null
    $BTC_DAEMON -daemon 2>/dev/null
    echo "  Restart command sent. Waiting 30s..."
    sleep 30
    BTC_TIP=$($BTC_CMD getblockcount 2>/dev/null)
    if [ -n "$BTC_TIP" ]; then
        echo "  BTC Signet started (tip=$BTC_TIP)"
    else
        echo "  BTC Signet still down. Check: tail -20 ~/.bitcoin-signet/signet/debug.log"
        tail -10 "$HOME/.bitcoin-signet/signet/debug.log" 2>/dev/null | tail -5
    fi
fi

echo "[6] Starting burn daemon..."
chmod +x ~/btc_burn_claim_daemon.sh 2>/dev/null
~/btc_burn_claim_daemon.sh start 2>&1

echo ""
echo "[7] Verification..."
sleep 3
$CLI getburnscanstatus 2>/dev/null | jq '{last_height, blocks_behind, synced, status}'
echo ""
pgrep -af 'btc_burn_claim_daemon' | grep -v pgrep || echo "WARNING: daemon not running"
ENDSCRIPT

# 2. Copy scripts to Seed
echo "[Step 1] Copying scripts to Seed..."
$SCP /tmp/reset_burn_scan_remote.sh ubuntu@$SEED_IP:/tmp/ 2>/dev/null
$SCP ~/BATHRON/contrib/testnet/btc_burn_claim_daemon.sh ubuntu@$SEED_IP:~/ 2>/dev/null
echo "  Done."
echo ""

# 3. Execute on Seed
echo "[Step 2] Executing on Seed..."
$SSH ubuntu@$SEED_IP "chmod +x /tmp/reset_burn_scan_remote.sh && bash /tmp/reset_burn_scan_remote.sh $RESCAN_HEIGHT" 2>&1
EXIT_CODE=$?
echo ""
echo "Exit code: $EXIT_CODE"
