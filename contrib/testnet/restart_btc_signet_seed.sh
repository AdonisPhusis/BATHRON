#!/bin/bash
# ==============================================================================
# restart_btc_signet_seed.sh - Restart BTC Signet on Seed, then restart burn daemon
# ==============================================================================
# Uses -conf= consistently (matching btc_header_daemon.sh)
set -uo pipefail

SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15"
SCP="scp -i $HOME/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SEED="ubuntu@57.131.33.151"

# Consistent flags matching header daemon
BTC_CONF="\$HOME/.bitcoin-signet/bitcoin.conf"
BTC_CLI_CMD="~/bitcoin-27.0/bin/bitcoin-cli -conf=$BTC_CONF"
BTC_DAEMON_CMD="~/bitcoin-27.0/bin/bitcoind -conf=$BTC_CONF"
BATHRON_CLI="~/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Step 1: Check current state ==="
$SSH $SEED "echo 'Connected to Seed'; $BTC_CLI_CMD getblockcount 2>/dev/null || echo 'BTC_DOWN'" || {
    echo "ERROR: Cannot SSH to Seed"; exit 1
}

echo ""
echo "=== Step 2: Ensure BTC Signet running ==="
$SSH $SEED "
# Check if already running
if $BTC_CLI_CMD getblockcount >/dev/null 2>&1; then
    echo \"BTC Signet already running (tip=\$($BTC_CLI_CMD getblockcount))\"
    exit 0
fi

echo 'BTC Signet is DOWN.'

# Kill all bitcoind + clean locks
echo 'Killing any zombie bitcoind...'
killall bitcoind 2>/dev/null || true
sleep 3

# Clean ALL possible lock locations
rm -f ~/.bitcoin-signet/signet/.lock ~/.bitcoin/signet/.lock 2>/dev/null
echo 'Lock files cleaned.'

# Show full config
echo 'Full bitcoin.conf:'
cat ~/.bitcoin-signet/bitcoin.conf
echo '---'

# Start
echo 'Starting bitcoind...'
$BTC_DAEMON_CMD -daemon 2>&1
echo \"Exit code: \$?\"
" || echo "(non-fatal error in step 2)"

echo ""
echo "=== Step 3: Wait for BTC Signet RPC (up to 3 min) ==="
BTC_TIP="NOT_READY"
for i in $(seq 1 36); do
    BTC_TIP=$($SSH $SEED "$BTC_CLI_CMD getblockcount 2>/dev/null || echo NOT_READY") || BTC_TIP="SSH_FAIL"
    if [ "$BTC_TIP" != "NOT_READY" ] && [ "$BTC_TIP" != "SSH_FAIL" ]; then
        echo "  BTC Signet is UP! tip=$BTC_TIP"
        break
    fi
    if [ $((i % 6)) -eq 0 ]; then
        echo "  Still waiting... ($((i*5))s)"
        $SSH $SEED 'tail -2 ~/.bitcoin-signet/signet/debug.log 2>/dev/null; tail -2 ~/.bitcoin/signet/debug.log 2>/dev/null' || true
    else
        echo "  Waiting... ($i/36)"
    fi
    sleep 5
done

if [ "$BTC_TIP" = "NOT_READY" ] || [ "$BTC_TIP" = "SSH_FAIL" ]; then
    echo ""
    echo "ERROR: BTC Signet still not responding. Checking state..."
    $SSH $SEED "
        echo '--- Process ---'
        pgrep -ax bitcoind || echo 'NO PROCESS'
        echo ''
        echo '--- Cookie files ---'
        ls -la ~/.bitcoin-signet/signet/.cookie 2>/dev/null || echo 'No cookie at ~/.bitcoin-signet/signet/'
        ls -la ~/.bitcoin/signet/.cookie 2>/dev/null || echo 'No cookie at ~/.bitcoin/signet/'
        echo ''
        echo '--- Debug log (last 20) ---'
        # Check both possible log locations
        if [ -f ~/.bitcoin-signet/signet/debug.log ]; then
            tail -20 ~/.bitcoin-signet/signet/debug.log
        elif [ -f ~/.bitcoin/signet/debug.log ]; then
            echo '(log at ~/.bitcoin/signet/debug.log)'
            tail -20 ~/.bitcoin/signet/debug.log
        else
            echo 'No debug log found'
        fi
    " || true
    exit 1
fi

echo ""
echo "=== Step 4: Copy + restart burn daemon ==="
$SCP ~/BATHRON/contrib/testnet/btc_burn_claim_daemon.sh $SEED:~/
echo "  Copied."

$SSH $SEED "
chmod +x ~/btc_burn_claim_daemon.sh

# Stop existing daemon
~/btc_burn_claim_daemon.sh stop 2>/dev/null || true
sleep 1

# Reset scan to before post-genesis burns
echo 'Resetting scan to 289200...'
$BATHRON_CLI setburnscanprogress 289200 '0000000000000000000000000000000000000000000000000000000000000000' 2>/dev/null || echo '(setburnscanprogress failed)'
echo '289200' > /tmp/btc_burn_claim_daemon.state
echo 'Reset done.'
echo ''

# Start daemon
echo 'Starting burn claim daemon...'
~/btc_burn_claim_daemon.sh start
sleep 5

echo ''
echo '=== Verification ==='
echo ''
echo '--- Daemon ---'
pgrep -af 'btc_burn_claim_daemon' | grep -v pgrep || echo 'NOT RUNNING'
echo ''
echo '--- Scan Progress ---'
$BATHRON_CLI getburnscanstatus 2>/dev/null | jq '{last_height, blocks_behind, synced}' || echo 'unavailable'
echo ''
echo '--- Burns in DB ---'
$BATHRON_CLI getbtcburnstats 2>/dev/null | jq '{total_records, total_pending, total_final}' || echo 'unavailable'
echo ''
echo '--- Last 15 log lines ---'
tail -15 /tmp/btc_burn_claim_daemon.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || echo 'no log'
"

echo ""
echo "=== Done ==="
