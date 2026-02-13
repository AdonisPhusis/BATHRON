#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"
CLI="$SSH_CMD /home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Checking Seed MN Status ==="
echo ""

echo "Active MN status:"
$CLI getactivemnstatus 2>&1

echo ""
echo "Recent debug log (errors):"
$SSH_CMD "tail -50 ~/.bathron/testnet5/debug.log | grep -E '(ERROR|REJECT|invalid|failed)'"

echo ""
echo "Recent debug log (MN/DMM/producer):"
$SSH_CMD "tail -100 ~/.bathron/testnet5/debug.log | grep -iE '(masternode|producer|dmm|scheduler)'"
