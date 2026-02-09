#!/bin/bash
# Get pna-lp logs from OP1 for debugging swap failures
# Usage: ./get_pna_lp_logs.sh [swap_id] [lines]

SWAP_ID="${1:-}"
LINES="${2:-150}"
OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=== Fetching pna-lp logs from OP1 ($OP1_IP) ==="
echo "Lines to retrieve: $LINES"

if [ -n "$SWAP_ID" ]; then
    echo "Filtering for swap ID: $SWAP_ID"
    echo ""
    $SSH ubuntu@$OP1_IP "tail -$LINES /tmp/pna-sdk.log 2>/dev/null || tail -$LINES /tmp/pna-lp.log 2>/dev/null || echo 'No log file found'" | grep -A 20 -B 5 "$SWAP_ID"
else
    echo "Showing last $LINES lines:"
    echo ""
    $SSH ubuntu@$OP1_IP "tail -$LINES /tmp/pna-sdk.log 2>/dev/null || tail -$LINES /tmp/pna-lp.log 2>/dev/null || echo 'No log file found'"
fi

echo ""
echo "=== Done ==="
