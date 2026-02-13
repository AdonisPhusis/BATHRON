#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED="57.131.33.151"

echo "=== Daemon running? ==="
$SSH ubuntu@$SEED 'pgrep -a bathrond 2>/dev/null || echo "NOT RUNNING"'

echo ""
echo "=== Block height ==="
$SSH ubuntu@$SEED '/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>&1'

echo ""
echo "=== dmesg (OOM or segfault) ==="
$SSH ubuntu@$SEED 'dmesg 2>/dev/null | grep -iE "oom|killed|segfault|bathrond" | tail -5 || echo "none"'

echo ""
echo "=== Debug log (last 10 lines) ==="
$SSH ubuntu@$SEED 'tail -10 ~/.bathron/testnet5/debug.log 2>/dev/null || echo "no debug log"'

echo ""
echo "=== Check for crash signal ==="
$SSH ubuntu@$SEED 'tail -100 ~/.bathron/testnet5/debug.log 2>/dev/null | grep -iE "error|shutdown|abort|segv|signal|exception" | tail -10 || echo "none"'
