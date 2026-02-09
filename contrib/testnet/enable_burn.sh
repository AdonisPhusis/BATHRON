#!/bin/bash
# enable_burn.sh - Enable/disable BTC burn and mint on all testnet nodes
#
# Usage:
#   ./enable_burn.sh --status          Show current burn/mint config on all nodes
#   ./enable_burn.sh --burn-only       Enable burn, disable mint (Phase 1)
#   ./enable_burn.sh --full            Enable both burn and mint (Phase 2)
#   ./enable_burn.sh --off             Disable both burn and mint
#
# This script modifies bathron.conf on each node and restarts daemons.
# V2 SPV must be ready before enabling burn (spv_ready=true on all nodes).

set -e

# Node configuration (same as deploy_to_vps.sh)
VPS_NODES=(
    "57.131.33.151"   # Seed + Faucet + Explorer (NO MN)
    "162.19.251.75"   # Core+SDK + MN1 (OP1)
    "57.131.33.152"   # OP1 - MN2 (OP2)
    "57.131.33.214"   # OP2 - MN3 (OP3)
    "51.75.31.44"     # OP3 - 5 MNs (Multi-MN, OP4)
)

# Nodes that use ~/BATHRON-Core/src/ instead of ~/
REPO_NODES=(
    "57.131.33.151"   # Seed - has BATHRON-Core repo
    "162.19.251.75"   # Core+SDK - has BATHRON-Core repo
)

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=30"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

VPS_DATADIR="/home/ubuntu/.bathron"
VPS_CONF="$VPS_DATADIR/bathron.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
ok() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err() { echo -e "${RED}✗${NC} $1"; }

# Check if node uses repo path
is_repo_node() {
    local ip=$1
    for repo in "${REPO_NODES[@]}"; do
        [[ "$ip" == "$repo" ]] && return 0
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

show_status() {
    log "Checking burn/mint configuration on all nodes..."
    echo ""
    printf "%-18s %-12s %-12s %-10s %-10s\n" "Node" "enableburn" "enablemint" "spv_ready" "height"
    printf "%-18s %-12s %-12s %-10s %-10s\n" "----" "----------" "----------" "---------" "------"

    for ip in "${VPS_NODES[@]}"; do
        CLI=$(get_cli_path "$ip")

        # Get config values and status in one SSH call
        result=$($SSH ubuntu@$ip "
            BURN=\$(grep -E '^enableburn=' $VPS_CONF 2>/dev/null | cut -d= -f2 || echo 'unset')
            MINT=\$(grep -E '^enablemint=' $VPS_CONF 2>/dev/null | cut -d= -f2 || echo 'unset')
            SPV=\$($CLI -testnet getbtcsyncstatus 2>/dev/null | grep -o '\"spv_ready\": [a-z]*' | awk '{print \$2}' || echo 'error')
            HEIGHT=\$($CLI -testnet getblockcount 2>/dev/null || echo 'error')
            echo \"\$BURN \$MINT \$SPV \$HEIGHT\"
        " 2>/dev/null || echo "error error error error")

        read -r burn mint spv height <<< "$result"

        # Color code the values
        burn_color=$([[ "$burn" == "1" ]] && echo "$GREEN" || echo "$NC")
        mint_color=$([[ "$mint" == "1" ]] && echo "$GREEN" || echo "$NC")
        spv_color=$([[ "$spv" == "true" ]] && echo "$GREEN" || echo "$YELLOW")

        printf "%-18s ${burn_color}%-12s${NC} ${mint_color}%-12s${NC} ${spv_color}%-10s${NC} %-10s\n" \
            "$ip" "$burn" "$mint" "$spv" "$height"
    done
    echo ""
}

update_config() {
    local ip=$1
    local burn_val=$2
    local mint_val=$3
    local CLI=$(get_cli_path "$ip")
    local DAEMON=$(get_daemon_path "$ip")
    local CONF="$VPS_CONF"

    log "Updating $ip: enableburn=$burn_val, enablemint=$mint_val"

    # Stop daemon
    $SSH ubuntu@$ip "$CLI -testnet stop" 2>/dev/null || true
    sleep 3

    # Update config (use heredoc for proper variable expansion)
    $SSH ubuntu@$ip bash <<EOF
        # Update or add enableburn
        if grep -q '^enableburn=' $CONF 2>/dev/null; then
            sed -i 's/^enableburn=.*/enableburn=$burn_val/' $CONF
        else
            echo 'enableburn=$burn_val' >> $CONF
        fi

        # Update or add enablemint
        if grep -q '^enablemint=' $CONF 2>/dev/null; then
            sed -i 's/^enablemint=.*/enablemint=$mint_val/' $CONF
        else
            echo 'enablemint=$mint_val' >> $CONF
        fi
EOF

    # Restart daemon
    $SSH ubuntu@$ip "$DAEMON -testnet -daemon" 2>/dev/null
    sleep 3

    # Verify restart
    height=$($SSH ubuntu@$ip "$CLI -testnet getblockcount" 2>/dev/null || echo "error")
    if [[ "$height" != "error" && "$height" =~ ^[0-9]+$ ]]; then
        ok "$ip restarted at height $height"
    else
        err "$ip failed to restart (got: $height)"
    fi
}

enable_burn_only() {
    log "Phase 1: Enabling burn (mint OFF) on all nodes..."
    echo ""

    # First check SPV readiness
    log "Verifying SPV readiness..."
    all_ready=true
    for ip in "${VPS_NODES[@]}"; do
        CLI=$(get_cli_path "$ip")
        spv=$($SSH ubuntu@$ip "$CLI -testnet getbtcsyncstatus 2>/dev/null | grep -o '\"spv_ready\": [a-z]*' | awk '{print \$2}'" 2>/dev/null || echo "false")
        if [[ "$spv" != "true" ]]; then
            err "$ip: SPV not ready (spv_ready=$spv)"
            all_ready=false
        else
            ok "$ip: SPV ready"
        fi
    done

    if [[ "$all_ready" != "true" ]]; then
        err "Aborting: Not all nodes have SPV ready"
        exit 1
    fi

    echo ""
    log "Updating configuration on all nodes..."
    for ip in "${VPS_NODES[@]}"; do
        update_config "$ip" "1" "0"
    done

    echo ""
    log "Done. Run './enable_burn.sh --status' to verify."
}

enable_full() {
    log "Phase 2: Enabling burn AND mint on all nodes..."
    echo ""

    for ip in "${VPS_NODES[@]}"; do
        update_config "$ip" "1" "1"
    done

    echo ""
    log "Done. Run './enable_burn.sh --status' to verify."
}

disable_all() {
    log "Disabling burn and mint on all nodes..."
    echo ""

    for ip in "${VPS_NODES[@]}"; do
        update_config "$ip" "0" "0"
    done

    echo ""
    log "Done. Run './enable_burn.sh --status' to verify."
}

show_help() {
    echo "Usage: $0 [option]"
    echo ""
    echo "Options:"
    echo "  --status      Show current burn/mint config on all nodes"
    echo "  --burn-only   Enable burn, disable mint (Phase 1 - validate burn_claim)"
    echo "  --full        Enable both burn and mint (Phase 2 - full pipeline)"
    echo "  --off         Disable both burn and mint"
    echo "  --help        Show this help"
    echo ""
    echo "Workflow:"
    echo "  1. Verify V2 SPV ready: ./deploy_to_vps.sh --spv=status"
    echo "  2. Enable burn only:    ./enable_burn.sh --burn-only"
    echo "  3. Test burn_claim E2E"
    echo "  4. Enable full:         ./enable_burn.sh --full"
    echo "  5. Test burn→claim→mint E2E"
}

# Main
case "${1:-}" in
    --status)
        show_status
        ;;
    --burn-only)
        enable_burn_only
        ;;
    --full)
        enable_full
        ;;
    --off)
        disable_all
        ;;
    --help|-h|"")
        show_help
        ;;
    *)
        err "Unknown option: $1"
        show_help
        exit 1
        ;;
esac
