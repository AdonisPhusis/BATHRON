#!/bin/bash
# Debug wallet state on CoreSDK (has 504k M1) and OP1 (LP1)
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=== CoreSDK raw getwalletstate ==="
$SSH ubuntu@162.19.251.75 "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getwalletstate true" 2>&1

echo ""
echo "=== OP1 raw getwalletstate ==="
$SSH ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet getwalletstate true" 2>&1

echo ""
echo "=== OP1 raw getbalance ==="
$SSH ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet getbalance" 2>&1

echo ""
echo "=== OP1 listtransactions (recent) ==="
$SSH ubuntu@57.131.33.152 "/home/ubuntu/bathron-cli -testnet listtransactions '*' 5" 2>&1
