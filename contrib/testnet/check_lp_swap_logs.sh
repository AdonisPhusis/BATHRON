#!/bin/bash
# Check LP logs for specific swap

SWAP_ID="${1:-full_67f6c6e133b14d20}"

echo "=== Checking LP Logs for Swap: $SWAP_ID ==="
ssh -i ~/.ssh/id_ed25519_vps ubuntu@57.131.33.152 "tail -200 /tmp/pna_lp.log | grep -A 15 -B 5 '$SWAP_ID'"
