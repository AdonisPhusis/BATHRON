#!/bin/bash
# ==============================================================================
# stop_burn_daemon_seed.sh - Stop burn claim daemon on Seed node
# ==============================================================================

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"

echo "======================================"
echo "  Stopping Burn Claim Daemon on Seed"
echo "======================================"
echo ""

# Execute stop commands on Seed
ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP << 'REMOTE_EOF'
    set -e
    
    echo "[1/4] Stopping daemon via script..."
    ~/btc_burn_claim_daemon.sh stop 2>&1 || echo "  (was not running)"
    
    sleep 2
    
    echo ""
    echo "[2/4] Killing any remaining processes..."
    pkill -f "btc_burn_claim_daemon" 2>/dev/null || echo "  (no processes found)"
    
    sleep 2
    
    echo ""
    echo "[3/4] Verifying stopped..."
    if pgrep -af btc_burn_claim 2>/dev/null; then
        echo "  ERROR: Daemon still running!"
        exit 1
    else
        echo "  OK: No burn daemon processes running"
    fi
    
    echo ""
    echo "[4/4] Cleaning up..."
    rm -f /tmp/btc_burn_claim_daemon.pid
    echo "  OK: PID file removed"
    
    echo ""
    echo "======================================"
    echo "  Burnscan Status"
    echo "======================================"
    ~/bathron-cli -testnet getburnscanstatus 2>&1 | head -20 || echo "(RPC not available)"
    
    echo ""
    echo "======================================"
    echo "  SUCCESS: Burn daemon stopped"
    echo "======================================"
REMOTE_EOF

echo ""
echo "Done. The burn claim daemon is now stopped on Seed."
echo "No new burn claims will be submitted until it's restarted."
echo ""
