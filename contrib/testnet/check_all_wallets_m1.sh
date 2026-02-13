#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# All 5 nodes: name|ip|cli_path
NODES=(
    "Seed|57.131.33.151|/home/ubuntu/BATHRON-Core/src/bathron-cli"
    "CoreSDK|162.19.251.75|/home/ubuntu/BATHRON-Core/src/bathron-cli"
    "OP1 (alice)|57.131.33.152|/home/ubuntu/bathron-cli"
    "OP2 (dev)|57.131.33.214|/home/ubuntu/bathron-cli"
    "OP3 (charlie)|51.75.31.44|/home/ubuntu/bathron-cli"
)

echo "Checking M0/M1 wallet state across ALL nodes..."
echo ""

for entry in "${NODES[@]}"; do
    IFS='|' read -r name ip cli <<< "$entry"

    echo "=========================================="
    echo "Node: $name ($ip)"
    echo "=========================================="

    # 1. M0 balance
    echo "1. M0 balance:"
    M0=$(ssh $SSH_OPTS ubuntu@$ip "$cli -testnet getbalance" 2>&1 || echo "ERROR")
    echo "   $M0"

    # 2. Wallet state (M1 receipts)
    echo "2. M1 receipts (getwalletstate):"
    WALLET_STATE=$(ssh $SSH_OPTS ubuntu@$ip "$cli -testnet getwalletstate true" 2>&1 || echo "{}")
    M1_COUNT=$(echo "$WALLET_STATE" | jq -r '.m1.receipts | length' 2>/dev/null || echo "0")
    M1_TOTAL=$(echo "$WALLET_STATE" | jq -r '.m1.total // 0' 2>/dev/null || echo "0")

    if [[ "$M1_COUNT" == "0" || "$M1_COUNT" == "null" ]]; then
        echo "   No M1 receipts"
    else
        echo "   $M1_COUNT receipt(s), total: $M1_TOTAL M1"
        echo "$WALLET_STATE" | jq -r '.m1.receipts[]? | "   → \(.outpoint) = \(.amount) M1"' 2>/dev/null || true
    fi

    # 3. Wallet name (verify independence)
    echo "3. Wallet identity:"
    ADDR=$(ssh $SSH_OPTS ubuntu@$ip "$cli -testnet getaccountaddress \"\"" 2>&1 || echo "unknown")
    echo "   Address: $ADDR"

    echo ""
done

echo "=========================================="
echo "Global Settlement State (from Seed)"
echo "=========================================="
ssh $SSH_OPTS ubuntu@57.131.33.151 "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getstate" 2>&1 | jq '.supply' 2>/dev/null || echo "ERROR fetching state"
