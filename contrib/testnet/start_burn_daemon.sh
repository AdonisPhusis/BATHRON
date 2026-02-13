#!/bin/bash
# ==============================================================================
# start_burn_daemon.sh - Start/restart burn claim daemon on Seed
# ==============================================================================
# Usage:
#   ./start_burn_daemon.sh           # Check BTC Signet, reset scan, start daemon
#   ./start_burn_daemon.sh status    # Just show status
#   ./start_burn_daemon.sh rescan    # Reset scan to 289200 and restart
#
# What it does:
#   1. Copies latest btc_burn_claim_daemon.sh to Seed
#   2. Checks BTC Signet - restarts if down
#   3. Resets scan progress if needed (rescan mode or first run)
#   4. Starts the burn claim daemon in background
# ==============================================================================

SSH="ssh -i ~/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCP="scp -i ~/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SEED_IP="57.131.33.151"
CLI="~/BATHRON-Core/src/bathron-cli -testnet"
BTC_CMD="~/bitcoin-27.0/bin/bitcoin-cli -datadir=~/.bitcoin-signet"
BTC_DAEMON="~/bitcoin-27.0/bin/bitcoind -conf=~/.bitcoin-signet/bitcoin.conf"

CMD="${1:-start}"

case "$CMD" in
status)
    echo "=== Burn Daemon Status on Seed ==="
    $SSH ubuntu@$SEED_IP "
        echo '--- Daemon Process ---'
        pgrep -af 'btc_burn_claim_daemon' || echo 'NOT RUNNING'
        echo ''
        echo '--- BTC Signet ---'
        $BTC_CMD getblockcount 2>/dev/null && echo 'OK' || echo 'UNREACHABLE'
        echo ''
        echo '--- Scan Progress ---'
        $CLI getburnscanstatus 2>/dev/null | jq . || echo 'RPC unavailable'
        echo ''
        echo '--- Burnclaimdb ---'
        $CLI getbtcburnstats 2>/dev/null | jq '{total_records, total_pending, total_final}' || echo 'RPC unavailable'
        echo ''
        echo '--- Last 10 Log Lines ---'
        tail -10 /tmp/btc_burn_claim_daemon.log 2>/dev/null || echo 'No log'
    " 2>/dev/null
    ;;

start|rescan)
    echo "=== Burn Claim Daemon Setup on Seed ==="
    echo ""

    # 1. Copy latest daemon script
    echo "[1/5] Copying btc_burn_claim_daemon.sh to Seed..."
    $SCP ~/BATHRON/contrib/testnet/btc_burn_claim_daemon.sh ubuntu@$SEED_IP:~/
    echo "  Done."
    echo ""

    # 2-5. Run setup on Seed
    RESCAN_FLAG="false"
    if [ "$CMD" = "rescan" ]; then
        RESCAN_FLAG="true"
    fi

    $SSH ubuntu@$SEED_IP "
        chmod +x ~/btc_burn_claim_daemon.sh

        # --- 2. Check BTC Signet ---
        echo '[2/5] Checking BTC Signet...'
        if $BTC_CMD getblockcount >/dev/null 2>&1; then
            BTC_TIP=\$($BTC_CMD getblockcount)
            echo \"  BTC Signet OK (tip=\$BTC_TIP)\"
        else
            echo '  BTC Signet DOWN - restarting...'
            pkill -f 'bitcoind.*bitcoin-signet' 2>/dev/null || true
            sleep 2
            $BTC_DAEMON -daemon 2>&1 || true
            echo '  Waiting for BTC Signet to start (up to 60s)...'
            BTC_STARTED=false
            for i in \$(seq 1 30); do
                if $BTC_CMD getblockcount >/dev/null 2>&1; then
                    BTC_TIP=\$($BTC_CMD getblockcount)
                    echo \"  BTC Signet started (tip=\$BTC_TIP)\"
                    BTC_STARTED=true
                    break
                fi
                sleep 2
            done
            if [ \"\$BTC_STARTED\" = 'false' ]; then
                echo '  ERROR: BTC Signet failed to start after 60s!'
                echo '  Check: ls ~/.bitcoin-signet/bitcoin.conf'
                ls -la ~/.bitcoin-signet/bitcoin.conf 2>/dev/null || echo '  bitcoin.conf NOT FOUND'
                echo '  Check: ~/.bitcoin-signet/signet/debug.log tail'
                tail -5 ~/.bitcoin-signet/signet/debug.log 2>/dev/null || echo '  No debug log'
                exit 1
            fi
        fi
        echo ''

        # --- 3. Check BATHRON node ---
        echo '[3/5] Checking BATHRON node...'
        BATHRON_TIP=\$($CLI getblockcount 2>/dev/null || echo '-1')
        if [ \"\$BATHRON_TIP\" = '-1' ]; then
            echo '  ERROR: BATHRON node unreachable!'
            exit 1
        fi
        echo \"  BATHRON OK (tip=\$BATHRON_TIP)\"
        echo ''

        # --- 4. Stop existing daemon + reset scan if needed ---
        echo '[4/5] Preparing daemon...'
        ~/btc_burn_claim_daemon.sh stop 2>/dev/null || true
        sleep 1

        SCAN_STATUS=\$($CLI getburnscanstatus 2>/dev/null || echo '{}')
        LAST_HEIGHT=\$(echo \"\$SCAN_STATUS\" | jq -r '.last_height // 0')
        echo \"  Current scan progress: \$LAST_HEIGHT\"

        if [ \"$RESCAN_FLAG\" = 'true' ] || [ \"\$LAST_HEIGHT\" = '0' ]; then
            echo '  Resetting scan to height 289200 (before post-genesis burns)...'
            $CLI setburnscanprogress 289200 '0000000000000000000000000000000000000000000000000000000000000000' 2>/dev/null || echo '  (setburnscanprogress not available, using statefile)'
            echo '289200' > /tmp/btc_burn_claim_daemon.state
            echo '  Reset done.'
        else
            echo \"  Keeping existing progress at \$LAST_HEIGHT\"
        fi
        echo ''

        # --- 5. Start daemon ---
        echo '[5/5] Starting burn claim daemon...'
        ~/btc_burn_claim_daemon.sh start
        sleep 3

        echo ''
        echo '=== Post-Start Verification ==='
        echo ''

        # Show daemon status
        pgrep -af 'btc_burn_claim_daemon' | grep -v pgrep || echo 'WARNING: daemon not found in process list'
        echo ''

        # Show scan status
        echo '--- Scan Progress ---'
        $CLI getburnscanstatus 2>/dev/null | jq '{last_height, blocks_behind, synced}' || echo 'RPC unavailable'
        echo ''

        # Show burnclaimdb
        echo '--- Burns in DB ---'
        $CLI getbtcburnstats 2>/dev/null | jq '{total_records, total_pending, total_final}' || echo 'RPC unavailable'
        echo ''

        # Show last log entries (daemon should have done initial scan)
        echo '--- Recent Log ---'
        tail -15 /tmp/btc_burn_claim_daemon.log 2>/dev/null | grep -v '^\[0;' || echo 'No log yet'
    " 2>/dev/null
    ;;

rescan-from)
    # Reset scan to a specific height, restart BTC Signet if needed, restart daemon
    RESCAN_HEIGHT="${2:-289200}"
    echo "=== Resetting Burn Scan to Height $RESCAN_HEIGHT ==="

    # Step 1: Copy daemon script
    echo "[1/5] Copying btc_burn_claim_daemon.sh to Seed..."
    $SCP ~/BATHRON/contrib/testnet/btc_burn_claim_daemon.sh ubuntu@$SEED_IP:~/ 2>/dev/null
    echo "  Done."

    # Step 2: Stop daemon + reset scan progress
    echo "[2/5] Stopping daemon and resetting scan progress..."
    $SSH ubuntu@$SEED_IP "
        ~/btc_burn_claim_daemon.sh stop 2>/dev/null || true
        pkill -f 'btc_burn_claim_daemon' 2>/dev/null || true
        sleep 1
        # Get real BTC block hash from SPV DB for the target height
        BLOCK_HASH=\$($CLI getbtcheader $RESCAN_HEIGHT 2>/dev/null | jq -r '.hash // empty')
        if [ -n \"\$BLOCK_HASH\" ]; then
            echo \"  Got SPV hash for height $RESCAN_HEIGHT: \${BLOCK_HASH:0:16}...\"
            $CLI setburnscanprogress $RESCAN_HEIGHT \"\$BLOCK_HASH\" 2>/dev/null && echo '  RPC reset OK' || echo '  RPC reset failed'
        else
            echo '  Cannot get SPV hash, RPC reset skipped'
        fi
        echo '$RESCAN_HEIGHT' > /tmp/btc_burn_claim_daemon.state
        echo '  Statefile set to $RESCAN_HEIGHT'
    " 2>/dev/null || echo "  Warning: reset command had issues"

    # Step 3: Check/restart BTC Signet (fire-and-forget restart, wait locally)
    echo "[3/5] Checking BTC Signet..."
    BTC_STATUS=$($SSH ubuntu@$SEED_IP "$BTC_CMD getblockcount 2>&1 || echo FAIL" 2>/dev/null)
    if echo "$BTC_STATUS" | grep -q "FAIL\|error\|Error"; then
        echo "  BTC Signet DOWN - sending restart command..."
        $SSH ubuntu@$SEED_IP "pkill -f 'bitcoind.*signet' 2>/dev/null; sleep 2; rm -f ~/.bitcoin-signet/signet/.lock 2>/dev/null; nohup $BTC_DAEMON -daemon > /tmp/btc_signet_start.log 2>&1 &; echo STARTED" 2>/dev/null || true
        echo "  Waiting 90s for BTC Signet to start..."
        sleep 90
        BTC_STATUS=$($SSH ubuntu@$SEED_IP "$BTC_CMD getblockcount 2>&1 || echo FAIL" 2>/dev/null)
        if echo "$BTC_STATUS" | grep -q "FAIL\|error\|Error"; then
            echo "  WARNING: BTC Signet still unreachable."
            echo "  Checking startup log..."
            $SSH ubuntu@$SEED_IP "tail -5 /tmp/btc_signet_start.log 2>/dev/null; tail -5 ~/.bitcoin-signet/signet/debug.log 2>/dev/null | tail -3" 2>/dev/null || true
            echo "  Daemon will retry when BTC comes online."
        else
            echo "  BTC Signet OK (tip=$BTC_STATUS)"
        fi
    else
        echo "  BTC Signet OK (tip=$BTC_STATUS)"
    fi

    # Step 4: Start daemon
    echo "[4/5] Starting burn claim daemon..."
    $SSH ubuntu@$SEED_IP "chmod +x ~/btc_burn_claim_daemon.sh; ~/btc_burn_claim_daemon.sh start 2>&1; sleep 3; pgrep -af 'btc_burn_claim_daemon' | grep -v pgrep || echo 'WARNING: daemon not found'" 2>/dev/null || echo "  Warning: start had issues"

    # Step 5: Verify
    echo "[5/5] Verifying..."
    sleep 2
    $SSH ubuntu@$SEED_IP "
        echo '--- Scan Progress ---'
        $CLI getburnscanstatus 2>/dev/null | jq '{last_height, blocks_behind, synced, status}' || echo 'RPC unavailable'
        echo ''
        echo '--- Burns in DB ---'
        $CLI getbtcburnstats 2>/dev/null | jq '{total_records, total_pending, total_final}' || echo 'RPC unavailable'
        echo ''
        echo '--- Last Log ---'
        tail -5 /tmp/btc_burn_claim_daemon.log 2>/dev/null || echo 'No log'
    " 2>/dev/null || echo "  Status check failed"
    ;;

*)
    echo "Usage: $0 [start|status|rescan|rescan-from <height>]"
    echo "  start        - Start daemon (restart BTC Signet if needed)"
    echo "  status       - Show daemon status"
    echo "  rescan       - Reset scan to 289200 and restart daemon"
    echo "  rescan-from  - Reset scan to specific height (default 289200)"
    exit 1
    ;;
esac
