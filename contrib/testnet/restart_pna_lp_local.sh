#!/bin/bash
# =============================================================================
# restart_pna_lp_local.sh - Run THIS ON OP1 (57.131.33.152) directly
# =============================================================================
# Usage: Copy to OP1 and run: bash restart_pna_lp_local.sh
# =============================================================================

set -e

cd ~/pna-sdk || { echo "ERROR: ~/pna-sdk not found"; exit 1; }

echo "=== Stopping existing pna-lp ==="
pkill -f "python3 server.py" 2>/dev/null || true
sleep 2

echo "=== Starting pna-lp ==="
nohup python3 server.py > pna-lp.log 2>&1 &
sleep 3

echo "=== Checking status ==="
if curl -s http://localhost:8080/api/status | python3 -m json.tool; then
    echo ""
    echo "✓ pna-lp is running!"
    echo "URL: http://57.131.33.152:8080/"
else
    echo "ERROR: pna-lp failed to start"
    echo "Check logs: tail -50 ~/pna-sdk/pna-lp.log"
    exit 1
fi
