#!/bin/bash
# Start burn claim daemon on Seed
set -e

SSH="ssh -i ~/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=10"
SCP="scp -i ~/.ssh/id_ed25519_vps -o BatchMode=yes"
SEED_IP="57.131.33.151"

echo "=== Burn Claim Daemon Setup on Seed ==="

# Copy latest daemon script
echo "Copying btc_burn_claim_daemon.sh to Seed..."
$SCP ~/BATHRON/contrib/testnet/btc_burn_claim_daemon.sh ubuntu@$SEED_IP:~/

# Check current status and start if needed
echo ""
echo "Checking status..."
$SSH ubuntu@$SEED_IP '
    chmod +x ~/btc_burn_claim_daemon.sh

    # Check if running
    if pgrep -f "btc_burn_claim_daemon.sh" > /dev/null; then
        echo "Daemon already RUNNING"
        ~/btc_burn_claim_daemon.sh status 2>/dev/null | grep -E "Daemon:|Last scan:|Burns found:"
    else
        echo "Starting daemon..."
        ~/btc_burn_claim_daemon.sh start
        sleep 3
        ~/btc_burn_claim_daemon.sh status 2>/dev/null | head -20
    fi

    echo ""
    echo "=== All Burns in DB ==="
    echo "Height: $(~/bathron-cli -testnet getblockcount)"
    ~/bathron-cli -testnet listburnclaims all 100 2>/dev/null | jq -c ".[] | {btc_txid: .btc_txid[0:16], btc_height, claim_height, status: .db_status}" 2>/dev/null || echo "(none)"
    echo ""
    echo "Total claims: $(~/bathron-cli -testnet listburnclaims all 100 2>/dev/null | jq length 2>/dev/null || echo 0)"
    echo ""
    echo "=== getbtcburnstats ==="
    ~/bathron-cli -testnet getbtcburnstats 2>/dev/null | jq -c . || echo "(not available)"
    echo ""
    echo "=== getstate (M0 supply) ==="
    ~/bathron-cli -testnet getstate 2>/dev/null | jq "{m0_total: .settlement.m0_total, m0_vaulted: .settlement.m0_vaulted, m1_supply: .settlement.m1_supply}" || echo "(not available)"
    echo ""
    echo "=== getexplorerdata ==="
    ~/bathron-cli -testnet getexplorerdata 2>/dev/null | jq . || echo "(not available)"
    echo ""
    echo "=== Explorer Burns Section (curl localhost) ==="
    curl -s "http://localhost:8080/" 2>/dev/null | grep -oE "CLAIMABLE|PENDING|FINAL" | sort | uniq -c || echo "(explorer not running?)"
    echo ""
    echo "=== Check scan progress (DB) ==="
    ~/bathron-cli -testnet getburnscanstatus 2>/dev/null | jq . || echo "(RPC not available)"

    echo ""
    echo "=== Reset DB state to 289200 and rescan ==="
    ~/btc_burn_claim_daemon.sh stop 2>/dev/null || true
    sleep 2
    # Reset both DB and statefile
    ~/bathron-cli -testnet setburnscanprogress 289200 "0000000000000000000000000000000000000000000000000000000000000000" 2>/dev/null || echo "(setburnscanprogress failed)"
    echo "289200" > /tmp/btc_burn_claim_daemon.state
    ~/btc_burn_claim_daemon.sh once 2>&1 | tail -30

    echo ""
    echo "=== After scan - check burnclaimdb ==="
    ~/bathron-cli -testnet listburnclaims all 10 2>/dev/null | jq -c ".[] | {btc_txid: .btc_txid[0:16], btc_height, status: .db_status}" || echo "(none)"
'
