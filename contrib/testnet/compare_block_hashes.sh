#!/bin/bash
# compare_block_hashes.sh - Compare block hashes at specific heights

set -e

SSH_KEY="~/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

HEIGHT=$1
if [ -z "$HEIGHT" ]; then
    echo "Usage: $0 <height>"
    exit 1
fi

echo "=== Block Hash Comparison at Height $HEIGHT ==="
echo ""

# Working nodes
NODES=(
    "162.19.251.75:~/bathron-cli -testnet:CoreSDK"
    "57.131.33.152:~/bathron-cli -testnet:OP1"
    "57.131.33.214:~/bathron-cli -testnet:OP2"
    "51.75.31.44:~/bathron-cli -testnet:OP3"
)

for node_info in "${NODES[@]}"; do
    IFS=':' read -r ip cli name <<< "$node_info"
    hash=$($SSH ubuntu@$ip "$cli getblockhash $HEIGHT 2>/dev/null" || echo "ERROR")
    echo "$name ($ip): $hash"
done
