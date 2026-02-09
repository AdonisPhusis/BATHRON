#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

declare -A NODES
NODES["Seed"]="57.131.33.151:BATHRON-Core"
NODES["CoreSDK"]="162.19.251.75:BATHRON-Core"

echo "Checking M1 receipts across all nodes..."
echo ""

for node_name in "${!NODES[@]}"; do
    IFS=':' read -r ip node_type <<< "${NODES[$node_name]}"
    
    if [[ "$node_type" == "BATHRON-Core" ]]; then
        CLI="\$HOME/BATHRON-Core/src/bathron-cli"
    else
        CLI="\$HOME/bathron-cli"
    fi
    
    echo "=========================================="
    echo "Node: $node_name ($ip)"
    echo "=========================================="
    
    echo "1. Wallet M1 balance:"
    M1_BALANCE=$(ssh $SSH_OPTS ubuntu@$ip "$CLI -testnet getbalance '*' 0 false 'M1'" 2>&1 || echo "ERROR")
    echo "   $M1_BALANCE"
    echo ""
    
    echo "2. M1 receipts (getwalletstate):"
    WALLET_STATE=$(ssh $SSH_OPTS ubuntu@$ip "$CLI -testnet getwalletstate true" 2>&1)
    M1_RECEIPTS=$(echo "$WALLET_STATE" | jq -r '.m1_receipts' 2>/dev/null || echo "null")
    
    if [[ "$M1_RECEIPTS" == "null" || "$M1_RECEIPTS" == "[]" ]]; then
        echo "   No M1 receipts in wallet"
    else
        echo "$M1_RECEIPTS" | jq -r '.[] | "   Receipt: \(.outpoint) = \(.amount) M1"'
    fi
    echo ""
    
    echo "3. listunspent M1:"
    UNSPENT=$(ssh $SSH_OPTS ubuntu@$ip "$CLI -testnet listunspent 0 999999 '[]' false '{\"assetfilter\": \"M1\"}'" 2>&1 || echo "[]")
    COUNT=$(echo "$UNSPENT" | jq -r 'length' 2>/dev/null || echo "0")
    echo "   $COUNT M1 UTXOs"
    if [[ "$COUNT" != "0" ]]; then
        echo "$UNSPENT" | jq -r '.[] | "   \(.txid):\(.vout) = \(.amount)"'
    fi
    echo ""
done

echo "=========================================="
echo "Global Settlement State"
echo "=========================================="
ssh $SSH_OPTS ubuntu@57.131.33.151 "\$HOME/BATHRON-Core/src/bathron-cli -testnet getstate" | jq '.supply'

