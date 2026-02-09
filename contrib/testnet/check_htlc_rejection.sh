#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

TXID="${1:-e827249a4a6740c82ce9ff4625f5a24561c20b3ddc91a0204ceb2c4c6f97d155}"

echo "[$(date +%H:%M:%S)] Checking HTLC TX rejection: ${TXID:0:16}..."
echo ""

declare -A NODES=(
    ["Seed"]="57.131.33.151"
    ["Core"]="162.19.251.75"
)

for NODE_NAME in "${!NODES[@]}"; do
    IP="${NODES[$NODE_NAME]}"
    echo "=== $NODE_NAME ($IP) ==="
    
    # Check mempool
    echo "  Mempool status:"
    $SSH ubuntu@$IP "~/bathron-cli -testnet getmempoolinfo 2>&1" | head -10
    
    # Check if TX is rejected in logs
    echo ""
    echo "  Checking for rejection/validation errors (last 200 lines):"
    $SSH ubuntu@$IP "grep -E 'HTLC|TX_HTLC|htlc|reject|invalid|bad-' ~/.bathron/testnet5/debug.log | tail -50 | grep -v 'UpdateTip\|addcon\|connection'" || echo "  No rejection messages found"
    
    echo ""
    echo "  Block production (last 5 blocks):"
    HEIGHT=$($SSH ubuntu@$IP '~/bathron-cli -testnet getblockcount')
    echo "  Current height: $HEIGHT"
    
    # Check last few block times
    for ((i=0; i<5; i++)); do
        H=$((HEIGHT - i))
        $SSH ubuntu@$IP "~/bathron-cli -testnet getblock \$(~/bathron-cli -testnet getblockhash $H) | grep -E 'height|time' | head -2"
    done
    
    echo ""
    echo "---"
    echo ""
done

echo "[$(date +%H:%M:%S)] Check complete"
