#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"
CLI="/home/ubuntu/bathron-cli -testnet"

echo "=== MN List (Seed) ==="
$SSH ubuntu@$SEED "timeout 5 $CLI protx_list 2>&1 | jq length"

echo ""
echo "=== MN List details ==="
$SSH ubuntu@$SEED "timeout 5 $CLI protx_list 2>&1 | jq -r '.[] | \"  \(.proTxHash[:16]) state=\(.state.status) addr=\(.state.service)\"' 2>/dev/null"

echo ""
echo "=== Active MN status (Seed) ==="
$SSH ubuntu@$SEED "timeout 5 $CLI getactivemnstatus 2>&1"

echo ""
echo "=== Finality status (Seed) ==="
$SSH ubuntu@$SEED "timeout 5 $CLI getfinalitystatus 2>&1"

echo ""
echo "=== MN count on each node ==="
for IP in 57.131.33.151 162.19.251.75 57.131.33.152 57.131.33.214 51.75.31.44; do
    MN_COUNT=$($SSH ubuntu@$IP "timeout 5 $CLI masternode count 2>&1" 2>/dev/null)
    HEIGHT=$($SSH ubuntu@$IP "timeout 5 $CLI getblockcount 2>&1" 2>/dev/null)
    echo "  $IP: height=$HEIGHT mn_count=$MN_COUNT"
done
