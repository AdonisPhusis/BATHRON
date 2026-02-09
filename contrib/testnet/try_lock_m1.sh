#!/bin/bash
# Try to lock a small amount of M0 → M1 on OP1 to test fee requirements
SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"
CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== Try locking M0 → M1 on OP1 ==="

# Current balance
echo "Current balance:"
$SSH ubuntu@${OP1_IP} "$CLI getbalance" 2>&1
echo ""

# Try lock 500 (should need 500 + fee)
echo "Trying lock 500..."
RESULT=$($SSH ubuntu@${OP1_IP} "$CLI lock 500" 2>&1)
echo "Result: $RESULT"
echo ""

# Try lock 1000
echo "Trying lock 1000..."
RESULT=$($SSH ubuntu@${OP1_IP} "$CLI lock 1000" 2>&1)
echo "Result: $RESULT"
echo ""

# Try lock 1200
echo "Trying lock 1200..."
RESULT=$($SSH ubuntu@${OP1_IP} "$CLI lock 1200" 2>&1)
echo "Result: $RESULT"
