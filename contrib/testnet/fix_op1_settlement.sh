#!/bin/bash
#
# fix_op1_settlement.sh - Wipe settlement DBs and sync from network
#
# This script fixes OP1 when it's stuck due to settlement validation issues.
# It wipes all consensus databases and lets the node resync from the network.
#

set -e

SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
OP1="57.131.33.152"
DATADIR="~/.bathron/testnet5"

echo "=== Fixing OP1 Settlement ==="
echo "This will wipe consensus DBs and resync from network"
echo ""

# Step 1: Stop daemon
echo "[1/4] Stopping daemon..."
$SSH ubuntu@$OP1 "pkill -9 bathrond 2>/dev/null || true; rm -f $DATADIR/.lock"
sleep 2

# Step 2: Wipe consensus databases (keep wallet)
echo "[2/4] Wiping consensus databases (keeping wallet)..."
$SSH ubuntu@$OP1 "
cd $DATADIR
rm -rf blocks chainstate evodb llmq settlementdb htlc btcheadersdb burnclaimdb hu_finality finality khu sporks settlement
rm -f peers.dat banlist.dat mempool.dat mncache.dat mnmetacache.dat
echo 'Wiped DBs:'
ls -la
"

# Step 3: Start daemon
echo "[3/4] Starting daemon..."
$SSH ubuntu@$OP1 "/home/ubuntu/bathrond -testnet -daemon"
sleep 15

# Step 4: Check status
echo "[4/4] Checking status..."
for i in 1 2 3 4 5; do
    HEIGHT=$($SSH ubuntu@$OP1 "/home/ubuntu/bathron-cli -testnet getblockcount 2>/dev/null" || echo "error")
    PEERS=$($SSH ubuntu@$OP1 "/home/ubuntu/bathron-cli -testnet getpeerinfo 2>/dev/null | grep -c '\"addr\"'" || echo "0")

    if [[ "$HEIGHT" != "error" ]]; then
        echo "  Height: $HEIGHT, Peers: $PEERS"
        if [[ "$HEIGHT" -gt 100 ]]; then
            echo ""
            echo "=== SUCCESS: OP1 is syncing ==="
            echo "Final height: $HEIGHT"
            exit 0
        fi
    else
        echo "  Still starting... (attempt $i/5)"
    fi
    sleep 10
done

# Final check
echo ""
echo "=== Final Status ==="
$SSH ubuntu@$OP1 "
/home/ubuntu/bathron-cli -testnet getblockcount 2>&1 || echo 'getblockcount failed'
/home/ubuntu/bathron-cli -testnet getpeerinfo 2>/dev/null | grep -c '\"addr\"' || echo 'getpeerinfo failed'
"

# Check logs for errors
echo ""
echo "=== Last 20 log lines ==="
$SSH ubuntu@$OP1 "tail -20 $DATADIR/debug.log | grep -E '(ERROR|error|HTLC|settlement|LEGACY)' || echo 'No relevant errors found'"
