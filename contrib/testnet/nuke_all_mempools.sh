#!/usr/bin/env bash
set -euo pipefail

# nuke_all_mempools.sh - Aggressively clear mempools on ALL nodes

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

NODES=(
    "57.131.33.151"   # Seed
    "57.131.33.152"   # OP1
    "57.131.33.214"   # OP2
    "51.75.31.44"     # OP3
)

echo "================================================"
echo "  NUKING ALL MEMPOOLS"
echo "================================================"
echo ""

# Step 1: Stop ALL daemons first
echo "STEP 1: Stopping all daemons..."
for IP in "${NODES[@]}"; do
    echo -n "  $IP: "
    ssh $SSH_OPTS ubuntu@$IP "~/bathron-cli -testnet stop 2>/dev/null; sleep 2; pkill -f bathrond 2>/dev/null || true" &
done
wait
sleep 5
echo "  Done."

# Step 2: Delete mempool.dat on ALL nodes
echo ""
echo "STEP 2: Deleting mempool.dat on all nodes..."
for IP in "${NODES[@]}"; do
    echo -n "  $IP: "
    ssh $SSH_OPTS ubuntu@$IP "rm -f ~/.bathron/testnet5/mempool.dat ~/.bathron/testnet5/.lock && echo 'cleared'" &
done
wait
echo "  Done."

# Step 3: Restart all daemons
echo ""
echo "STEP 3: Starting all daemons..."
for IP in "${NODES[@]}"; do
    echo -n "  $IP: "
    ssh $SSH_OPTS ubuntu@$IP "~/bathrond -testnet -daemon && echo 'started'" &
done
wait
echo "  Done."

# Step 4: Wait for initialization
echo ""
echo "STEP 4: Waiting 20s for initialization..."
sleep 20

# Step 5: Verify
echo ""
echo "STEP 5: Verifying mempool status..."
for IP in "${NODES[@]}"; do
    HEIGHT=$(ssh $SSH_OPTS ubuntu@$IP "~/bathron-cli -testnet getblockcount 2>/dev/null" || echo "error")
    MEMPOOL=$(ssh $SSH_OPTS ubuntu@$IP "~/bathron-cli -testnet getrawmempool 2>/dev/null | jq length" || echo "error")
    echo "  $IP: height=$HEIGHT, mempool=$MEMPOOL"
done

echo ""
echo "================================================"
echo "  MEMPOOL NUKE COMPLETE"
echo "================================================"
