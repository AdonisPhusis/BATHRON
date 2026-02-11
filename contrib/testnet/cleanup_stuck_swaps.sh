#!/usr/bin/env bash
# ==============================================================================
# cleanup_stuck_swaps.sh - Force-fail stuck swaps on LP via admin endpoint
# ==============================================================================
#
# Usage:
#   ./cleanup_stuck_swaps.sh [lp1|lp2]   # Default: lp1
#
# Runs on the LP VPS via SSH, calls localhost admin endpoints.
# ==============================================================================

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"

TARGET="${1:-lp1}"
case "$TARGET" in
    lp1) VPS="57.131.33.152"; LP_NAME="LP1" ;;
    lp2) VPS="57.131.33.214"; LP_NAME="LP2" ;;
    *)   echo "Usage: $0 [lp1|lp2]"; exit 1 ;;
esac

echo "=== Cleaning stuck swaps on $LP_NAME ($VPS) ==="

# List stuck swaps
echo ""
echo "--- Stuck swaps (>1h in non-terminal state) ---"
STUCK=$(ssh -i "$SSH_KEY" "ubuntu@$VPS" \
    'curl -s http://localhost:8080/api/admin/stuck-swaps')
echo "$STUCK" | python3 -m json.tool 2>/dev/null || echo "$STUCK"

COUNT=$(echo "$STUCK" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])" 2>/dev/null || echo "0")

if [ "$COUNT" = "0" ]; then
    echo ""
    echo "No stuck swaps found."
    exit 0
fi

# Force-fail each stuck swap
echo ""
echo "--- Force-failing $COUNT stuck swaps ---"
SWAP_IDS=$(echo "$STUCK" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data['stuck_swaps']:
    print(s['swap_id'])
" 2>/dev/null)

for SWAP_ID in $SWAP_IDS; do
    echo -n "  Force-failing $SWAP_ID... "
    RESULT=$(ssh -i "$SSH_KEY" "ubuntu@$VPS" \
        "curl -s -X POST http://localhost:8080/api/admin/swap/$SWAP_ID/force-fail")
    echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'OK ({d[\"old_state\"]} -> {d[\"new_state\"]})')" 2>/dev/null || echo "$RESULT"
done

echo ""
echo "--- Done. New status ---"
ssh -i "$SSH_KEY" "ubuntu@$VPS" \
    'curl -s http://localhost:8080/api/status' | python3 -m json.tool 2>/dev/null
