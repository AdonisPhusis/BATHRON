#!/bin/bash
set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=== Searching for swap initialization in full log ==="
$SSH ubuntu@57.131.33.152 "grep -E 'fs_59f554fb4eef4dbd.*PLAN|POST.*flowswap/init' /tmp/pna-sdk.log 2>/dev/null | head -20"

echo ""
echo "=== Checking DB file save operations around 03:04:40 ==="
$SSH ubuntu@57.131.33.152 "grep -E '2026-02-12 03:04:' /tmp/pna-sdk.log 2>/dev/null | grep -E '(PLAN|init|save|FlowSwap)' | head -20"

echo ""
echo "=== Count of swaps in current DB file ==="
$SSH ubuntu@57.131.33.152 "python3 -c \"
import json
with open('/home/ubuntu/.bathron/flowswap_db_lp_pna_01.json') as f:
    db = json.load(f)
print(f'Total swaps in DB file: {len(db)}')
print(f'Has fs_59f554fb4eef4dbd: {\"fs_59f554fb4eef4dbd\" in db}')
\""
