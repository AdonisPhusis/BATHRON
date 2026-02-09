#!/bin/bash
# Check pna-lp logs on OP1 for errors

set -e

IP="57.131.33.152"
SSH="ssh -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== Checking pna-lp logs on OP1 ($IP) ==="

# Try multiple log locations
$SSH ubuntu@$IP 'bash -s' << 'REMOTE'
if [ -f ~/pna-sdk/pna-lp.log ]; then
    echo "=== Last 100 lines of ~/pna-sdk/pna-lp.log ==="
    tail -100 ~/pna-sdk/pna-lp.log
elif [ -f ~/pna-lp.log ]; then
    echo "=== Last 100 lines of ~/pna-lp.log ==="
    tail -100 ~/pna-lp.log
elif [ -f ~/BATHRON/contrib/dex/pna-lp/pna-lp.log ]; then
    echo "=== Last 100 lines of ~/BATHRON/contrib/dex/pna-lp/pna-lp.log ==="
    tail -100 ~/BATHRON/contrib/dex/pna-lp/pna-lp.log
else
    echo "ERROR: pna-lp log file not found"
    echo "Searched locations:"
    echo "  - ~/pna-sdk/pna-lp.log"
    echo "  - ~/pna-lp.log"
    echo "  - ~/BATHRON/contrib/dex/pna-lp/pna-lp.log"
    
    # Check if pna-lp process is running
    echo ""
    echo "=== pna-lp process status ==="
    ps aux | grep -E "pna-lp|server.py" | grep -v grep || echo "No pna-lp process found"
fi
REMOTE

echo ""
echo "=== Done ==="
