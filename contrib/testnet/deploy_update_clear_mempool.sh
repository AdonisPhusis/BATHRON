#!/bin/bash
# ==============================================================================
# deploy_update_clear_mempool.sh - Deploy binaries + clear mempool
# ==============================================================================
# 
# Use case: Deploy fixed binaries and clear stuck mempool to unblock production
#
# Steps:
#   1. Stop all daemons gracefully
#   2. Delete mempool.dat on all nodes
#   3. Deploy new binaries
#   4. Start daemons
#   5. Monitor block production
# ==============================================================================

set -e

VPS_NODES=(
    "57.131.33.151"   # Seed + 8 MNs
    "162.19.251.75"   # Core+SDK
    "57.131.33.152"   # OP1
    "57.131.33.214"   # OP2
    "51.75.31.44"     # OP3
)

REPO_NODES=(
    "57.131.33.151"   # Seed - has BATHRON-Core repo
    "162.19.251.75"   # Core+SDK - has BATHRON-Core repo
)

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
SCP="scp -i $SSH_KEY $SSH_OPTS"

VPS_DATADIR="~/.bathron"
VPS_TESTNET_DIR="~/.bathron/testnet5"

LOCAL_DAEMON="/home/ubuntu/BATHRON/src/bathrond"
LOCAL_CLI="/home/ubuntu/BATHRON/src/bathron-cli"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

is_repo_node() {
    local ip=$1
    for repo_ip in "${REPO_NODES[@]}"; do
        [[ "$ip" == "$repo_ip" ]] && return 0
    done
    return 1
}

get_cli_path() {
    local ip=$1
    if is_repo_node "$ip"; then
        echo "~/BATHRON-Core/src/bathron-cli"
    else
        echo "~/bathron-cli"
    fi
}

get_daemon_path() {
    local ip=$1
    if is_repo_node "$ip"; then
        echo "~/BATHRON-Core/src/bathrond"
    else
        echo "~/bathrond"
    fi
}

# ==============================================================================
# STEP 1: Stop all daemons
# ==============================================================================
log "STEP 1: Stopping all daemons..."
for ip in "${VPS_NODES[@]}"; do
    (
        CLI=$(get_cli_path "$ip")
        echo "  Stopping $ip..."
        $SSH ubuntu@$ip "$CLI -testnet stop" 2>/dev/null || true
    ) &
done
wait

sleep 10

# Verify all stopped
log "Verifying all daemons stopped..."
for ip in "${VPS_NODES[@]}"; do
    running=$($SSH ubuntu@$ip "pgrep bathrond || echo 'NONE'" 2>/dev/null)
    if [[ "$running" == "NONE" ]]; then
        success "  $ip: stopped ✓"
    else
        warn "  $ip: still running (PIDs: $running), force killing..."
        $SSH ubuntu@$ip "killall -9 bathrond 2>/dev/null || true"
        sleep 2
    fi
done
echo ""

# ==============================================================================
# STEP 2: Delete mempool.dat
# ==============================================================================
log "STEP 2: Clearing mempool.dat on all nodes..."
for ip in "${VPS_NODES[@]}"; do
    (
        $SSH ubuntu@$ip "rm -f $VPS_TESTNET_DIR/mempool.dat && echo 'Deleted mempool.dat'"
        success "  $ip: mempool cleared ✓"
    ) &
done
wait
echo ""

# ==============================================================================
# STEP 3: Deploy binaries
# ==============================================================================
log "STEP 3: Deploying new binaries..."

# Check local binaries exist
if [[ ! -f "$LOCAL_DAEMON" ]] || [[ ! -f "$LOCAL_CLI" ]]; then
    error "Local binaries not found at $LOCAL_DAEMON or $LOCAL_CLI"
    error "Please compile first: make -j\$(nproc)"
    exit 1
fi

for ip in "${VPS_NODES[@]}"; do
    if is_repo_node "$ip"; then
        # Seed and Core+SDK: copy to ~/BATHRON-Core/src/
        log "  $ip (repo node): deploying to ~/BATHRON-Core/src/..."
        $SSH ubuntu@$ip "mkdir -p ~/BATHRON-Core/src"
        $SCP "$LOCAL_DAEMON" ubuntu@$ip:~/BATHRON-Core/src/bathrond
        $SCP "$LOCAL_CLI" ubuntu@$ip:~/BATHRON-Core/src/bathron-cli
        $SSH ubuntu@$ip "chmod +x ~/BATHRON-Core/src/bathrond ~/BATHRON-Core/src/bathron-cli"
        success "  $ip: binaries deployed ✓"
    else
        # Other nodes: copy to ~/
        log "  $ip: deploying to ~/..."
        $SSH ubuntu@$ip "rm -f ~/bathrond ~/bathron-cli"
        $SCP "$LOCAL_DAEMON" ubuntu@$ip:~/bathrond
        $SCP "$LOCAL_CLI" ubuntu@$ip:~/bathron-cli
        $SSH ubuntu@$ip "chmod +x ~/bathrond ~/bathron-cli"
        success "  $ip: binaries deployed ✓"
        
        # OP1 special: also copy to pna-lp path
        if [[ "$ip" == "57.131.33.152" ]]; then
            $SSH ubuntu@$ip "mkdir -p ~/bathron/bin && cp ~/bathrond ~/bathron/bin/ && cp ~/bathron-cli ~/bathron/bin/ && chmod +x ~/bathron/bin/*"
            success "  $ip: also deployed to ~/bathron/bin/ for pna-lp ✓"
        fi
    fi
done
echo ""

# ==============================================================================
# STEP 4: Start daemons
# ==============================================================================
log "STEP 4: Starting daemons..."
for ip in "${VPS_NODES[@]}"; do
    (
        DAEMON=$(get_daemon_path "$ip")
        echo "  Starting $ip..."
        $SSH ubuntu@$ip "$DAEMON -testnet -daemon"
    ) &
done
wait
sleep 5
success "All daemons started ✓"
echo ""

# ==============================================================================
# STEP 5: Check status
# ==============================================================================
log "STEP 5: Checking network status (waiting 15s for startup)..."
sleep 15

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                     NETWORK STATUS                             ║"
echo "╠════════════════════════════════════════════════════════════════╣"
printf "%-20s %-10s %-8s %-30s\n" "Node" "Height" "Peers" "Status"
echo "────────────────────────────────────────────────────────────────"

for ip in "${VPS_NODES[@]}"; do
    CLI=$(get_cli_path "$ip")
    
    # Get height and peer count
    height=$($SSH ubuntu@$ip "$CLI -testnet getblockcount 2>/dev/null" || echo "ERROR")
    peers=$($SSH ubuntu@$ip "$CLI -testnet getconnectioncount 2>/dev/null" || echo "0")
    
    if [[ "$height" == "ERROR" ]]; then
        printf "%-20s %-10s %-8s %-30s\n" "$ip" "ERROR" "-" "Daemon not responding"
    else
        printf "%-20s %-10s %-8s %-30s\n" "$ip" "$height" "$peers" "OK"
    fi
done

echo "════════════════════════════════════════════════════════════════"
echo ""

# ==============================================================================
# STEP 6: Monitor for new block
# ==============================================================================
log "STEP 6: Monitoring for new block production (60s)..."
CLI=$(get_cli_path "57.131.33.151")  # Monitor Seed
initial_height=$($SSH ubuntu@57.131.33.151 "$CLI -testnet getblockcount 2>/dev/null" || echo "0")

echo "Initial height: $initial_height"
echo "Waiting for new block..."

for i in {1..60}; do
    sleep 1
    current_height=$($SSH ubuntu@57.131.33.151 "$CLI -testnet getblockcount 2>/dev/null" || echo "0")
    if [[ "$current_height" != "$initial_height" ]]; then
        success "New block produced! Height: $current_height (was $initial_height)"
        break
    fi
    printf "."
done
echo ""

# Final status
final_height=$($SSH ubuntu@57.131.33.151 "$CLI -testnet getblockcount 2>/dev/null" || echo "0")
if [[ "$final_height" == "$initial_height" ]]; then
    warn "No new blocks after 60s. Network may still be starting up."
    warn "Check logs: ssh ubuntu@57.131.33.151 'tail -100 ~/.bathron/testnet5/debug.log'"
else
    success "DEPLOYMENT COMPLETE - Network producing blocks ✓"
fi
