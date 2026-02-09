#!/bin/bash
# Check bootstrap daemon status on Seed

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "════════════════════════════════════════════════════════════════"
echo "  Seed Bootstrap Status"
echo "════════════════════════════════════════════════════════════════"
echo ""

$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
# Check bootstrap daemon
CLI="/home/ubuntu/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet"

echo "=== Daemon Status ==="
if pgrep -f "bathrond.*bathron_bootstrap" >/dev/null; then
    echo "Daemon: RUNNING"
else
    echo "Daemon: STOPPED"
    echo ""
    echo "=== Last 30 lines of debug.log ==="
    tail -30 /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null || echo "Log not found"
    exit 1
fi

echo ""
echo "=== Blockchain Status ==="
HEIGHT=$($CLI getblockcount 2>&1)
echo "Height: $HEIGHT"

if [[ "$HEIGHT" =~ ^[0-9]+$ ]]; then
    echo ""
    echo "=== Last Block ==="
    HASH=$($CLI getblockhash $HEIGHT 2>/dev/null)
    $CLI getblock "$HASH" 1 2>/dev/null | jq -r '{height: .height, hash: .hash[:16], tx_count: (.tx | length), time: .time}'
    
    echo ""
    echo "=== Burn Claims ==="
    $CLI listburnclaims pending 10 2>/dev/null | jq -c 'length as $len | if $len > 0 then .[] else "No pending" end' | head -5
    $CLI listburnclaims final 10 2>/dev/null | jq -c 'length as $len | if $len > 0 then .[] else "No final" end' | head -5
    
    echo ""
    echo "=== Mempool ==="
    MEMPOOL=$($CLI getrawmempool 2>/dev/null | jq 'length')
    echo "Mempool TXs: $MEMPOOL"
    
    echo ""
    echo "=== Recent debug.log ==="
    tail -20 /tmp/bathron_bootstrap/testnet5/debug.log | grep -E "burn|claim|mint|MINT|ERROR|error" || echo "No burn/claim activity"
fi
REMOTE
