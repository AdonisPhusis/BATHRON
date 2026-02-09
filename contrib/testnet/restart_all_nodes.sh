#!/bin/bash
# Quick restart of all nodes

set -e

VPS_NODES=(
    "162.19.251.75"   # Core+SDK
    "57.131.33.152"   # OP1
    "57.131.33.214"   # OP2
    "51.75.31.44"     # OP3
)

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=== Starting daemons ==="
for IP in "${VPS_NODES[@]}"; do
    echo "Starting $IP..."
    if [ "$IP" = "162.19.251.75" ]; then
        $SSH ubuntu@$IP "cd ~/BATHRON-Core && ./src/bathrond -testnet -daemon" &
    else
        $SSH ubuntu@$IP "~/bathrond -testnet -daemon" &
    fi
done

wait
echo "All daemons started"
