#!/bin/bash
# Check pna-lp status on OP1

OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=== pna-lp Server Status ==="
$SSH ubuntu@$OP1_IP "ps aux | grep -E 'uvicorn.*server' | grep -v grep"

echo ""
echo "=== Recent Logs ==="
$SSH ubuntu@$OP1_IP "tail -50 /tmp/pna-sdk.log 2>/dev/null | tail -30"
