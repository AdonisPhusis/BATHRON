#!/usr/bin/env bash
set -euo pipefail

# clear_all_mempools.sh
# Clear mempools on all testnet nodes by restarting with -zapwallettxes

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

NODES=(
    "57.131.33.151"   # Seed
    "162.19.251.75"   # Core+SDK
    "57.131.33.152"   # OP1
    "57.131.33.214"   # OP2
    "51.75.31.44"     # OP3
)

echo "================================================"
echo "  Clearing Mempools on All Testnet Nodes"
echo "================================================"
echo ""

for IP in "${NODES[@]}"; do
    echo "[$IP] Stopping daemon and clearing mempool..."
    ssh $SSH_OPTS ubuntu@$IP "~/bathron-cli -testnet stop 2>/dev/null || true; sleep 3; rm -f ~/.bathron/testnet5/mempool.dat; rm -f ~/.bathron/testnet5/.lock"
done

echo ""
echo "All daemons stopped. Waiting 5s..."
sleep 5

echo ""
echo "Starting daemons..."
for IP in "${NODES[@]}"; do
    echo "[$IP] Starting daemon..."
    ssh $SSH_OPTS ubuntu@$IP "~/bathrond -testnet -daemon 2>/dev/null" &
done
wait

echo ""
echo "Waiting 15s for daemons to initialize..."
sleep 15

echo ""
echo "Checking mempool status..."
for IP in "${NODES[@]}"; do
    MEMPOOL=$(ssh $SSH_OPTS ubuntu@$IP "~/bathron-cli -testnet getrawmempool 2>/dev/null | jq length" 2>/dev/null || echo "error")
    HEIGHT=$(ssh $SSH_OPTS ubuntu@$IP "~/bathron-cli -testnet getblockcount" 2>/dev/null || echo "error")
    echo "  $IP: height=$HEIGHT, mempool=$MEMPOOL"
done

echo ""
echo "================================================"
echo "  Mempool Clear Complete"
echo "================================================"
