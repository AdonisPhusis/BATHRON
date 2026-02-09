#!/bin/bash
# ==============================================================================
# network_mempool_wipe.sh - Wipe mempool across all testnet nodes
# ==============================================================================

set -e

VPS_NODES=(
    "57.131.33.151"   # Seed
    "162.19.251.75"   # Core+SDK
    "57.131.33.152"   # OP1
    "57.131.33.214"   # OP2
    "51.75.31.44"     # OP3
)

NODE_NAMES=(
    "Seed"
    "Core+SDK"
    "OP1"
    "OP2"
    "OP3"
)

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# CLI paths differ per node
get_cli_path() {
    local IP=$1
    if [ "$IP" = "57.131.33.151" ] || [ "$IP" = "162.19.251.75" ]; then
        echo "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
    else
        echo "/home/ubuntu/bathron-cli -testnet"
    fi
}

echo "=== NETWORK MEMPOOL WIPE ==="
echo "This will:"
echo "  1. Stop all daemons"
echo "  2. Delete mempool.dat on all nodes"
echo "  3. Restart all daemons"
echo ""

# Step 1: Stop all daemons
echo "=== Step 1: Stopping all daemons ==="
for i in "${!VPS_NODES[@]}"; do
    IP="${VPS_NODES[$i]}"
    NAME="${NODE_NAMES[$i]}"
    CLI=$(get_cli_path "$IP")
    
    echo "  Stopping $NAME ($IP)..."
    $SSH ubuntu@$IP "$CLI stop" 2>&1 | grep -E "(stopping|not running)" || true
done

echo "  Waiting 10 seconds for all daemons to stop..."
sleep 10

# Step 2: Delete mempool.dat
echo ""
echo "=== Step 2: Deleting mempool.dat ==="
for i in "${!VPS_NODES[@]}"; do
    IP="${VPS_NODES[$i]}"
    NAME="${NODE_NAMES[$i]}"
    
    echo "  Deleting mempool.dat on $NAME ($IP)..."
    $SSH ubuntu@$IP "rm -f ~/.bathron/testnet5/mempool.dat"
done

# Step 3: Restart all daemons
echo ""
echo "=== Step 3: Restarting all daemons ==="
for i in "${!VPS_NODES[@]}"; do
    IP="${VPS_NODES[$i]}"
    NAME="${NODE_NAMES[$i]}"
    
    echo "  Starting $NAME ($IP)..."
    if [ "$IP" = "57.131.33.151" ] || [ "$IP" = "162.19.251.75" ]; then
        $SSH ubuntu@$IP "cd ~/BATHRON-Core && ./src/bathrond -testnet -daemon" 2>&1 | grep "starting" || true
    else
        $SSH ubuntu@$IP "~/bathrond -testnet -daemon" 2>&1 | grep "starting" || true
    fi
done

echo "  Waiting 15 seconds for daemons to start..."
sleep 15

# Step 4: Verify
echo ""
echo "=== Step 4: Verification ==="
for i in "${!VPS_NODES[@]}"; do
    IP="${VPS_NODES[$i]}"
    NAME="${NODE_NAMES[$i]}"
    CLI=$(get_cli_path "$IP")
    
    echo "  $NAME ($IP):"
    HEIGHT=$($SSH ubuntu@$IP "$CLI getblockcount" 2>&1 || echo "ERROR")
    MEMPOOL=$($SSH ubuntu@$IP "$CLI getmempoolinfo 2>&1 | grep '\"size\"' | awk '{print \$2}' | tr -d ','")
    echo "    Height: $HEIGHT"
    echo "    Mempool size: $MEMPOOL"
done

echo ""
echo "=== Done! ==="
echo "Monitor block production with:"
echo "  watch './contrib/testnet/deploy_to_vps.sh --status'"
