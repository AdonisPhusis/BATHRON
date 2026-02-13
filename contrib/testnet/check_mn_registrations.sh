#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"
CLI="$SSH_CMD /home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Checking MN Registrations On-Chain ==="
echo ""

echo "Waiting for daemon to be ready..."
sleep 10

echo "Block height:"
$CLI getblockcount 2>&1

echo ""
echo "Block 25 (ProReg block):"
HASH=$($CLI getblockhash 25 2>&1)
echo "Hash: $HASH"
$CLI getblock "$HASH" | jq -r '{height, tx: .tx | length}'

echo ""
echo "Transactions in block 25:"
$CLI getblock "$HASH" | jq -r '.tx[]' | head -15

echo ""
echo "MN list (via protx list):"
$CLI protx list 2>&1 || echo "protx not available"
