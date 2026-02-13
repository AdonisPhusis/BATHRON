#!/bin/bash
# Get full context for swap fs_59f554fb4eef4dbd

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

BLUE='\033[0;34m'; NC='\033[0m'

SWAP_ID="fs_59f554fb4eef4dbd"

echo -e "${BLUE}=== Full context for swap $SWAP_ID on LP1 ===${NC}\n"

# Get all log lines related to this swap
echo "=== Chronological log entries ==="
$SSH ubuntu@57.131.33.152 "grep '$SWAP_ID' /tmp/pna-sdk.log 2>/dev/null | tail -100"

echo ""
echo "=== Checking current FlowSwap DB state ==="
$SSH ubuntu@57.131.33.152 "cat ~/.bathron/flowswap_db_lp_pna_01.json 2>/dev/null | python3 -c \"
import json, sys
try:
    db = json.load(sys.stdin)
    swap = db.get('$SWAP_ID')
    if swap:
        print('FOUND in DB:')
        print(json.dumps(swap, indent=2))
    else:
        print('NOT FOUND in current DB')
        print('Available swap IDs:', list(db.keys())[:5])
except Exception as e:
    print('Error:', e)
\""

echo ""
echo "=== Recent error logs ==="
$SSH ubuntu@57.131.33.152 "grep -E '(ERROR|WARN|400|500|failed|timeout)' /tmp/pna-sdk.log 2>/dev/null | tail -50"
