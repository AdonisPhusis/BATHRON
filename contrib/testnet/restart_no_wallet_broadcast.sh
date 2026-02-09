#!/bin/bash
# Restart all nodes with wallet broadcast disabled

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

get_cli_path() {
    local IP=$1
    if [ "$IP" = "57.131.33.151" ] || [ "$IP" = "162.19.251.75" ]; then
        echo "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
    else
        echo "/home/ubuntu/bathron-cli -testnet"
    fi
}

echo "=== Stopping all nodes ==="
for i in "${!VPS_NODES[@]}"; do
    IP="${VPS_NODES[$i]}"
    NAME="${NODE_NAMES[$i]}"
    CLI=$(get_cli_path "$IP")
    
    echo "Stopping $NAME..."
    $SSH ubuntu@$IP "$CLI stop" 2>&1 | grep -E "(stopping|not running)" || true
done

sleep 10

echo ""
echo "=== Deleting mempool.dat on all nodes ==="
for i in "${!VPS_NODES[@]}"; do
    IP="${VPS_NODES[$i]}"
    NAME="${NODE_NAMES[$i]}"
    
    echo "Deleting mempool.dat on $NAME..."
    $SSH ubuntu@$IP "rm -f ~/.bathron/testnet5/mempool.dat"
done

echo ""
echo "=== Starting all nodes with -walletbroadcast=0 ==="
for i in "${!VPS_NODES[@]}"; do
    IP="${VPS_NODES[$i]}"
    NAME="${NODE_NAMES[$i]}"
    
    echo "Starting $NAME..."
    if [ "$IP" = "57.131.33.151" ] || [ "$IP" = "162.19.251.75" ]; then
        $SSH ubuntu@$IP "cd ~/BATHRON-Core && ./src/bathrond -testnet -daemon -walletbroadcast=0" &
    else
        $SSH ubuntu@$IP "~/bathrond -testnet -daemon -walletbroadcast=0" &
    fi
done

wait
sleep 15

echo ""
echo "=== Verification ==="
for i in "${!VPS_NODES[@]}"; do
    IP="${VPS_NODES[$i]}"
    NAME="${NODE_NAMES[$i]}"
    CLI=$(get_cli_path "$IP")
    
    HEIGHT=$($SSH ubuntu@$IP "$CLI getblockcount" 2>&1 || echo "ERROR")
    MEMPOOL_SIZE=$($SSH ubuntu@$IP "$CLI getmempoolinfo 2>&1 | grep '\"size\"' | awk '{print \$2}' | tr -d ','")
    
    echo "$NAME: height=$HEIGHT mempool=$MEMPOOL_SIZE"
done

echo ""
echo "=== Waiting 90 seconds to see if blocks are produced ==="
START_HEIGHT=$($SSH ubuntu@${VPS_NODES[0]} "$(get_cli_path ${VPS_NODES[0]}) getblockcount")
echo "Starting height: $START_HEIGHT"

sleep 90

END_HEIGHT=$($SSH ubuntu@${VPS_NODES[0]} "$(get_cli_path ${VPS_NODES[0]}) getblockcount")
echo "Ending height: $END_HEIGHT"

if [ "$END_HEIGHT" -gt "$START_HEIGHT" ]; then
    echo "SUCCESS: Blocks are being produced!"
else
    echo "FAILED: No blocks produced"
fi
