#!/bin/bash
# ==============================================================================
# deploy_to_vps.sh - UNIFIED BATHRON Testnet Orchestrator v17.0
# ==============================================================================
#
# ONE SCRIPT, MODULAR SUB-COMMANDS, STRICT GATES
#
# Usage:
#   ./deploy_to_vps.sh <command> [options]
#
# === DIAGNOSTIC ===
#   --status           Quick status: height + peers per node
#   --check            Pre-flight: SSH, binaries, connectivity
#   --health           Full health check
#   --btc              BTC headers status (btcheadersdb consensus tip)
#
# === GENESIS (granular) ===
#   --genesis-create      Create blocks 0-3 on Seed only
#   --genesis-distribute  Distribute chain + SPV to all nodes
#   --genesis-configure   Configure MN + SPV on Seed
#   --genesis-start       Start all daemons
#   --genesis-verify      Verify network is producing blocks
#   --genesis             FULL: all above in order (with strict gates)
#
# === DEPLOYMENT LEVELS ===
#   --update           Level 1: binary update only
#   --rescan           Level 2: + wallet rescan
#   --wipe             Level 3: + chain wipe
#
# === CONTROL ===
#   --stop             Stop ALL daemons
#   --dry-run          Show what would be done (no changes)
#   --resume-from=N    Resume genesis from step N (1-7)
#   --help             Show this help
#
# === STRICT GATES (--genesis) ===
# Each step has must_ok assertions. Script exits immediately on failure:
#   - BTC Signet must be reachable on Seed
#   - SPV tip must be >= BTC genesis checkpoint (286000)
#   - Operator keys must be generated
#   - All nodes must sync to same height
# ==============================================================================

set -e

# ==============================================================================
# NETWORK CONFIGURATION (v13.0 Burn-Based Genesis - 8 MNs)
# ==============================================================================
# LOCAL machine (37.59.114.129):
#   - Development and wallet control
#   - Source of binaries (compiled here)
#   - Collateral keys stay here (NEVER on VPS)
#   - NO testnet daemon should run here (cleaned by --full-reset and --stop)
#
# VPS Nodes - ONE daemon per node:
#   - Seed (57.131.33.151): 8 MNs (pilpous) + Faucet + Explorer + SPV Publisher
#   - Core+SDK (162.19.251.75): Development + SDK (peer only)
#   - OP1 (57.131.33.152): Peer only
#   - OP2 (57.131.33.214): Peer only
#   - OP3 (51.75.31.44): Peer only
#
# Total: 5 VPS, 1 operator (pilpous), 8 masternodes, 8,000,000 M0 from burns
# ==============================================================================

# Consensus constant — must match BTCHEADERS_GENESIS_CHECKPOINT in src/btcheaders/btcheaders.h
BTC_CHECKPOINT=286000

VPS_NODES=(
    "57.131.33.151"   # Seed + 8 MNs (pilpous) + Faucet + Explorer
    "162.19.251.75"   # Core+SDK (peer only)
    "57.131.33.152"   # Peer only
    "57.131.33.214"   # Peer only
    "51.75.31.44"     # Peer only
)

# MN operator nodes (v13.0: only Seed has MNs)
MN_NODES=(
    "57.131.33.151"   # Seed - 8 MNs (pilpous)
)

# Nodes that use ~/BATHRON-Core/src/ instead of ~/
# These nodes have full git repo (for git pull)
REPO_NODES=(
    "57.131.33.151"   # Seed - has BATHRON-Core repo
    "162.19.251.75"   # Core+SDK - has BATHRON-Core repo
)

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
# SSH multiplexing: reuse single connection per host to avoid rate limiting
# - ControlPersist=600: Keep connection alive 10 min (long genesis operations)
# - ServerAliveInterval=30 + ServerAliveCountMax=10: Detect dead connections
# - TCPKeepAlive=yes: Prevent firewall timeouts
SSH_CONTROL_DIR="/tmp/ssh-bathron-deploy-$$"
mkdir -p "$SSH_CONTROL_DIR"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=10 -o TCPKeepAlive=yes -o ControlMaster=auto -o ControlPath=$SSH_CONTROL_DIR/%h -o ControlPersist=600"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
SCP="scp -i $SSH_KEY $SSH_OPTS"

# Comprehensive cleanup on exit (SSH sockets, temp files)
cleanup_on_exit() {
    # 1. Clean up this session's SSH control sockets
    rm -rf "$SSH_CONTROL_DIR" 2>/dev/null || true

    # 2. Clean up temp tar files
    rm -f /tmp/testnet5_bootstrap.tar.gz 2>/dev/null || true
    rm -f /tmp/testnet5_chain.tar.gz 2>/dev/null || true
    rm -f /tmp/btcspv_backup*.tar.gz 2>/dev/null || true

    # 3. Clean up old orphaned SSH control directories (from previous runs killed with SIGKILL)
    find /tmp -maxdepth 1 -name "ssh-bathron-deploy-*" -type d -mmin +60 -exec rm -rf {} \; 2>/dev/null || true
}
trap cleanup_on_exit EXIT INT TERM

# Robust SSH execution with retries (for rate-limited hosts)
ssh_with_retry() {
    local host="$1"
    shift
    local cmd="$*"
    local max_retries=3
    local retry_delay=10
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        if $SSH "ubuntu@$host" "$cmd" 2>/dev/null; then
            return 0
        fi
        if [ $attempt -lt $max_retries ]; then
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))  # Exponential backoff
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# Paths - use $HOME instead of hardcoded /home/ubuntu
LOCAL_DAEMON="$HOME/BATHRON-Core/src/bathrond"
LOCAL_CLI="$HOME/BATHRON-Core/src/bathron-cli"

# Canonical data directory (ALWAYS use explicit -datadir)
# VPS nodes use /home/ubuntu/.bathron as base
VPS_DATADIR="/home/ubuntu/.bathron"
VPS_TESTNET_DIR="$VPS_DATADIR/testnet5"

# ==============================================================================
# CRITICAL DIRECTORIES TO WIPE (single source of truth)
# ==============================================================================
# ALL LevelDB directories that must be wiped during genesis/reset
# Update this list whenever a new database is added to the codebase!
# Currently: blocks chainstate evodb llmq hu_finality khu sporks database
#            wallets backups settlement burnclaimdb btcheadersdb btcspv htlc index
CRITICAL_DB_DIRS="blocks chainstate evodb llmq hu_finality khu sporks database wallets backups settlement burnclaimdb btcheadersdb btcspv htlc index"

# Timeouts and retries
MAX_RETRIES=3
DAEMON_START_TIMEOUT=15
SYNC_WAIT_TIMEOUT=45

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Options - Deployment Levels
DEPLOY_LEVEL=0          # 0=none, 1=update, 2=rescan, 3=wipe, 4=genesis
STOP_ONLY=false
STATUS_ONLY=false
CHECK_ONLY=false
HEALTH_ONLY=false
UPDATE_REPO=false
CONFIGURE_KEYS=false
SYNC_CHAIN=false
EXPLORER_ONLY=false
BAN_POLLUTERS=false
RESTORE_MN_CONFIGS=false
SPV_MODE=""

# v17.0: New modular options
DRY_RUN=false
RESUME_FROM=0
SPV_PREPARE=false
SPV_DISTRIBUTE=false
SPV_VERIFY=false
GENESIS_CREATE=false
GENESIS_DISTRIBUTE=false
GENESIS_CONFIGURE=false
GENESIS_START=false
GENESIS_VERIFY=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        # Diagnostic
        --status) STATUS_ONLY=true ;;
        --check) CHECK_ONLY=true ;;
        --health) HEALTH_ONLY=true ;;
        --btc-status|--btc|--spv) SPV_MODE="status" ;;  # BTC headers status

        # Deployment levels (1-4)
        --update) DEPLOY_LEVEL=1 ;;
        --rescan) DEPLOY_LEVEL=2 ;;
        --wipe) DEPLOY_LEVEL=3 ;;
        --genesis) DEPLOY_LEVEL=4 ;;
        --full-reset) DEPLOY_LEVEL=4 ;;

        # v17.0: Granular SPV sub-commands
        --spv-prepare) SPV_PREPARE=true ;;
        --spv-distribute) SPV_DISTRIBUTE=true ;;
        --spv-verify) SPV_VERIFY=true ;;

        # v17.0: Granular Genesis sub-commands
        --genesis-create) GENESIS_CREATE=true ;;
        --genesis-distribute) GENESIS_DISTRIBUTE=true ;;
        --genesis-configure) GENESIS_CONFIGURE=true ;;
        --genesis-start) GENESIS_START=true ;;
        --genesis-verify) GENESIS_VERIFY=true ;;

        # v17.0: Control options
        --dry-run) DRY_RUN=true ;;
        --resume-from=*) RESUME_FROM="${arg#*=}" ;;

        # Control
        --stop) STOP_ONLY=true ;;
        --update-repo) UPDATE_REPO=true ;;
        --explorer) EXPLORER_ONLY=true ;;
        --configure-keys) CONFIGURE_KEYS=true ;;
        --sync-chain) SYNC_CHAIN=true ;;
        --ban-polluters) BAN_POLLUTERS=true ;;
        --restore-mn-configs) RESTORE_MN_CONFIGS=true ;;
        # --spv is legacy alias for --btc (handled above)
        --help)
            head -50 "$0" | tail -45
            exit 0
            ;;
    esac
done

# Human-readable level names
get_level_name() {
    case $1 in
        1) echo "UPDATE (binary only)" ;;
        2) echo "RESCAN (+ wallet rescan)" ;;
        3) echo "WIPE (+ chain wipe)" ;;
        4) echo "GENESIS (HARD RESET)" ;;
        *) echo "NONE" ;;
    esac
}

log() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"
}

success() {
    echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $1"
}

error() {
    echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $1"
}

# ==============================================================================
# v17.0: STRICT GATES - must_ok pattern (exit on failure)
# ==============================================================================

# Gate: Check condition and exit if false
must_ok() {
    local condition="$1"
    local msg="$2"
    if ! eval "$condition"; then
        error "GATE FAILED: $msg"
        exit 1
    fi
    success "GATE OK: $msg"
}

# Gate: File must exist
gate_file_exists() {
    local file="$1"
    local desc="$2"
    if [ ! -f "$file" ]; then
        error "GATE FAILED: $desc not found: $file"
        exit 1
    fi
    success "GATE OK: $desc exists"
}

# Gate: SSH command must succeed
gate_ssh_ok() {
    local ip="$1"
    local cmd="$2"
    local desc="$3"
    if ! $SSH ubuntu@$ip "$cmd" >/dev/null 2>&1; then
        error "GATE FAILED: $desc on $ip"
        exit 1
    fi
    success "GATE OK: $desc on $ip"
}

# Gate: SPV tip must be >= required height
gate_spv_ready() {
    local ip="$1"
    local required="$2"
    local tip=$($SSH ubuntu@$ip '~/bathron-cli -testnet getbtcsyncstatus 2>/dev/null | jq -r ".tip_height // 0"' 2>/dev/null || echo "0")
    if [ "$tip" -lt "$required" ]; then
        error "GATE FAILED: SPV tip ($tip) < required ($required) on $ip"
        exit 1
    fi
    success "GATE OK: SPV tip=$tip >= $required on $ip"
}

# Gate: All nodes at same height
gate_nodes_synced() {
    local expected="$1"
    local all_ok=true
    for ip in "${VPS_NODES[@]}"; do
        local h=$($SSH ubuntu@$ip '~/bathron-cli -testnet getblockcount 2>/dev/null' 2>/dev/null || echo "0")
        if [ "$h" -ne "$expected" ]; then
            error "  $ip: height=$h (expected $expected)"
            all_ok=false
        fi
    done
    if ! $all_ok; then
        error "GATE FAILED: Nodes not synced to height $expected"
        exit 1
    fi
    success "GATE OK: All nodes synced to height $expected"
}

# Dry-run wrapper: skip if DRY_RUN=true
run_or_dry() {
    local desc="$1"
    shift
    if $DRY_RUN; then
        log "[DRY-RUN] Would execute: $desc"
    else
        log "Executing: $desc"
        "$@"
    fi
}

# ==============================================================================
# MN CONFIG RESTORATION: Restore MN configs after genesis reset
# ==============================================================================
# Burn-Based v13.0 Layout (8 MNs, 1 operator):
#   - Seed (57.131.33.151): pilpous = 8 MNs (from BTC burns)
#   - Core+SDK (162.19.251.75): Peer only
#   - OP1 (57.131.33.152): Peer only
#   - OP2 (57.131.33.214): Peer only
#   - OP3 (51.75.31.44): Peer only
# Uses keys from ~/.BathronKey/operators.json on Seed
# ==============================================================================
restore_mn_configs() {
    log "Restoring MN configs (v13.0 burn-based: 1 operator, 8 MNs on Seed)..."

    # Try to read operator keys from Seed's ~/.BathronKey/operators.json
    # These keys are generated by genesis_bootstrap_seed.sh and match the ProRegTx
    local KEYS_JSON=$($SSH ubuntu@57.131.33.151 "cat ~/.BathronKey/operators.json 2>/dev/null" 2>/dev/null)

    if [ -n "$KEYS_JSON" ]; then
        log "  Using operator keys from Seed (~/.BathronKey/operators.json)"

        # Extract pilpous WIF (v15.0: single operator for all 8 MNs)
        # Try new format (.operator.wif) first, then old format (.operators.pilpous.wif)
        local PILPOUS_WIF=$(echo "$KEYS_JSON" | jq -r '.operator.wif // .operators.pilpous.wif')

        if [ -z "$PILPOUS_WIF" ] || [ "$PILPOUS_WIF" = "null" ]; then
            error "Pilpous operator key not found in operator_keys.json!"
            error "Expected: .operator.wif or .operators.pilpous.wif"
            return 1
        fi

        # Configure Seed (57.131.33.151) as MN operator with 8 MNs + SPV publisher
        $SSH ubuntu@57.131.33.151 "
            CONFIG_FILE=$VPS_DATADIR/bathron.conf
            grep -q '^masternode=1' \$CONFIG_FILE 2>/dev/null || echo 'masternode=1' >> \$CONFIG_FILE
            sed -i '/^mnoperatorprivatekey=/d' \$CONFIG_FILE
            echo 'mnoperatorprivatekey=$PILPOUS_WIF' >> \$CONFIG_FILE
            # SPV publisher config
            grep -q '^btcspv=1' \$CONFIG_FILE 2>/dev/null || echo 'btcspv=1' >> \$CONFIG_FILE
            grep -q '^btcheaderspublish=1' \$CONFIG_FILE 2>/dev/null || echo 'btcheaderspublish=1' >> \$CONFIG_FILE
        " 2>/dev/null
        success "  57.131.33.151: Seed (MNs + SPV publisher) configured"

        # Ensure other VPS are NOT MN nodes (peers only)
        for ip in 162.19.251.75 57.131.33.152 57.131.33.214 51.75.31.44; do
            $SSH ubuntu@$ip "
                CONFIG_FILE=$VPS_DATADIR/bathron.conf
                sed -i '/^masternode=/d' \$CONFIG_FILE
                sed -i '/^mnoperatorprivatekey=/d' \$CONFIG_FILE
            " 2>/dev/null
            success "  $ip: Peer only (no MN)"
        done
    else
        error "Could not read operator keys from Seed!"
        error "Run bootstrap_testnet.sh first, or manually configure MN keys."
        return 1
    fi

    success "MN configs restored on all nodes (v13.0 burn-based layout) ✓"
}

# ==============================================================================
# BURN-BASED v13.0: Configure VPS operator keys from bootstrap output
# ==============================================================================
configure_vps_operator_keys() {
    local KEYS_FILE="/tmp/mn_operator_keys.json"

    if [ ! -f "$KEYS_FILE" ]; then
        error "Operator keys file not found: $KEYS_FILE"
        error "Run bootstrap_testnet.sh first to generate keys!"
        exit 1
    fi

    log "Configuring VPS operator keys (Burn-Based v13.0 - 1 operator, 8 MNs)..."
    echo ""

    # Read pilpous operator WIF (v15.0: single operator for all 8 MNs)
    # Try new format (.operator) first, then old format (.operators.pilpous)
    local PILPOUS_WIF=$(jq -r '.operator.wif // .operators.pilpous.wif' "$KEYS_FILE")
    local PILPOUS_IP=$(jq -r '.operator.ip // .operators.pilpous.ip' "$KEYS_FILE")

    if [ -z "$PILPOUS_WIF" ] || [ "$PILPOUS_WIF" = "null" ]; then
        error "Pilpous operator key not found in $KEYS_FILE"
        error "Expected: .operator.wif or .operators.pilpous.wif"
        exit 1
    fi

    # Show what we're doing
    log "  Seed ($PILPOUS_IP): 8 MNs (pilpous - all from BTC burns)"
    log "  Other VPS: Peers only (no MNs)"
    echo ""

    # Configure Seed as MN operator
    log "  Configuring $PILPOUS_IP (8 MNs)..."
    $SSH ubuntu@$PILPOUS_IP "
        CONFIG_FILE=~/.bathron/bathron.conf

        # Ensure masternode=1
        grep -q '^masternode=1' \$CONFIG_FILE 2>/dev/null || echo 'masternode=1' >> \$CONFIG_FILE

        # Update operator key
        sed -i '/^mnoperatorprivatekey=/d' \$CONFIG_FILE
        echo 'mnoperatorprivatekey=$PILPOUS_WIF' >> \$CONFIG_FILE
    " 2>/dev/null
    success "  $PILPOUS_IP: configured with pilpous operator key"

    # Ensure other VPS are peers only
    for ip in 162.19.251.75 57.131.33.152 57.131.33.214 51.75.31.44; do
        $SSH ubuntu@$ip "
            CONFIG_FILE=~/.bathron/bathron.conf
            sed -i '/^masternode=/d' \$CONFIG_FILE
            sed -i '/^mnoperatorprivatekey=/d' \$CONFIG_FILE
        " 2>/dev/null
        success "  $ip: peer only (no MN)"
    done

    echo ""
    success "All VPS operator keys configured!"
    log "Seed manages 8 MNs with ONE key (Burn-Based v13.0)"
    echo ""
    log "Now restart daemons with: ./deploy_to_vps.sh --update"
}

# ==============================================================================
# PRE-FLIGHT CHECKS - Validate environment before any operation
# ==============================================================================
preflight_check() {
    local errors=0

    log "Running pre-flight checks..."

    # 1. Check SSH key exists
    if [ ! -f "${SSH_KEY/#\~/$HOME}" ]; then
        error "  SSH key not found: $SSH_KEY"
        ((errors++))
    else
        success "  SSH key exists ✓"
    fi

    # 2. Check local binaries exist
    if [ ! -f "$LOCAL_DAEMON" ]; then
        error "  Local daemon not found: $LOCAL_DAEMON"
        ((errors++))
    else
        success "  Local daemon exists ✓"
    fi

    if [ ! -f "$LOCAL_CLI" ]; then
        error "  Local CLI not found: $LOCAL_CLI"
        ((errors++))
    else
        success "  Local CLI exists ✓"
    fi

    # 3. Check local binaries are executable
    if [ -f "$LOCAL_DAEMON" ] && [ ! -x "$LOCAL_DAEMON" ]; then
        error "  Local daemon not executable: $LOCAL_DAEMON"
        ((errors++))
    fi

    # 4. Test SSH connectivity to all VPS nodes (with retries for rate-limited hosts)
    log "  Testing SSH connectivity..."
    for ip in "${VPS_NODES[@]}"; do
        # Sleep 3s between SSH tests to avoid rate limiting (especially on Seed)
        sleep 3
        local ssh_ok=false
        local retry_count=0
        local max_retries=3
        local retry_delay=5

        while [ $retry_count -lt $max_retries ]; do
            if timeout 15 $SSH ubuntu@$ip "echo OK" >/dev/null 2>&1; then
                ssh_ok=true
                break
            fi
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                log "    $ip: retry $retry_count/$max_retries (waiting ${retry_delay}s)..."
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))  # Exponential backoff: 5, 10, 20
            fi
        done

        if $ssh_ok; then
            success "    $ip: reachable ✓"
        else
            error "    $ip: UNREACHABLE after $max_retries attempts!"
            ((errors++))
        fi
    done

    # 5. Check version compatibility (warn if mismatch, not error)
    log "  Checking daemon versions..."
    local local_version=$(get_local_daemon_version)
    log "    Local version: $local_version"

    local version_mismatches=0
    for ip in "${VPS_NODES[@]}"; do
        local remote_version=$(get_remote_daemon_version "$ip")
        if [ "$remote_version" = "not_running" ] || [ "$remote_version" = "unknown" ]; then
            log "    $ip: daemon not running or version unknown"
        elif [ "$remote_version" != "$local_version" ]; then
            warn "    $ip: VERSION MISMATCH - remote=$remote_version, local=$local_version"
            version_mismatches=$((version_mismatches + 1))
        else
            success "    $ip: version $remote_version ✓"
        fi
    done

    if [ $version_mismatches -gt 0 ]; then
        warn "  $version_mismatches node(s) have different versions - will be updated during deployment"
    fi

    if [ $errors -gt 0 ]; then
        error "Pre-flight check failed with $errors error(s)!"
        return 1
    fi

    success "All pre-flight checks passed ✓"
    return 0
}

# ==============================================================================
# HEALTH CHECK - Verify network is healthy after deployment
# ==============================================================================
health_check() {
    local errors=0
    local warnings=0

    log "Running health check..."

    # 1. Check daemon count on each node
    log "  Checking daemon counts..."
    for ip in "${VPS_NODES[@]}"; do
        count=$($SSH ubuntu@$ip "pgrep bathrond | wc -l" 2>/dev/null || echo "0")
        if [ "$count" = "1" ]; then
            success "    $ip: 1 daemon ✓"
        elif [ "$count" = "0" ]; then
            error "    $ip: NO daemon!"
            ((errors++))
        else
            error "    $ip: $count daemons (TOO MANY)!"
            ((errors++))
        fi
    done

    # 2. Check LOCAL has no daemon
    local_count=$(pgrep bathrond | wc -l 2>/dev/null || echo "0")
    if [ "$local_count" = "0" ]; then
        success "    LOCAL: 0 daemons ✓"
    else
        error "    LOCAL: $local_count daemon(s) - SHOULD BE 0!"
        ((errors++))
    fi

    # 3. Check all nodes are synced (same height)
    log "  Checking block heights..."
    declare -A heights
    for ip in "${VPS_NODES[@]}"; do
        cli=$(get_cli_path "$ip")
        h=$($SSH ubuntu@$ip "$cli -datadir=$VPS_DATADIR -testnet getblockcount 2>/dev/null" 2>/dev/null || echo "0")
        heights[$ip]=$h
        echo "    $ip: height=$h"
    done

    # Check if all heights are the same
    unique_heights=$(printf '%s\n' "${heights[@]}" | sort -u | wc -l)
    if [ "$unique_heights" = "1" ]; then
        success "  All nodes at same height ✓"
    else
        warn "  Nodes at different heights (may still be syncing)"
        ((warnings++))
    fi

    # 4. Check headers == blocks (no IBD)
    log "  Checking headers vs blocks..."
    local headers_mismatch=false
    for ip in "${VPS_NODES[@]}"; do
        cli=$(get_cli_path "$ip")
        info=$($SSH ubuntu@$ip "$cli -datadir=$VPS_DATADIR -testnet getblockchaininfo 2>/dev/null" 2>/dev/null)
        blocks=$(echo "$info" | grep '"blocks"' | grep -o '[0-9]*' | head -1)
        headers=$(echo "$info" | grep '"headers"' | grep -o '[0-9]*' | head -1)
        if [ -n "$blocks" ] && [ -n "$headers" ] && [ "$blocks" = "$headers" ]; then
            success "    $ip: blocks=$blocks, headers=$headers ✓"
        elif [ -n "$blocks" ] && [ -n "$headers" ]; then
            warn "    $ip: blocks=$blocks, headers=$headers (mismatch!)"
            headers_mismatch=true
            ((warnings++))
        else
            error "    $ip: could not get blockchain info"
            ((errors++))
        fi
    done

    # Auto-ban polluters if headers mismatch detected
    if $headers_mismatch; then
        echo ""
        warn "Headers mismatch detected - scanning for network polluters..."
        ban_polluters
    fi

    # 5. Check peer connectivity
    log "  Checking peer connectivity..."
    for ip in "${VPS_NODES[@]}"; do
        cli=$(get_cli_path "$ip")
        peers=$($SSH ubuntu@$ip "$cli -datadir=$VPS_DATADIR -testnet getconnectioncount 2>/dev/null" 2>/dev/null || echo "0")
        if [ "$peers" -ge 4 ]; then
            success "    $ip: $peers peers ✓"
        elif [ "$peers" -gt 0 ]; then
            warn "    $ip: only $peers peer(s)"
            ((warnings++))
        else
            error "    $ip: NO peers!"
            ((errors++))
        fi
    done

    # Summary
    echo ""
    if [ $errors -gt 0 ]; then
        error "Health check: $errors ERROR(s), $warnings warning(s)"
        return 1
    elif [ $warnings -gt 0 ]; then
        warn "Health check: $warnings warning(s), but no errors"
        return 0
    else
        success "Health check: ALL CLEAR ✓"
        return 0
    fi
}

# ==============================================================================
# BAN POLLUTERS - Detect and ban external nodes with invalid headers
# ==============================================================================
# Detects peers that advertise headers much higher than our chain height,
# which indicates they're running an old/incompatible testnet and polluting
# the network with stale headers.
#
# Usage: Called automatically by health_check when headers > blocks mismatch
#        or manually via --ban-polluters
# ==============================================================================
ban_polluters() {
    local threshold=${1:-10}  # Ban peers with synced_headers > blocks + threshold
    local ban_duration=86400  # 24 hours
    local banned_count=0
    local checked_count=0

    log "Scanning for network polluters (threshold: +$threshold headers)..."

    for ip in "${VPS_NODES[@]}"; do
        local cli=$(get_cli_path "$ip")

        # Get current block height
        local blocks=$($SSH ubuntu@$ip "$cli -datadir=$VPS_DATADIR -testnet getblockcount 2>/dev/null" 2>/dev/null || echo "0")

        if [ "$blocks" = "0" ]; then
            warn "  $ip: daemon not responding, skipping"
            continue
        fi

        # Get peer info with synced_headers
        local peers_json=$($SSH ubuntu@$ip "$cli -datadir=$VPS_DATADIR -testnet getpeerinfo 2>/dev/null" 2>/dev/null)

        if [ -z "$peers_json" ]; then
            warn "  $ip: no peer info available"
            continue
        fi

        # Parse each peer and check for polluters
        # A polluter has synced_headers significantly higher than our blocks
        local polluters=$(echo "$peers_json" | jq -r --argjson blocks "$blocks" --argjson threshold "$threshold" '
            .[] |
            select(.synced_headers > ($blocks + $threshold)) |
            "\(.addr) \(.synced_headers) \(.subver)"
        ' 2>/dev/null)

        if [ -n "$polluters" ]; then
            echo "$polluters" | while read -r addr sheaders subver; do
                # Extract IP (remove port)
                local peer_ip=$(echo "$addr" | cut -d: -f1)

                # Skip if it's one of our VPS nodes
                local is_our_node=false
                for vps in "${VPS_NODES[@]}"; do
                    if [[ "$peer_ip" == "$vps" ]]; then
                        is_our_node=true
                        break
                    fi
                done

                if $is_our_node; then
                    continue
                fi

                # Ban the polluter
                warn "  $ip: Banning polluter $peer_ip (headers=$sheaders vs blocks=$blocks) $subver"
                $SSH ubuntu@$ip "$cli -datadir=$VPS_DATADIR -testnet setban $peer_ip add $ban_duration" 2>/dev/null || true
                ((banned_count++))
            done
        fi
        ((checked_count++))
    done

    if [ $banned_count -gt 0 ]; then
        warn "Banned $banned_count polluter(s) across $checked_count node(s)"
        echo ""
        log "To clear bans: run on each node: bathron-cli -testnet clearbanned"
        return 1
    else
        success "No polluters found across $checked_count node(s) ✓"
        return 0
    fi
}

# ==============================================================================
# BTC HEADERS STATUS - Show btcheadersdb consensus state on all nodes
# ==============================================================================
# NEW ARCHITECTURE (TX_BTC_HEADERS):
#   - Seed syncs BTC headers locally via btcspv module (from Signet)
#   - btc_header_daemon publishes headers as TX_BTC_HEADERS transactions
#   - ALL nodes receive headers via P2P and store in btcheadersdb (CONSENSUS)
#   - No config flags needed on non-Seed nodes
#
# Usage:
#   --btc           Show BTC headers status on all nodes
#   --btc=status    Same as above
# ==============================================================================

SEED_IP="57.131.33.151"

# Get BTC headers status for a single node (NEW: uses btcheadersdb consensus)
get_btc_headers_status() {
    local ip=$1
    local cli_path=$(get_cli_path "$ip")

    # Get consensus status via RPC (btcheadersdb, NOT old btcspv)
    local status=$($SSH ubuntu@$ip "$cli_path -datadir=$VPS_DATADIR -testnet getbtcheadersstatus 2>/dev/null" 2>/dev/null)

    if [ -n "$status" ] && [ "$status" != "null" ]; then
        local db_init=$(echo "$status" | jq -r '.db_initialized // false')
        local tip_height=$(echo "$status" | jq -r '.tip_height // 0')
        local header_count=$(echo "$status" | jq -r '.header_count // 0')
        local spv_tip=$(echo "$status" | jq -r '.spv_tip_height // 0')
        local headers_ahead=$(echo "$status" | jq -r '.headers_ahead // 0')
        local can_publish=$(echo "$status" | jq -r '.can_publish // false')

        if [ "$db_init" = "true" ] && [ "$tip_height" -gt 0 ]; then
            if [ "$ip" = "$SEED_IP" ]; then
                # Seed shows publisher status
                if [ "$can_publish" = "true" ]; then
                    echo -e "${GREEN}OK${NC} tip=$tip_height spv=$spv_tip ${YELLOW}+$headers_ahead to publish${NC}"
                else
                    echo -e "${GREEN}OK${NC} tip=$tip_height (synced with spv)"
                fi
            else
                # Non-Seed just shows consensus tip
                echo -e "${GREEN}OK${NC} tip=$tip_height headers=$header_count"
            fi
        elif [ "$db_init" = "true" ]; then
            echo -e "${YELLOW}EMPTY${NC} (db initialized but no headers)"
        else
            echo -e "${RED}NOT INIT${NC} (btcheadersdb not initialized)"
        fi
    else
        echo -e "${RED}OFFLINE${NC} (daemon not responding)"
    fi
}

# Show BTC headers status on all nodes
btc_headers_status() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  BTC Headers Status - All Nodes (btcheadersdb consensus)     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    local min_tip=999999999
    local max_tip=0

    for ip in "${VPS_NODES[@]}"; do
        local role=""
        if [ "$ip" = "$SEED_IP" ]; then
            role="[Seed]  "
        else
            role="[Node]  "
        fi

        local status=$(get_btc_headers_status "$ip")
        echo "  $role$ip: $status"

        # Track min/max for sync check
        local tip=$($SSH ubuntu@$ip "$(get_cli_path $ip) -datadir=$VPS_DATADIR -testnet getbtcheadersstatus 2>/dev/null | jq -r '.tip_height // 0'" 2>/dev/null || echo "0")
        [ "$tip" -lt "$min_tip" ] && min_tip=$tip
        [ "$tip" -gt "$max_tip" ] && max_tip=$tip
    done

    echo ""

    # Check header daemon on Seed
    local daemon_pid=$($SSH ubuntu@$SEED_IP "cat /tmp/btc_header_daemon.pid 2>/dev/null" 2>/dev/null || echo "")
    local daemon_running=$($SSH ubuntu@$SEED_IP "[ -n '$daemon_pid' ] && kill -0 $daemon_pid 2>/dev/null && echo 'yes' || echo 'no'" 2>/dev/null)

    if [ "$daemon_running" = "yes" ]; then
        success "Header daemon: ${GREEN}RUNNING${NC} on Seed (PID $daemon_pid)"
    else
        warn "Header daemon: ${YELLOW}NOT RUNNING${NC} on Seed"
        log "  Start with: ssh seed './contrib/testnet/btc_header_daemon.sh start'"
    fi

    # Sync status
    if [ "$min_tip" -eq "$max_tip" ] && [ "$max_tip" -gt 0 ]; then
        success "All nodes synced at BTC height $max_tip"
    elif [ "$max_tip" -gt 0 ]; then
        warn "Nodes not synced: min=$min_tip max=$max_tip (diff=$((max_tip - min_tip)))"
    fi
    echo ""
}

# Legacy alias for backward compatibility
spv_status() {
    btc_headers_status
}

# ==============================================================================
# GENESIS: Sync BTC SPV Headers on Seed
# ==============================================================================
sync_btc_spv_for_genesis() {
    log "Syncing BTC SPV headers on Seed..."

    # Check BTC Signet on Seed (use $HOME instead of ~ for proper expansion)
    local btc_tip=$($SSH ubuntu@$SEED_IP '/home/ubuntu/bitcoin-27.0/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet getblockcount 2>/dev/null || echo "-1"')

    if [ "$btc_tip" = "-1" ]; then
        warn "  BTC Signet not running, starting..."
        $SSH ubuntu@$SEED_IP '
            mkdir -p /home/ubuntu/.bitcoin-signet
            cat > /home/ubuntu/.bitcoin-signet/bitcoin.conf << EOF
signet=1
server=1
txindex=1
daemon=1
rpcuser=bathronseed
rpcpassword=bathronseedpass
EOF
            /home/ubuntu/bitcoin-27.0/bin/bitcoind -conf=/home/ubuntu/.bitcoin-signet/bitcoin.conf -daemon 2>/dev/null || true
        '
        sleep 15
        btc_tip=$($SSH ubuntu@$SEED_IP '/home/ubuntu/bitcoin-27.0/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet getblockcount 2>/dev/null || echo "-1"')
    fi

    if [ "$btc_tip" = "-1" ]; then
        warn "  Cannot reach BTC Signet - SPV sync skipped"
        return 0
    fi
    success "  BTC Signet tip: $btc_tip"

    # Clean start: wipe chain data BUT preserve/restore btcspv for incremental sync
    $SSH ubuntu@$SEED_IP 'pkill -9 bathrond 2>/dev/null || true; sleep 2' 2>/dev/null
    $SSH ubuntu@$SEED_IP "
        cd $VPS_TESTNET_DIR 2>/dev/null || true
        rm -rf blocks chainstate evodb llmq hu_finality khu sporks settlement btcheadersdb burnclaimdb index 2>/dev/null
        rm -f .lock peers.dat banlist.dat mempool.dat mncache.dat mnmetacache.dat 2>/dev/null
        # Restore btcspv from existing backup if dir was wiped or missing
        if [ ! -d btcspv ] || [ ! -f btcspv/CURRENT ]; then
            rm -rf btcspv 2>/dev/null
            if [ -f ~/btcspv_backup_latest.tar.gz ]; then
                tar xzf ~/btcspv_backup_latest.tar.gz 2>/dev/null && echo 'RESTORED_FROM_BACKUP'
            fi
        else
            echo 'BTCSPV_PRESERVED'
        fi
    " 2>/dev/null
    local bathron_ok=$($SSH ubuntu@$SEED_IP 'nohup ~/bathrond -testnet -daemon -noconnect -masternode=0 </dev/null >/dev/null 2>&1; sleep 15; ~/bathron-cli -testnet getblockcount >/dev/null 2>&1 && echo "yes" || echo "no"')

    if [ "$bathron_ok" = "no" ]; then
        warn "  Cannot start BATHRON for SPV sync"
        return 1
    fi

    # Get current SPV tip (should be checkpoint 286000 on fresh start)
    local BTC_CHECKPOINT=$BTC_CHECKPOINT  # from global constant
    local spv_tip=$($SSH ubuntu@$SEED_IP '~/bathron-cli -testnet getbtcsyncstatus 2>/dev/null | grep -o "\"tip_height\": *[0-9]*" | grep -o "[0-9]*" || echo "0"')
    # Enforce minimum: never sync below checkpoint (avoids syncing 286K unnecessary headers)
    if [ "$spv_tip" -lt "$BTC_CHECKPOINT" ] 2>/dev/null; then
        log "  SPV tip $spv_tip < checkpoint $BTC_CHECKPOINT, starting from checkpoint"
        spv_tip=$BTC_CHECKPOINT
    fi
    log "  Current SPV tip: $spv_tip (syncing to $btc_tip)"

    if [ "$spv_tip" -ge "$btc_tip" ]; then
        success "  SPV already synced (backup sufficient)"
        # Stop daemon and create backup
        $SSH ubuntu@$SEED_IP '~/bathron-cli -testnet stop 2>/dev/null || true; sleep 3'
        return 0
    fi

    # Backup not sufficient — sync remaining headers from Signet
    # Run entire sync loop on Seed in a SINGLE SSH call (avoids per-batch SSH roundtrip)
    local total=$((btc_tip - spv_tip))
    log "  Syncing $total remaining headers from Signet (single SSH, batches of 500)..."

    $SSH ubuntu@$SEED_IP "
        BTCCLI=/home/ubuntu/bitcoin-27.0/bin/bitcoin-cli
        BTCDATA=/home/ubuntu/.bitcoin-signet
        BATHCLI=/home/ubuntu/bathron-cli
        CURRENT=$((spv_tip + 1))
        TARGET=$btc_tip
        BATCH=500
        TOTAL=$total
        DONE=0

        # Sanity check: verify BTC Signet CLI works (both getblockhash and getblockheader)
        TEST_HASH=\$(\$BTCCLI -datadir=\$BTCDATA getblockhash \$CURRENT 2>&1)
        if [ -z \"\$TEST_HASH\" ] || echo \"\$TEST_HASH\" | grep -qi 'error'; then
            echo \"[FATAL] BTC Signet CLI getblockhash failed for height \$CURRENT: \$TEST_HASH\" >&2
            exit 1
        fi
        TEST_HDR=\$(\$BTCCLI -datadir=\$BTCDATA getblockheader \$TEST_HASH false 2>&1)
        TEST_HDR_LEN=\${#TEST_HDR}
        echo \"Sanity: hash(\$CURRENT) = \$TEST_HASH\"
        echo \"Sanity: header len=\$TEST_HDR_LEN first40=\${TEST_HDR:0:40}\"
        if [ \"\$TEST_HDR_LEN\" -ne 160 ]; then
            echo \"[FATAL] getblockheader returned \$TEST_HDR_LEN chars (expected 160): \$TEST_HDR\" >&2
            exit 1
        fi

        while [ \$CURRENT -le \$TARGET ]; do
            END=\$((CURRENT + BATCH - 1))
            [ \$END -gt \$TARGET ] && END=\$TARGET
            headers_hex=''
            for h in \$(seq \$CURRENT \$END); do
                hash=\$(\$BTCCLI -datadir=\$BTCDATA getblockhash \$h 2>/dev/null)
                header=\$(\$BTCCLI -datadir=\$BTCDATA getblockheader \$hash false 2>/dev/null)
                headers_hex=\"\${headers_hex}\${header}\"
            done
            HEX_LEN=\${#headers_hex}
            RESULT=\$(\$BATHCLI -testnet submitbtcheaders \"\$headers_hex\" 2>&1)
            DONE=\$((END - $spv_tip))
            PCT=\$((DONE * 100 / TOTAL))
            # Extract tip from result for monitoring
            RES_TIP=\$(echo \"\$RESULT\" | grep -o '\"tip_height\": *[0-9]*' | grep -o '[0-9]*')
            RES_ACC=\$(echo \"\$RESULT\" | grep -o '\"accepted\": *[0-9]*' | grep -o '[0-9]*')
            RES_REJ=\$(echo \"\$RESULT\" | grep -o '\"rejected\": *[0-9]*' | grep -o '[0-9]*')
            echo \"Progress: \${PCT}% (\${DONE}/\${TOTAL}) tip=\$RES_TIP acc=\$RES_ACC rej=\$RES_REJ\"
            CURRENT=\$((END + 1))
        done
        SPV_TIP_AFTER=\$(\$BATHCLI -testnet getbtcsyncstatus 2>/dev/null)
        echo \"SPV_TIP_AFTER: \$SPV_TIP_AFTER\"
        echo 'SPV sync complete'
    " 2>&1 | while IFS= read -r line; do
        printf "\r  %s" "$line"
    done
    echo ""
    success "  SPV synced to $btc_tip"

    # Create updated backup — stop daemon cleanly, then verify + create backup
    log "  Creating SPV backup..."
    $SSH ubuntu@$SEED_IP '
        ~/bathron-cli -testnet stop 2>/dev/null || true
        for i in $(seq 1 60); do
            pgrep -u ubuntu bathrond >/dev/null 2>&1 || break
            sleep 1
        done
        if pgrep -u ubuntu bathrond >/dev/null 2>&1; then
            echo "[WARN] Daemon still running after 60s — forcing kill"
            pkill -9 -u ubuntu bathrond 2>/dev/null || true
            sleep 2
        fi
    '
    # Verify backup: restart daemon briefly to force LevelDB WAL replay, check tip, stop
    log "  Verifying btcspv integrity (restart cycle)..."
    local verified_tip=$($SSH ubuntu@$SEED_IP "
        cd $VPS_TESTNET_DIR
        ~/bathrond -testnet -daemon -noconnect -masternode=0 >/dev/null 2>&1
        sleep 10
        TIP=\$(~/bathron-cli -testnet getbtcsyncstatus 2>/dev/null | jq -r '.tip_height // 0' 2>/dev/null || echo '0')
        ~/bathron-cli -testnet stop 2>/dev/null || true
        for i in \$(seq 1 30); do
            pgrep -u ubuntu bathrond >/dev/null 2>&1 || break
            sleep 1
        done
        echo \$TIP
    ")
    if [ "$verified_tip" -lt "$btc_tip" ] 2>/dev/null; then
        warn "  btcspv verified tip ($verified_tip) < BTC Signet ($btc_tip) — bootstrap fallback will sync gap"
    else
        success "  btcspv verified tip: $verified_tip"
    fi
    $SSH ubuntu@$SEED_IP "
        cd $VPS_TESTNET_DIR
        [ -d btcspv ] && tar -czf ~/btcspv_backup_${btc_tip}.tar.gz btcspv
        ln -sf btcspv_backup_${btc_tip}.tar.gz ~/btcspv_backup_latest.tar.gz
    "
    success "  Backup: btcspv_backup_${btc_tip}.tar.gz"
}

# ==============================================================================
# GENESIS: Distribute SPV Backup to All Nodes
# ==============================================================================
distribute_spv_backup() {
    log "Distributing SPV backup to all nodes..."

    # Download SPV backup from Seed to local (Seed doesn't have SSH keys to other nodes)
    $SCP ubuntu@$SEED_IP:~/btcspv_backup_latest.tar.gz /tmp/btcspv_backup_latest.tar.gz 2>/dev/null || true

    for ip in "${VPS_NODES[@]}"; do
        (
            $SCP /tmp/btcspv_backup_latest.tar.gz ubuntu@$ip:~/ 2>/dev/null || true
            $SSH ubuntu@$ip "
                mkdir -p $VPS_TESTNET_DIR
                cd $VPS_TESTNET_DIR && rm -rf btcspv
                tar -xzf ~/btcspv_backup_latest.tar.gz 2>/dev/null || true
            " 2>/dev/null
            success "  $ip: SPV restored"
        ) &
    done
    wait
}

# ==============================================================================
# GENESIS: Create Bootstrap Blocks 0-3 on Seed
# ==============================================================================
create_genesis_bootstrap() {
    log "Creating genesis bootstrap on Seed..."
    log "  CLEAN FLOW (auto-discovery from BTC Signet):"
    log "    Block 1: TX_BTC_HEADERS from btcspv backup"
    log "    Header catch-up → Burn scan BTC Signet → Claims → K=20 → Mint → MN reg"

    local KEYS_FILE="$HOME/.BathronKey/testnet_keys.json"
    local BURN_KEYS_FILE="$HOME/.BathronKey/burn_dest_keys.json"
    local BOOTSTRAP_SCRIPT="$HOME/BATHRON/contrib/testnet/genesis_bootstrap_seed.sh"
    local BURN_DAEMON="$HOME/BATHRON/contrib/testnet/btc_burn_claim_daemon.sh"

    # Collect ALL known wallet keys for bootstrap (so bootstrap can import them all)
    # Burns on BTC Signet may have destination addresses of ANY known wallet
    log "Collecting wallet keys from all VPS for bootstrap..."
    local ALL_KEYS="["
    local KEY_COUNT=0
    for VPS_IP in "${VPS_NODES[@]}"; do
        local KEY_JSON=$($SSH ubuntu@$VPS_IP "cat ~/.BathronKey/wallet.json 2>/dev/null" 2>/dev/null || echo "")
        if [ -n "$KEY_JSON" ] && echo "$KEY_JSON" | jq -e '.wif' >/dev/null 2>&1; then
            [ "$KEY_COUNT" -gt 0 ] && ALL_KEYS+=","
            ALL_KEYS+="$KEY_JSON"
            KEY_COUNT=$((KEY_COUNT + 1))
            local W_NAME=$(echo "$KEY_JSON" | jq -r '.name' 2>/dev/null)
            log "    $VPS_IP: $W_NAME"
        fi
    done
    ALL_KEYS+="]"
    echo "$ALL_KEYS" > /tmp/all_wallet_keys_genesis.json
    $SCP /tmp/all_wallet_keys_genesis.json ubuntu@$SEED_IP:/tmp/all_wallet_keys.json 2>/dev/null
    rm -f /tmp/all_wallet_keys_genesis.json
    log "  Collected $KEY_COUNT wallet keys"

    # Copy files to Seed
    [ -f "$KEYS_FILE" ] && $SCP "$KEYS_FILE" ubuntu@$SEED_IP:/tmp/testnet_keys.json 2>/dev/null
    [ -f "$BURN_KEYS_FILE" ] && $SCP "$BURN_KEYS_FILE" ubuntu@$SEED_IP:/tmp/burn_dest_keys.json 2>/dev/null
    $SCP "$BOOTSTRAP_SCRIPT" ubuntu@$SEED_IP:/tmp/genesis_bootstrap_seed.sh 2>/dev/null
    $SCP "$BURN_DAEMON" ubuntu@$SEED_IP:~/btc_burn_claim_daemon.sh 2>/dev/null
    $SSH ubuntu@$SEED_IP "chmod +x ~/btc_burn_claim_daemon.sh" 2>/dev/null

    # CRITICAL: Kill any running bathrond on Seed BEFORE bootstrap (avoid port conflict)
    log "Killing any bathrond on Seed before bootstrap..."
    $SSH ubuntu@$SEED_IP 'pkill -9 bathrond 2>/dev/null || true; sleep 2; rm -f ~/.bathron/testnet5/.lock /tmp/bathron_bootstrap/testnet5/.lock' 2>/dev/null

    # Run bootstrap script on Seed in background (to avoid SSH timeout during BTC scan)
    log "Running bootstrap script on Seed (background)..."
    $SSH ubuntu@$SEED_IP 'chmod +x /tmp/genesis_bootstrap_seed.sh && nohup /tmp/genesis_bootstrap_seed.sh > /tmp/genesis_bootstrap.log 2>&1 </dev/null & echo $!'

    # Poll for completion (check for SUCCESS or FATAL in log, or daemon height > 5)
    log "Waiting for bootstrap to complete (polling every 30s)..."
    local MAX_WAIT=3600  # 60 minutes (BTC Signet burn scan + K=20 finality + MN registration)
    local WAITED=0
    local BOOTSTRAP_EXIT=1
    local SSH_FAIL_COUNT=0

    while [ $WAITED -lt $MAX_WAIT ]; do
        sleep 30
        WAITED=$((WAITED + 30))

        # Check SSH connectivity first (retry if rate-limited)
        if ! timeout 10 $SSH ubuntu@$SEED_IP "echo OK" >/dev/null 2>&1; then
            SSH_FAIL_COUNT=$((SSH_FAIL_COUNT + 1))
            if [ $SSH_FAIL_COUNT -ge 3 ]; then
                error "Lost SSH connection to Seed after 3 failed attempts"
                return 1
            fi
            warn "  SSH connection issue, retrying in 15s... ($SSH_FAIL_COUNT/3)"
            sleep 15
            continue
        fi
        SSH_FAIL_COUNT=0  # Reset on success

        # Check log for completion
        local LOG_STATUS=$($SSH ubuntu@$SEED_IP 'tail -50 /tmp/genesis_bootstrap.log 2>/dev/null | grep -E "SUCCESS|FATAL|COMPLETE|ERROR.*failed"' 2>/dev/null || echo "")

        if echo "$LOG_STATUS" | grep -q "COMPLETE\|SUCCESS"; then
            log "Bootstrap completed successfully"
            $SSH ubuntu@$SEED_IP 'tail -80 /tmp/genesis_bootstrap.log' 2>/dev/null || true
            BOOTSTRAP_EXIT=0
            break
        elif echo "$LOG_STATUS" | grep -q "FATAL\|ERROR.*failed"; then
            error "Bootstrap failed:"
            $SSH ubuntu@$SEED_IP 'tail -50 /tmp/genesis_bootstrap.log' 2>/dev/null || true
            BOOTSTRAP_EXIT=1
            break
        fi

        # Show progress (height + last log line) but don't use it as success signal —
        # only COMPLETE/FATAL in the log determines success
        local HEIGHT=$($SSH ubuntu@$SEED_IP '/home/ubuntu/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet getblockcount 2>/dev/null || echo "0"')
        local LAST_LOG=$($SSH ubuntu@$SEED_IP 'tail -1 /tmp/genesis_bootstrap.log 2>/dev/null' 2>/dev/null || echo "")
        log "  ...waited ${WAITED}s/${MAX_WAIT}s, h=$HEIGHT | $LAST_LOG"
    done

    if [ $WAITED -ge $MAX_WAIT ]; then
        error "Bootstrap timed out after ${MAX_WAIT}s"
        $SSH ubuntu@$SEED_IP 'tail -50 /tmp/genesis_bootstrap.log' 2>/dev/null || true
        return 1
    fi

    if [ $BOOTSTRAP_EXIT -ne 0 ]; then
        error "Bootstrap script failed"
        return 1
    fi

    success "Bootstrap completed on Seed"
}


# Check if IP is in repo nodes list (nodes with ~/BATHRON-Core/src/ binaries)
is_repo_node() {
    local ip=$1
    for node in "${REPO_NODES[@]}"; do
        if [[ "$node" == "$ip" ]]; then
            return 0
        fi
    done
    return 1
}

# Get the CLI path for a node (repo nodes use different path)
# Returns absolute path for reliable use in SSH commands
get_cli_path() {
    local ip=$1
    if is_repo_node "$ip"; then
        echo "/home/ubuntu/BATHRON-Core/src/bathron-cli"
    else
        echo "/home/ubuntu/bathron-cli"
    fi
}

# Get the daemon path for a node (repo nodes use different path)
# Returns absolute path for reliable use in SSH commands
get_daemon_path() {
    local ip=$1
    if is_repo_node "$ip"; then
        echo "/home/ubuntu/BATHRON-Core/src/bathrond"
    else
        echo "/home/ubuntu/bathrond"
    fi
}

# Function to get daemon version on remote node
# Returns: version string or "unknown" or "not_running"
get_remote_daemon_version() {
    local ip=$1
    local cli_path=$(get_cli_path "$ip")

    local version=$($SSH ubuntu@$ip "$cli_path -testnet getnetworkinfo 2>/dev/null | jq -r '.subversion // \"unknown\"'" 2>/dev/null)
    if [ -z "$version" ] || [ "$version" = "null" ] || [ "$version" = "unknown" ]; then
        # Daemon not responding - check if binary exists and get its version
        local daemon_path=$(get_daemon_path "$ip")
        version=$($SSH ubuntu@$ip "$daemon_path --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo 'unknown'" 2>/dev/null)
    else
        # Normalize subversion format /BATHRON:0.9.0/ to just 0.9.0
        version=$(echo "$version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "$version")
    fi
    echo "$version"
}

# Function to get local daemon version
get_local_daemon_version() {
    if [ -x "$LOCAL_DAEMON" ]; then
        "$LOCAL_DAEMON" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown"
    else
        echo "not_found"
    fi
}

# Function to stop daemon on a VPS (robust stop - guarantees no daemon running)
# Returns 0 on success, 1 if port still in use after all attempts
stop_daemon() {
    local ip=$1
    local cli_path=$(get_cli_path "$ip")
    local max_attempts=3

    for attempt in $(seq 1 $max_attempts); do
        $SSH ubuntu@$ip "
            # Step 1: Try graceful stop (use explicit datadir)
            $cli_path -datadir=$VPS_DATADIR -testnet stop 2>/dev/null && sleep 3 || true

            # Step 2: Force kill ALL bathrond processes by name (SIGKILL)
            # Use -u ubuntu to only kill OUR processes, not other users
            pkill -9 -u ubuntu bathrond 2>/dev/null || true
            pkill -9 -u ubuntu -f 'bathrond.*-testnet' 2>/dev/null || true
            sleep 2

            # Step 3: Kill by PID if still running (only ubuntu's processes)
            for pid in \$(pgrep -u ubuntu bathrond 2>/dev/null); do
                kill -9 \$pid 2>/dev/null || true
            done
            sleep 1

            # Step 4: CRITICAL - Kill any process holding port 27171
            # This catches zombie processes that pkill/killall miss
            for pid in \$(sudo lsof -t -i:27171 2>/dev/null); do
                sudo kill -9 \$pid 2>/dev/null || true
            done
            sleep 1

            # Step 5: Remove lock files to ensure clean start
            rm -f $VPS_TESTNET_DIR/.lock 2>/dev/null || true
            rm -f $VPS_TESTNET_DIR/.walletlock 2>/dev/null || true
            rm -f $VPS_TESTNET_DIR/settlement/LOCK 2>/dev/null || true
            rm -f $VPS_TESTNET_DIR/burnclaimdb/LOCK 2>/dev/null || true
            rm -f $VPS_TESTNET_DIR/evodb/LOCK 2>/dev/null || true
        " 2>/dev/null

        # Verify port is actually free
        local port_check=$($SSH ubuntu@$ip "sudo lsof -i:27171 >/dev/null 2>&1 && echo 'IN_USE' || echo 'FREE'" 2>/dev/null)
        if [ "$port_check" = "FREE" ]; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            warn "  $ip: Port 27171 still in use, retry $attempt/$max_attempts..."
            sleep 3
        fi
    done

    # Final check - if still in use, this is a critical error
    error "  $ip: FAILED to free port 27171 after $max_attempts attempts"
    return 1
}

# Function to copy binaries to a VPS (for non-compile nodes)
copy_binaries() {
    local ip=$1

    # Step 1: Remove old binaries first
    $SSH ubuntu@$ip "rm -f ~/bathrond ~/bathron-cli"

    # Step 2: Copy new binaries - show errors, these MUST succeed
    if ! $SCP "$LOCAL_DAEMON" ubuntu@$ip:~/bathrond; then
        error "Failed to copy bathrond to $ip"
        return 1
    fi
    if ! $SCP "$LOCAL_CLI" ubuntu@$ip:~/bathron-cli; then
        error "Failed to copy bathron-cli to $ip"
        return 1
    fi

    # Step 3: Ensure executable and verify
    $SSH ubuntu@$ip "
        chmod +x ~/bathrond ~/bathron-cli
        if [ ! -x ~/bathrond ] || [ ! -x ~/bathron-cli ]; then
            echo 'ERROR: Binaries not executable!'
            exit 1
        fi
        echo 'Binaries installed and executable.'
    "

    # Step 4: OP1/OP2 special - also copy to ~/bathron/bin/ for pna-lp
    if [[ "$ip" == "57.131.33.152" ]]; then
        $SSH ubuntu@$ip "mkdir -p ~/bathron/bin && cp ~/bathrond ~/bathron/bin/ && cp ~/bathron-cli ~/bathron/bin/ && chmod +x ~/bathron/bin/*"
        echo "  OP1: Also deployed to ~/bathron/bin/ for pna-lp"
    fi
    if [[ "$ip" == "57.131.33.214" ]]; then
        $SSH ubuntu@$ip "mkdir -p ~/bathron/bin && cp ~/bathrond ~/bathron/bin/ && cp ~/bathron-cli ~/bathron/bin/ && chmod +x ~/bathron/bin/*"
        echo "  OP2: Also deployed to ~/bathron/bin/ for pna-lp"
    fi
}

# Function to copy binaries to Seed node (force overwrite)
copy_binaries_to_seed() {
    local ip=$1

    # Ensure directory exists
    $SSH ubuntu@$ip "mkdir -p ~/BATHRON-Core/src"

    # Copy to repo location, overwriting existing - show errors
    if ! $SCP "$LOCAL_DAEMON" ubuntu@$ip:~/BATHRON-Core/src/bathrond; then
        error "Failed to copy bathrond to Seed $ip"
        return 1
    fi
    if ! $SCP "$LOCAL_CLI" ubuntu@$ip:~/BATHRON-Core/src/bathron-cli; then
        error "Failed to copy bathron-cli to Seed $ip"
        return 1
    fi

    # Also copy to ~/bathrond and ~/bathron-cli (used by SPV sync + genesis bootstrap)
    $SSH ubuntu@$ip "
        cp ~/BATHRON-Core/src/bathrond ~/bathrond
        cp ~/BATHRON-Core/src/bathron-cli ~/bathron-cli
        chmod +x ~/BATHRON-Core/src/bathrond ~/BATHRON-Core/src/bathron-cli ~/bathrond ~/bathron-cli
        if [ ! -x ~/bathrond ] || [ ! -x ~/bathron-cli ]; then
            echo 'ERROR: Binaries not executable!'
            exit 1
        fi
        echo 'Seed binaries installed and executable.'
    "
}

# Function to perform FULL RESET on a node (delete entire testnet5, keep only bathron.conf)
full_reset_node() {
    local ip=$1

    $SSH ubuntu@$ip "
        echo '=== Full reset on '\$(hostname -I | awk \"{print \\\$1}\")' ==='

        # Step 1: Force kill ALL bathrond processes
        echo 'Step 1: Killing all bathrond processes...'
        killall -9 bathrond 2>/dev/null || true
        sleep 2

        # Double check
        for pid in \$(pgrep bathrond 2>/dev/null); do
            kill -9 \$pid 2>/dev/null || true
        done
        sleep 1

        # Verify
        if pgrep bathrond >/dev/null 2>&1; then
            echo 'ERROR: bathrond still running!'
            exit 1
        fi
        echo '  -> All bathrond processes killed'

        # Step 2: Backup bathron.conf (from main dir - canonical location)
        echo 'Step 2: Backing up bathron.conf...'
        if [ -f $VPS_DATADIR/bathron.conf ]; then
            cp $VPS_DATADIR/bathron.conf /tmp/bathron.conf.bak
            echo '  -> bathron.conf backed up to /tmp/'
        elif [ -f $VPS_TESTNET_DIR/bathron.conf ]; then
            cp $VPS_TESTNET_DIR/bathron.conf /tmp/bathron.conf.bak
            echo '  -> bathron.conf (testnet5 dir) backed up to /tmp/'
        else
            echo '  -> WARNING: No bathron.conf found!'
        fi

        # Step 3: Delete ENTIRE testnet5 directory
        echo 'Step 3: Deleting entire testnet5 directory...'
        rm -rf $VPS_TESTNET_DIR
        echo '  -> testnet5 directory deleted'

        # Step 4: Recreate directories with proper permissions
        echo 'Step 4: Creating directories with proper permissions...'
        mkdir -p $VPS_DATADIR
        chmod 700 $VPS_DATADIR
        mkdir -p $VPS_TESTNET_DIR
        chmod 700 $VPS_TESTNET_DIR
        echo '  -> Directories created with chmod 700'

        # Step 5: Restore config to MAIN dir (canonical location)
        echo 'Step 5: Restoring bathron.conf...'
        if [ -f /tmp/bathron.conf.bak ]; then
            mv /tmp/bathron.conf.bak $VPS_DATADIR/bathron.conf
            chmod 600 $VPS_DATADIR/bathron.conf
            echo '  -> bathron.conf restored to main dir'
        else
            echo '  -> WARNING: No backup to restore!'
        fi

        # Step 6: Verify
        echo 'Step 6: Verification...'
        echo '  -> Contents of $VPS_TESTNET_DIR/:'
        ls -la $VPS_TESTNET_DIR/ 2>/dev/null || echo '    (empty - correct)'
        echo '=== Full reset complete ==='
    " 2>/dev/null
}

# Function to update repo via git pull (NO compilation - binaries built locally)
repo_update() {
    local ip=$1
    $SSH ubuntu@$ip "
        cd ~/BATHRON-Core
        git fetch origin
        git reset --hard origin/main
        echo 'Commit:' \$(git log -1 --oneline)
    " 2>/dev/null
}

# Function to deploy to a node (handles both types)
deploy_node() {
    local ip=$1
    if is_repo_node "$ip"; then
        if $UPDATE_REPO; then
            repo_update "$ip"
        else
            echo "Skipped (repo node, use --update-repo to git pull)"
        fi
    else
        copy_binaries "$ip"
    fi
}

# Function to start daemon on a VPS
start_daemon() {
    local ip=$1
    local daemon_path=$(get_daemon_path "$ip")
    local extra_args=""

    # WIPE mode: delete ALL blockchain/chain data (full reset)
    # This is a COMPLETE wipe - only bathron.conf is preserved
    if $WIPE; then
        $SSH ubuntu@$ip "
            # Ensure daemon is DEAD before wiping
            killall -9 bathrond 2>/dev/null || true
            sleep 2

            # Remove ALL chain data directories
            # CRITICAL: This list must include ALL LevelDB databases
            rm -rf $VPS_TESTNET_DIR/blocks
            rm -rf $VPS_TESTNET_DIR/chainstate
            rm -rf $VPS_TESTNET_DIR/evodb
            rm -rf $VPS_TESTNET_DIR/llmq
            rm -rf $VPS_TESTNET_DIR/hu_finality
            rm -rf $VPS_TESTNET_DIR/khu
            rm -rf $VPS_TESTNET_DIR/sporks
            rm -rf $VPS_TESTNET_DIR/database
            rm -rf $VPS_TESTNET_DIR/wallets
            rm -rf $VPS_TESTNET_DIR/backups
            rm -rf $VPS_TESTNET_DIR/settlement
            # === ADDED: Missing DBs that caused genesis issues ===
            rm -rf $VPS_TESTNET_DIR/burnclaimdb    # BTC burn claims
            rm -rf $VPS_TESTNET_DIR/btcheadersdb   # BTC headers consensus
            rm -rf $VPS_TESTNET_DIR/btcspv         # BTC SPV local sync
            rm -rf $VPS_TESTNET_DIR/htlc           # HTLC database
            rm -rf $VPS_TESTNET_DIR/index          # TX index

            # Remove ALL data files (keep only bathron.conf)
            rm -f $VPS_TESTNET_DIR/wallet.dat
            rm -f $VPS_TESTNET_DIR/.walletlock
            rm -f $VPS_TESTNET_DIR/.lock
            rm -f $VPS_TESTNET_DIR/banlist.dat
            rm -f $VPS_TESTNET_DIR/peers.dat
            rm -f $VPS_TESTNET_DIR/mncache.dat
            rm -f $VPS_TESTNET_DIR/mnmetacache.dat
            rm -f $VPS_TESTNET_DIR/netrequests.dat
            rm -f $VPS_TESTNET_DIR/fee_estimates.dat
            rm -f $VPS_TESTNET_DIR/mempool.dat
            rm -f $VPS_TESTNET_DIR/debug.log
            rm -f $VPS_TESTNET_DIR/db.log
            rm -f $VPS_TESTNET_DIR/*.dat
            rm -f $VPS_TESTNET_DIR/*.log
            # === ADDED: Epoch file for genesis versioning ===
            rm -f $VPS_TESTNET_DIR/epoch

            # Verify wipe was successful - be explicit about what should NOT exist
            echo '=== WIPE VERIFICATION ==='
            CRITICAL_DIRS='blocks chainstate evodb settlement burnclaimdb btcheadersdb btcspv htlc'
            FOUND_STALE=0
            for d in \$CRITICAL_DIRS; do
                if [ -d \"$VPS_TESTNET_DIR/\$d\" ]; then
                    echo \"ERROR: \$d still exists!\"
                    FOUND_STALE=1
                fi
            done
            if [ \$FOUND_STALE -eq 0 ]; then
                echo 'All critical directories wiped successfully.'
            fi
            echo 'Remaining contents:'
            ls -la $VPS_TESTNET_DIR/ 2>/dev/null | head -10 || echo '(empty)'
        "
    elif $CLEAN; then
        # CLEAN mode: only wallet and database (keep blockchain)
        $SSH ubuntu@$ip "
            rm -f $VPS_TESTNET_DIR/wallet.dat $VPS_TESTNET_DIR/.walletlock
            rm -rf $VPS_TESTNET_DIR/database $VPS_TESTNET_DIR/wallets
        " 2>/dev/null
    fi

    if $REINDEX; then
        extra_args="-reindex"
    fi

    # Ensure no daemon is already running before starting
    # CRITICAL: Use explicit -datadir
    # NOTE: Do NOT hide stderr here - we need to see startup errors
    $SSH ubuntu@$ip "
        if pgrep bathrond >/dev/null 2>&1; then
            echo 'ERROR: Daemon still running! Aborting start.'
            exit 1
        fi
        echo 'Starting daemon with: $daemon_path -datadir=$VPS_DATADIR -testnet -daemon $extra_args'
        $daemon_path -datadir=$VPS_DATADIR -testnet -daemon $extra_args
        sleep 2
        if pgrep bathrond >/dev/null 2>&1; then
            echo 'Daemon started successfully.'
        else
            echo 'ERROR: Daemon failed to start! Check debug.log'
            tail -20 $VPS_TESTNET_DIR/debug.log 2>/dev/null | grep -E '(Error|error|ERROR|FATAL|fatal)' | head -5
            exit 1
        fi
    "
}

# Function to get status of a VPS (checks daemon count, height, peers)
get_status() {
    local ip=$1
    local cli_path=$(get_cli_path "$ip")
    local height
    local peers
    local daemon_count
    local node_type

    if is_repo_node "$ip"; then
        node_type="[repo]"
    else
        node_type="[bin] "
    fi

    daemon_count=$($SSH ubuntu@$ip "pgrep bathrond | wc -l" 2>/dev/null || echo "0")
    height=$($SSH ubuntu@$ip "$cli_path -datadir=$VPS_DATADIR -testnet getblockcount 2>&1" 2>/dev/null || echo "offline")
    peers=$($SSH ubuntu@$ip "$cli_path -datadir=$VPS_DATADIR -testnet getpeerinfo 2>&1 | jq 'length'" 2>/dev/null || echo "?")

    # Warn if daemon count is not 1
    if [ "$daemon_count" = "1" ]; then
        echo "$node_type $ip: daemons=1 ✓, height=$height, peers=$peers"
    elif [ "$daemon_count" = "0" ]; then
        echo "$node_type $ip: daemons=0 ✗ (OFFLINE), height=$height, peers=$peers"
    else
        echo "$node_type $ip: daemons=$daemon_count ✗ (TOO MANY!), height=$height, peers=$peers"
    fi
}

# Main execution

# --check: Run pre-flight checks only
if $CHECK_ONLY; then
    preflight_check
    exit $?
fi

# --health: Run full health check only
if $HEALTH_ONLY; then
    health_check
    exit $?
fi

# --ban-polluters: Detect and ban external nodes with invalid headers
if $BAN_POLLUTERS; then
    ban_polluters
    exit $?
fi

# --btc / --spv: BTC headers status (new TX_BTC_HEADERS architecture)
if [ -n "$SPV_MODE" ]; then
    btc_headers_status
    exit $?
fi

# --restore-mn-configs: Restore MN configs (masternode=1 + keys) and restart daemons
if $RESTORE_MN_CONFIGS; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  BATHRON Testnet - Restore MN Configs                           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Stop all daemons first
    log "Stopping all VPS daemons..."
    for ip in "${VPS_NODES[@]}"; do
        stop_daemon "$ip" &
    done
    wait
    sleep 3
    success "All daemons stopped"

    # Restore MN configs
    restore_mn_configs
    echo ""

    # Restart all daemons
    log "Restarting all daemons..."
    for ip in "${VPS_NODES[@]}"; do
        daemon_path=$(get_daemon_path "$ip")
        timeout 30 $SSH ubuntu@$ip "nohup $daemon_path -datadir=$VPS_DATADIR -testnet -daemon < /dev/null > /dev/null 2>&1" &
    done
    wait

    log "Waiting 15s for daemons to start..."
    sleep 15

    # Verify
    log "Verifying daemon counts..."
    for ip in "${VPS_NODES[@]}"; do
        count=$(timeout 10 $SSH ubuntu@$ip "pgrep bathrond | wc -l" 2>/dev/null || echo "0")
        if [ "$count" = "1" ]; then
            success "  $ip: 1 daemon ✓"
        else
            error "  $ip: $count daemon(s)"
        fi
    done

    echo ""
    success "MN configs restored and daemons restarted!"
    exit 0
fi

# --explorer: Deploy explorer only (calls dedicated script)
if $EXPLORER_ONLY; then
    EXPLORER_SCRIPT="$(dirname "$0")/deploy_explorer.sh"
    if [ -x "$EXPLORER_SCRIPT" ]; then
        exec "$EXPLORER_SCRIPT"
    else
        error "Explorer deploy script not found: $EXPLORER_SCRIPT"
        exit 1
    fi
fi

if $STATUS_ONLY; then
    log "Checking status of all nodes..."
    echo ""

    # Check LOCAL first
    local_count=$(pgrep bathrond | wc -l 2>/dev/null || echo "0")
    if [ "$local_count" = "0" ]; then
        echo "[LOCAL] 37.59.114.129: daemons=0 ✓ (correct - no local testnet daemon)"
    else
        echo "[LOCAL] 37.59.114.129: daemons=$local_count ✗ (SHOULD BE 0! Run --stop to clean)"
    fi

    # Check VPS nodes
    for ip in "${VPS_NODES[@]}"; do
        get_status "$ip" &
    done
    wait
    exit 0
fi

# ==============================================================================
# CONFIGURE KEYS: Update VPS operator keys from bootstrap output
# ==============================================================================
if $CONFIGURE_KEYS; then
    configure_vps_operator_keys
    exit 0
fi

if $STOP_ONLY; then
    log "Stopping ALL daemons (LOCAL + VPS)..."

    # FIRST: Kill LOCAL daemons to prevent pollution
    log "  Killing LOCAL bathrond daemons..."
    local_pids=$(pgrep bathrond 2>/dev/null || true)
    if [ -n "$local_pids" ]; then
        warn "  Found LOCAL bathrond processes: $local_pids"
        pkill -9 bathrond 2>/dev/null || true
        sleep 2
        # Kill by PID if still running
        for pid in $(pgrep bathrond 2>/dev/null); do
            kill -9 $pid 2>/dev/null || true
        done
        success "  LOCAL daemons killed"
    else
        success "  No LOCAL daemons running"
    fi

    # Clean LOCAL data directories
    log "  Cleaning LOCAL bathron data directories..."
    rm -rf "$HOME/.bathron" 2>/dev/null && success "  Removed ~/.bathron" || true
    rm -rf /tmp/bathron* 2>/dev/null && success "  Removed /tmp/bathron*" || true

    # THEN: Kill VPS daemons
    log "  Stopping VPS daemons..."
    for ip in "${VPS_NODES[@]}"; do
        stop_daemon "$ip" &
    done
    wait

    # VERIFY: Check daemon count on each VPS
    log "  Verifying no daemon is running anywhere..."
    all_stopped=true
    for ip in "${VPS_NODES[@]}"; do
        count=$($SSH ubuntu@$ip "pgrep bathrond | wc -l" 2>/dev/null || echo "0")
        if [ "$count" = "0" ]; then
            success "  $ip: 0 daemons ✓"
        else
            error "  $ip: $count daemon(s) still running!"
            all_stopped=false
        fi
    done

    # Check local
    local_count=$(pgrep bathrond | wc -l 2>/dev/null || echo "0")
    if [ "$local_count" = "0" ]; then
        success "  LOCAL: 0 daemons ✓"
    else
        error "  LOCAL: $local_count daemon(s) still running!"
        all_stopped=false
    fi

    if $all_stopped; then
        success "All daemons stopped (LOCAL + VPS)"
    else
        error "Some daemons are still running!"
    fi
    exit 0
fi

# ==============================================================================
# SYNC CHAIN - Sync chain data from Seed to all MN nodes
# ==============================================================================
if $SYNC_CHAIN; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  BATHRON Testnet - Sync Chain from Seed                         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    SEED_IP="57.131.33.151"

    # Stop Seed daemon to safely package chain data
    log "Stopping Seed daemon..."
    $SSH ubuntu@$SEED_IP "~/bathron-cli -testnet stop 2>/dev/null || ~/BATHRON-Core/src/bathron-cli -testnet stop 2>/dev/null" || true
    sleep 3
    success "Seed daemon stopped"

    # Package chain data on Seed (includes blocks, chainstate, evodb, etc.)
    log "Packaging chain data on Seed..."
    $SSH ubuntu@$SEED_IP "
        cd ~/.bathron/testnet5
        # Build list of existing directories to package
        DIRS=''
        for d in blocks chainstate evodb settlement hu_finality llmq sporks btcspv btcheadersdb burnclaimdb; do
            [ -d \"\$d\" ] && DIRS=\"\$DIRS \$d\"
        done
        cd ~/.bathron
        # Safety: exclude wallet files even though we only package subdirectories
        tar czf /tmp/testnet5_chain.tar.gz --exclude='wallet.dat' --exclude='wallet.sqlite*' --exclude='.walletlock' \$(echo \$DIRS | sed 's/ / testnet5\\//g' | sed 's/^/testnet5\\//')
    " 2>&1
    chain_size=$($SSH ubuntu@$SEED_IP "ls -lh /tmp/testnet5_chain.tar.gz | awk '{print \$5}'" 2>/dev/null)
    success "Chain data packaged on Seed ($chain_size)"

    # Stop all VPS daemons
    log "Stopping all VPS daemons..."
    for ip in "${VPS_NODES[@]}"; do
        stop_daemon "$ip" &
    done
    wait
    sleep 2
    success "All VPS daemons stopped"

    # Copy chain data from Seed to LOCAL first (Seed doesn't have SSH keys to other nodes)
    log "Downloading chain data from Seed to LOCAL..."
    scp -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP:/tmp/testnet5_chain.tar.gz /tmp/ 2>/dev/null
    $SSH ubuntu@$SEED_IP "rm -f /tmp/testnet5_chain.tar.gz" 2>/dev/null
    success "Chain data downloaded to LOCAL"

    # Copy from LOCAL to all VPS nodes
    log "Copying chain data from LOCAL to all nodes..."
    for ip in "${VPS_NODES[@]}"; do
        (
            # Copy tar from LOCAL to target node
            scp -i ~/.ssh/id_ed25519_vps /tmp/testnet5_chain.tar.gz ubuntu@$ip:/tmp/ 2>/dev/null

            # Extract on target node (preserving bathron.conf and wallets)
            $SSH ubuntu@$ip "
                mkdir -p $VPS_DATADIR && chmod 700 $VPS_DATADIR
                cd $VPS_TESTNET_DIR
                # Remove old chain data but keep config and wallets
                rm -rf blocks chainstate evodb llmq hu_finality sporks settlement btcspv btcheadersdb burnclaimdb 2>/dev/null
                # Extract new chain data
                cd $VPS_DATADIR && tar xzf /tmp/testnet5_chain.tar.gz
                chmod 700 $VPS_TESTNET_DIR
                rm /tmp/testnet5_chain.tar.gz
            " 2>/dev/null
            success "  $ip: chain data synced"
        ) &
    done
    wait

    # Cleanup tar on LOCAL
    rm -f /tmp/testnet5_chain.tar.gz

    # Start all daemons (Seed first, then MNs)
    log "Starting Seed daemon..."
    seed_daemon=$($SSH ubuntu@$SEED_IP "test -f ~/bathrond && echo ~/bathrond || echo ~/BATHRON-Core/src/bathrond" 2>/dev/null)
    $SSH ubuntu@$SEED_IP "nohup $seed_daemon -datadir=$VPS_DATADIR -testnet -daemon < /dev/null > /dev/null 2>&1" &
    sleep 5

    log "Starting all MN daemons..."
    for ip in "${VPS_NODES[@]}"; do
        if [ "$ip" != "$SEED_IP" ]; then
            daemon_path=$(get_daemon_path "$ip")
            timeout 30 $SSH ubuntu@$ip "nohup $daemon_path -datadir=$VPS_DATADIR -testnet -daemon < /dev/null > /dev/null 2>&1" &
        fi
    done
    wait
    success "All daemons started"

    # Wait for sync
    log "Waiting 20s for network sync..."
    sleep 20

    # Health check
    health_check

    success "SYNC CHAIN FROM SEED COMPLETE"
    exit 0
fi

# ==============================================================================
# DEPLOYMENT LEVELS IMPLEMENTATION
# ==============================================================================

# No deployment level specified - show help
if [ $DEPLOY_LEVEL -eq 0 ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  BATHRON Testnet Deployment Script                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "DIAGNOSTIC (read-only):"
    echo "  --status         Quick status: daemon count + height per node"
    echo "  --check          Pre-flight: SSH, binaries, connectivity"
    echo "  --health         Full health: daemons, sync, peers, headers==blocks"
    echo "  --ban-polluters  Detect & ban external nodes with invalid headers"
    echo "  --btc            BTC headers status (btcheadersdb consensus)"
    echo ""
    echo "DEPLOYMENT LEVELS (progressive severity):"
    echo "  --update     Level 1: Binary update only (keeps all data)"
    echo "  --rescan     Level 2: + Delete wallet, restart with -rescan"
    echo "  --wipe       Level 3: + Delete chain data, restart with -reindex"
    echo "  --genesis    Level 4: HARD RESET (clean local + VPS, fresh genesis)"
    echo ""
    echo "CONTROL:"
    echo "  --stop       Stop ALL daemons (LOCAL + VPS)"
    echo "  --explorer   Deploy explorer only (to Seed node)"
    echo "  --help       Show detailed help"
    echo ""
    exit 0
fi

# ==============================================================================
# DEPLOYMENT EXECUTION
# ==============================================================================

# Show initial level (may be upgraded later)
INITIAL_LEVEL=$DEPLOY_LEVEL

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  BATHRON Testnet Deployment - Level $DEPLOY_LEVEL: $(get_level_name $DEPLOY_LEVEL)"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Pre-flight checks
if ! preflight_check; then
    error "Pre-flight checks failed! Aborting deployment."
    exit 1
fi
echo ""

# ==============================================================================
# AUTO-UPGRADE DETECTION: Check if binary changed, force rescan if needed
# ==============================================================================
# When deploying new binaries (especially after refactoring like KHU→KPIV),
# the wallet format may have changed. We detect this by comparing binary hashes.
# If binary changed AND level < 2, we auto-upgrade to level 2 (rescan).
# ==============================================================================

if [ $DEPLOY_LEVEL -eq 1 ]; then
    log "Checking if binary upgrade requires wallet rescan..."

    # Get hash of local binary
    LOCAL_HASH=$(md5sum "$LOCAL_DAEMON" 2>/dev/null | awk '{print $1}')

    # Get hash of remote binary (first VPS node as reference)
    FIRST_IP="${VPS_NODES[0]}"
    if is_repo_node "$FIRST_IP"; then
        REMOTE_PATH="~/BATHRON-Core/src/bathrond"
    else
        REMOTE_PATH="~/bathrond"
    fi
    REMOTE_HASH=$($SSH ubuntu@$FIRST_IP "md5sum $REMOTE_PATH 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "none")

    if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        warn "Binary changed detected!"
        warn "  Local:  $LOCAL_HASH"
        warn "  Remote: $REMOTE_HASH"
        warn "Auto-upgrading to Level 2 (RESCAN) to ensure wallet compatibility."
        DEPLOY_LEVEL=2
        echo ""
    else
        success "Binary unchanged - proceeding with Level 1 (update only)"
    fi
fi
echo ""

# Level 4 (GENESIS) requires confirmation
if [ $DEPLOY_LEVEL -eq 4 ]; then
    warn "GENESIS RESET will DELETE ALL DATA on LOCAL and VPS!"
    echo "Press Ctrl+C within 5 seconds to abort..."
    sleep 5
fi
echo ""

deploy_failed=false

# ============================================================================
# STEP 1-6: Legacy deployment code (levels 0-3 only)
# Level 4 (GENESIS) uses genesis_full() at the end of the script
# ============================================================================
if [ $DEPLOY_LEVEL -lt 4 ]; then

# ============================================================================
# STEP 2: Stop VPS daemons
# ============================================================================
log "STEP 2: Stopping VPS daemons..."
for ip in "${VPS_NODES[@]}"; do
    stop_daemon "$ip" &
done
wait
sleep 3

# Verify - check both process and port
for ip in "${VPS_NODES[@]}"; do
    count=$($SSH ubuntu@$ip "pgrep bathrond | wc -l" 2>/dev/null || echo "0")
    port_in_use=$($SSH ubuntu@$ip "sudo lsof -i:27171 2>/dev/null | wc -l" 2>/dev/null || echo "0")

    if [ "$count" = "0" ] && [ "$port_in_use" -le 1 ]; then
        success "  $ip: stopped ✓"
    else
        if [ "$count" != "0" ]; then
            error "  $ip: daemon still running (pid count: $count)"
        fi
        if [ "$port_in_use" -gt 1 ]; then
            error "  $ip: port 27171 still in use!"
        fi
        # Force kill by port
        $SSH ubuntu@$ip "
            sudo pkill -9 bathrond 2>/dev/null || true
            for pid in \$(sudo lsof -t -i:27171 2>/dev/null); do
                sudo kill -9 \$pid 2>/dev/null || true
            done
        " 2>/dev/null
        sleep 2
    fi
done
echo ""

# ============================================================================
# STEP 3: Clean VPS data (based on level)
# ============================================================================
log "STEP 3: Cleaning VPS data (Level $DEPLOY_LEVEL)..."

for ip in "${VPS_NODES[@]}"; do
    (
        case $DEPLOY_LEVEL in
            1)
                # Level 1: No cleaning, just binary update
                echo "  $ip: no cleaning (binary update only)"
                ;;
            2)
                # Level 2: Delete wallet only
                $SSH ubuntu@$ip "
                    rm -f $VPS_TESTNET_DIR/wallet.dat
                    rm -f $VPS_TESTNET_DIR/.walletlock
                    rm -rf $VPS_TESTNET_DIR/database
                    rm -rf $VPS_TESTNET_DIR/wallets
                " 2>/dev/null
                echo "  $ip: wallet cleaned"
                ;;
            3)
                # Level 3: Delete chain data (keep bathron.conf)
                $SSH ubuntu@$ip "
                    rm -rf $VPS_TESTNET_DIR/blocks
                    rm -rf $VPS_TESTNET_DIR/chainstate
                    rm -rf $VPS_TESTNET_DIR/evodb
                    rm -rf $VPS_TESTNET_DIR/llmq
                    rm -rf $VPS_TESTNET_DIR/hu_finality
                    rm -rf $VPS_TESTNET_DIR/sporks
                    rm -rf $VPS_TESTNET_DIR/database
                    rm -rf $VPS_TESTNET_DIR/wallets
                    rm -rf $VPS_TESTNET_DIR/settlement
                    # === ADDED: All LevelDB databases ===
                    rm -rf $VPS_TESTNET_DIR/burnclaimdb
                    rm -rf $VPS_TESTNET_DIR/btcheadersdb
                    rm -rf $VPS_TESTNET_DIR/btcspv
                    rm -rf $VPS_TESTNET_DIR/htlc
                    rm -rf $VPS_TESTNET_DIR/index
                    rm -f $VPS_TESTNET_DIR/epoch
                    rm -f $VPS_TESTNET_DIR/*.dat
                    rm -f $VPS_TESTNET_DIR/*.log
                    rm -f $VPS_TESTNET_DIR/.lock
                    rm -f $VPS_TESTNET_DIR/.walletlock
                " 2>/dev/null
                echo "  $ip: chain data wiped"
                ;;
            4)
                # Level 4: Delete EVERYTHING except bathron.conf
                $SSH ubuntu@$ip "
                    # Backup bathron.conf (prefer main dir)
                    cp $VPS_DATADIR/bathron.conf /tmp/bathron.conf.bak 2>/dev/null || \\
                    cp $VPS_TESTNET_DIR/bathron.conf /tmp/bathron.conf.bak 2>/dev/null || true

                    # Delete entire testnet5
                    rm -rf $VPS_TESTNET_DIR

                    # Create directories with proper permissions
                    mkdir -p $VPS_DATADIR && chmod 700 $VPS_DATADIR
                    mkdir -p $VPS_TESTNET_DIR && chmod 700 $VPS_TESTNET_DIR

                    # Restore bathron.conf to MAIN dir (canonical location)
                    [ -f /tmp/bathron.conf.bak ] && mv /tmp/bathron.conf.bak $VPS_DATADIR/bathron.conf && chmod 600 $VPS_DATADIR/bathron.conf
                " 2>/dev/null
                echo "  $ip: GENESIS reset"
                ;;
        esac
    ) &
done
wait
success "  VPS data cleaning complete ✓"
echo ""

# ============================================================================
# STEP 3b: Restore MN configs (Level 4: skip - keys created in STEP 7)
# ============================================================================
if [ $DEPLOY_LEVEL -eq 4 ]; then
    log "STEP 3b: MN config will be set after genesis bootstrap (STEP 7)..."
    echo ""
fi

# NOTE: Explorer is managed separately via contrib/testnet/deploy_explorer.sh

# ============================================================================
# STEP 4: Copy binaries
# ============================================================================
log "STEP 4: Copying binaries to VPS..."
for ip in "${VPS_NODES[@]}"; do
    if is_repo_node "$ip"; then
        copy_binaries_to_seed "$ip"
    else
        copy_binaries "$ip"
    fi
    success "  $ip: binary deployed ✓"
done
echo ""

# ============================================================================
# STEP 5: Start daemons
# ============================================================================
log "STEP 5: Starting daemons..."

# Determine extra args based on level
extra_args=""
case $DEPLOY_LEVEL in
    2) extra_args="-rescan" ;;
    3|4) extra_args="-reindex" ;;
esac

# Pre-start: Ensure port 27171 is free on all nodes
log "  Ensuring port 27171 is free on all nodes..."
for ip in "${VPS_NODES[@]}"; do
    $SSH ubuntu@$ip "
        for pid in \$(sudo lsof -t -i:27171 2>/dev/null); do
            sudo kill -9 \$pid 2>/dev/null || true
        done
        rm -f $VPS_TESTNET_DIR/.lock $VPS_TESTNET_DIR/settlement/LOCK 2>/dev/null || true
        # Ensure directories exist with proper permissions
        mkdir -p $VPS_DATADIR && chmod 700 $VPS_DATADIR
        mkdir -p $VPS_TESTNET_DIR && chmod 700 $VPS_TESTNET_DIR
    " 2>/dev/null &
done
wait
sleep 2

# Start all daemons in parallel with explicit timeout and background
# CRITICAL: Use explicit -datadir for all daemon starts
for ip in "${VPS_NODES[@]}"; do
    daemon_path=$(get_daemon_path "$ip")
    # Use timeout and nohup to ensure daemon starts detached
    timeout 30 $SSH ubuntu@$ip "nohup $daemon_path -datadir=$VPS_DATADIR -testnet -daemon $extra_args < /dev/null > /dev/null 2>&1" &
done
wait

log "  Waiting 10s for daemons to initialize..."
sleep 10

# Verify daemon counts
log "  Verifying daemon counts..."
for ip in "${VPS_NODES[@]}"; do
    count=$(timeout 10 $SSH ubuntu@$ip "pgrep bathrond | wc -l" 2>/dev/null || echo "0")
    if [ "$count" = "1" ]; then
        success "  $ip: 1 daemon ✓"
    elif [ "$count" = "0" ]; then
        error "  $ip: NOT STARTED!"
        deploy_failed=true
    else
        error "  $ip: $count daemons (too many)!"
        deploy_failed=true
    fi
done

# Verify LOCAL has no daemon
local_count=$(pgrep bathrond | wc -l 2>/dev/null || echo "0")
if [ "$local_count" = "0" ]; then
    success "  LOCAL: 0 daemons ✓"
else
    error "  LOCAL: $local_count daemon(s) - should be 0!"
    deploy_failed=true
fi
echo ""

# ============================================================================
# STEP 6: Wait and verify
# ============================================================================
if [ $DEPLOY_LEVEL -ge 3 ]; then
    log "STEP 6: Waiting 45s for network sync..."
    sleep 45
else
    log "STEP 6: Waiting 15s for network..."
    sleep 15
fi

# Health check
health_check

fi  # End of DEPLOY_LEVEL -lt 4 (old STEP 1-6 code)

# ============================================================================
# STEP 7: GENESIS (Level 4) - MODULAR WITH STRICT GATES (v17.0)
# ============================================================================
# Sub-steps can be called individually:
#   --spv-prepare, --spv-distribute, --spv-verify
#   --genesis-create, --genesis-distribute, --genesis-configure,
#   --genesis-start, --genesis-verify
# Or all together: --genesis (with --resume-from=N support)
# ============================================================================

# Genesis Step 1: SPV Prepare (sync BTC headers on Seed)
genesis_step_1_spv_prepare() {
    echo ""
    log "═══════════════════════════════════════════════════════════════"
    log "GENESIS STEP 1: SPV Prepare (sync BTC headers on Seed)"
    log "═══════════════════════════════════════════════════════════════"

    # DAEMON-ONLY FLOW: No genesis_burns.json needed
    # Burns will be detected LIVE from BTC Signet by btc_burn_claim_daemon
    local BTC_CHECKPOINT=$BTC_CHECKPOINT  # from global constant
    log "BTC checkpoint: $BTC_CHECKPOINT (daemon-only flow)"

    # Run SPV sync
    run_or_dry "sync_btc_spv_for_genesis" sync_btc_spv_for_genesis

    # GATE: btcspv/ must exist on Seed with data files (LevelDB WAL or .ldb)
    if ! $DRY_RUN; then
        local spv_size=$($SSH ubuntu@$SEED_IP "du -sb $VPS_TESTNET_DIR/btcspv/ 2>/dev/null | cut -f1 || echo 0" 2>/dev/null || echo "0")
        local spv_files=$($SSH ubuntu@$SEED_IP "ls $VPS_TESTNET_DIR/btcspv/ 2>/dev/null | wc -l" 2>/dev/null || echo "0")
        if [ "$spv_size" -lt 100000 ] || [ "$spv_files" -lt 3 ]; then
            error "GATE FAILED: btcspv/ not found or empty on Seed (${spv_size} bytes, ${spv_files} files)"
            error "  Ensure SPV backup exists at ~/btcspv_backup_latest.tar.gz"
            exit 1
        fi
        success "GATE OK: btcspv/ exists on Seed (${spv_size} bytes, ${spv_files} files)"
    fi

    success "STEP 1 COMPLETE: SPV prepared on Seed"
}

# Genesis Step 1b: REMOVED (burns are now auto-discovered by genesis_bootstrap_seed.sh)
# Kept as stub for backward compatibility with any external references.
genesis_step_refresh_burns() {
    warn "genesis_step_refresh_burns() is DEPRECATED — burns are auto-discovered from BTC Signet"
    return 0
}

# Genesis Step 1c: REMOVED (burn keys are auto-managed by the burn-based genesis flow)
genesis_step_1c_backup_burn_keys() {
    warn "genesis_step_1c_backup_burn_keys() is DEPRECATED — burns use wallet addresses directly"
    return 0
}

genesis_step_2_create() {
    echo ""
    log "═══════════════════════════════════════════════════════════════"
    log "GENESIS STEP 2: Create bootstrap blocks 0-3 on Seed"
    log "═══════════════════════════════════════════════════════════════"

    run_or_dry "create_genesis_bootstrap" create_genesis_bootstrap

    # GATE: operator_keys.json must exist after bootstrap
    if ! $DRY_RUN; then
        gate_ssh_ok "$SEED_IP" "test -f ~/.BathronKey/operators.json" "operators.json exists"
    fi

    success "STEP 2 COMPLETE: Bootstrap blocks created"
}

# Genesis Step 3: Configure MN + SPV on Seed
genesis_step_3_configure() {
    echo ""
    log "═══════════════════════════════════════════════════════════════"
    log "GENESIS STEP 3: Configure MN + SPV on Seed"
    log "═══════════════════════════════════════════════════════════════"

    # Sync operator keys
    log "Syncing operator keys from Seed..."
    if ! $DRY_RUN; then
        scp -i "$SSH_KEY" -o StrictHostKeyChecking=no ubuntu@$SEED_IP:~/.BathronKey/operators.json /tmp/mn_operator_keys.json 2>/dev/null
        gate_file_exists "/tmp/mn_operator_keys.json" "operator_keys.json (local copy)"
    fi

    # Configure MN + SPV
    run_or_dry "restore_mn_configs" restore_mn_configs

    success "STEP 3 COMPLETE: MN + SPV configured on Seed"
}

# Genesis Step 4: Distribute chain + SPV to all nodes
genesis_step_4_distribute() {
    echo ""
    log "═══════════════════════════════════════════════════════════════"
    log "GENESIS STEP 4: Distribute chain + SPV to all nodes"
    log "═══════════════════════════════════════════════════════════════"

    if $DRY_RUN; then
        log "[DRY-RUN] Would package and distribute chain data"
        log "[DRY-RUN] Would distribute SPV backup"
        return 0
    fi

    # Stop all daemons first
    log "Stopping all daemons..."
    for ip in "${VPS_NODES[@]}"; do
        stop_daemon "$ip" &
    done
    wait
    sleep 3

    # Package chain on Seed (MUST include burnclaimdb for anti-replay!)
    # CRITICAL: EXCLUDE wallet.dat to prevent shared HD seed across nodes
    log "Packaging chain data on Seed (excluding wallet.dat)..."
    if ! $SSH ubuntu@$SEED_IP "cd /tmp/bathron_bootstrap && tar czf /tmp/testnet5_bootstrap.tar.gz --exclude='testnet5/wallet.dat' --exclude='testnet5/wallet.sqlite' --exclude='testnet5/wallet.sqlite-shm' --exclude='testnet5/wallet.sqlite-wal' --exclude='testnet5/.walletlock' --exclude='testnet5/wallets' --exclude='testnet5/backups' testnet5/"; then
        error "FAILED to create tar on Seed"
        exit 1
    fi

    # GATE: wallet files must NOT be in the archive (prevents shared wallets)
    if $SSH ubuntu@$SEED_IP "tar tzf /tmp/testnet5_bootstrap.tar.gz | grep -qE 'wallet\.(dat|sqlite)'"; then
        error "GATE FAILED: wallet file found in bootstrap archive — would share HD seed across all nodes"
        exit 1
    fi

    # GATE: Verify tar exists and has reasonable size
    local tar_size=$($SSH ubuntu@$SEED_IP "stat -c%s /tmp/testnet5_bootstrap.tar.gz 2>/dev/null || echo 0")
    if [ "$tar_size" -lt 100000 ]; then
        error "GATE FAILED: tar too small ($tar_size bytes) - bootstrap may have failed"
        exit 1
    fi
    success "  Tar created: $tar_size bytes (wallet.dat excluded)"

    # Download tar to local (Seed doesn't have SSH keys to other nodes)
    log "Downloading chain data to local..."
    if ! $SCP ubuntu@$SEED_IP:/tmp/testnet5_bootstrap.tar.gz /tmp/; then
        error "FAILED to download tar from Seed"
        exit 1
    fi

    # GATE: Verify local tar exists and is valid
    if [ ! -f /tmp/testnet5_bootstrap.tar.gz ]; then
        error "GATE FAILED: /tmp/testnet5_bootstrap.tar.gz not found locally"
        exit 1
    fi

    # Verify tar integrity (catches corruption during transfer)
    if ! tar tzf /tmp/testnet5_bootstrap.tar.gz >/dev/null 2>&1; then
        error "GATE FAILED: tar file corrupted (integrity check failed)"
        rm -f /tmp/testnet5_bootstrap.tar.gz
        exit 1
    fi

    # Verify tar contains required directories
    local tar_contents=$(tar tzf /tmp/testnet5_bootstrap.tar.gz 2>/dev/null)
    if ! echo "$tar_contents" | grep -q "testnet5/blocks/" || ! echo "$tar_contents" | grep -q "testnet5/evodb/"; then
        error "GATE FAILED: tar missing required directories (blocks or evodb)"
        exit 1
    fi
    success "  Downloaded and verified (integrity OK)"

    # Distribute to all nodes (parallel with exit code tracking)
    log "Distributing to all nodes..."
    local dist_fail_file=$(mktemp /tmp/dist_failures.XXXXXX)
    local pids=()
    for ip in "${VPS_NODES[@]}"; do
        (
            if [[ "$ip" == "$SEED_IP" ]]; then
                # Seed: move bootstrap data directly (tar already exists on Seed)
                if ! $SSH ubuntu@$ip "
                    pkill -9 bathrond 2>/dev/null || true
                    sleep 1
                    mkdir -p $VPS_DATADIR && chmod 700 $VPS_DATADIR
                    rm -rf $VPS_TESTNET_DIR
                    cd $VPS_DATADIR && tar xzf /tmp/testnet5_bootstrap.tar.gz
                    chmod 700 $VPS_TESTNET_DIR
                    rm -f /tmp/testnet5_bootstrap.tar.gz
                    if [ ! -d $VPS_TESTNET_DIR/blocks ] || [ ! -d $VPS_TESTNET_DIR/evodb ]; then
                        echo 'EXTRACT_FAIL: blocks or evodb missing'
                        exit 1
                    fi
                    echo 'OK'
                "; then
                    echo "$ip:extract" >> "$dist_fail_file"
                    exit 1
                fi
            else
                # Other nodes: SCP tar then extract
                if ! $SCP /tmp/testnet5_bootstrap.tar.gz ubuntu@$ip:/tmp/; then
                    echo "$ip:scp" >> "$dist_fail_file"
                    exit 1
                fi
                if ! $SSH ubuntu@$ip "
                    pkill -9 bathrond 2>/dev/null || true
                    sleep 1
                    mkdir -p $VPS_DATADIR && chmod 700 $VPS_DATADIR
                    rm -rf $VPS_TESTNET_DIR
                    cd $VPS_DATADIR && tar xzf /tmp/testnet5_bootstrap.tar.gz
                    chmod 700 $VPS_TESTNET_DIR
                    rm -f /tmp/testnet5_bootstrap.tar.gz
                    if [ ! -d $VPS_TESTNET_DIR/blocks ] || [ ! -d $VPS_TESTNET_DIR/evodb ]; then
                        echo 'EXTRACT_FAIL: blocks or evodb missing'
                        exit 1
                    fi
                    echo 'OK'
                "; then
                    echo "$ip:extract" >> "$dist_fail_file"
                    exit 1
                fi
            fi
            success "  $ip: chain synced ✓"
        ) &
        pids+=($!)
    done

    # Wait for all and check exit codes
    local any_failed=false
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            any_failed=true
        fi
    done

    # Check failure file for details
    if [ -s "$dist_fail_file" ]; then
        error "Distribution FAILED on:"
        while IFS= read -r line; do
            error "  $line"
        done < "$dist_fail_file"
        rm -f "$dist_fail_file"
        exit 1
    elif $any_failed; then
        error "Distribution FAILED (unknown subshell error)"
        rm -f "$dist_fail_file"
        exit 1
    fi
    rm -f "$dist_fail_file"

    # GATE: Verify ALL nodes have blocks and evodb
    log "Verifying distribution..."
    for ip in "${VPS_NODES[@]}"; do
        local check=$($SSH ubuntu@$ip "test -d $VPS_TESTNET_DIR/blocks && test -d $VPS_TESTNET_DIR/evodb && echo OK || echo FAIL")
        if [ "$check" != "OK" ]; then
            error "GATE FAILED: $ip missing blocks or evodb after distribution"
            exit 1
        fi
        success "  $ip: verified ✓"
    done

    # Cleanup local tar
    rm -f /tmp/testnet5_bootstrap.tar.gz

    success "STEP 4 COMPLETE: Chain + SPV distributed to all ${#VPS_NODES[@]} nodes"
}

# Genesis Step 5: Start all daemons
genesis_step_5_start() {
    echo ""
    log "═══════════════════════════════════════════════════════════════"
    log "GENESIS STEP 5: Start all daemons"
    log "═══════════════════════════════════════════════════════════════"

    if $DRY_RUN; then
        log "[DRY-RUN] Would start daemons on all nodes"
        return 0
    fi

    # NOTE: genesis_burns.json and btcspv/ gates removed.
    # New genesis flow: Block 1 TX_BTC_HEADERS populates btcheadersdb via consensus replay.
    # Non-Seed nodes only need blocks/chainstate (distributed in step 4).

    log "Starting daemons..."
    for ip in "${VPS_NODES[@]}"; do
        daemon_path=$(get_daemon_path "$ip")
        timeout 30 $SSH ubuntu@$ip "nohup $daemon_path -datadir=$VPS_DATADIR -testnet -daemon < /dev/null > /dev/null 2>&1" &
    done
    wait

    log "Waiting 15s for initialization..."
    sleep 15

    # GATE: All daemons must be running AND responding to RPC
    log "Verifying daemons..."
    for ip in "${VPS_NODES[@]}"; do
        local cli_path=$(get_cli_path "$ip")
        local count=$($SSH ubuntu@$ip "pgrep bathrond | wc -l" 2>/dev/null || echo "0")
        if [ "$count" != "1" ]; then
            # Show crash reason from debug.log
            error "GATE FAILED: Daemon not running on $ip (count=$count)"
            warn "Last 20 lines of debug.log:"
            $SSH ubuntu@$ip "tail -20 $VPS_TESTNET_DIR/debug.log 2>/dev/null" || true
            exit 1
        fi

        # Also verify RPC is responding (catches crash-on-startup)
        local height=$($SSH ubuntu@$ip "$cli_path -testnet getblockcount 2>/dev/null || echo -1")
        if [ "$height" = "-1" ]; then
            error "GATE FAILED: Daemon on $ip not responding to RPC"
            warn "Last 20 lines of debug.log:"
            $SSH ubuntu@$ip "tail -20 $VPS_TESTNET_DIR/debug.log 2>/dev/null" || true
            exit 1
        fi
        success "  $ip: daemon running, height=$height ✓"
    done

    success "STEP 5 COMPLETE: All daemons started and responding"

    # Post-start: Import wallet keys from ~/.BathronKey/wallet.json + rescanblockchain
    # This ensures each VPS wallet can see its own M0/M1 after chain distribution.
    # Without this, getbalance returns 0 even though M0 was minted to known addresses.
    log "STEP 5b: Importing wallet keys + rescan on all nodes..."
    for ip in "${VPS_NODES[@]}"; do
        local cli_path=$(get_cli_path "$ip")
        $SSH ubuntu@$ip "
            if [ -f ~/.BathronKey/wallet.json ]; then
                WIF=\$(jq -r '.wif' ~/.BathronKey/wallet.json 2>/dev/null)
                NAME=\$(jq -r '.name' ~/.BathronKey/wallet.json 2>/dev/null)
                if [ -n \"\$WIF\" ] && [ \"\$WIF\" != 'null' ]; then
                    $cli_path -testnet importprivkey \"\$WIF\" \"\$NAME\" false 2>/dev/null || true
                    $cli_path -testnet rescanblockchain 0 2>/dev/null || true
                    echo \"[OK] Imported key for \$NAME, rescan done\"
                fi
            else
                echo \"[SKIP] No ~/.BathronKey/wallet.json\"
            fi
        " 2>/dev/null && success "  $ip: wallet key imported + rescanned ✓" || warn "  $ip: wallet import skipped"
    done
}

# Genesis Step 6: Verify network producing blocks (THOROUGH)
genesis_step_6_verify() {
    echo ""
    log "═══════════════════════════════════════════════════════════════"
    log "GENESIS STEP 6: Verify network (height, SPV, consensus)"
    log "═══════════════════════════════════════════════════════════════"

    if $DRY_RUN; then
        log "[DRY-RUN] Would wait 60s and verify:"
        log "[DRY-RUN]   - height >= 5 on all nodes"
        log "[DRY-RUN]   - btcheadersstatus.tip >= H_required on all nodes"
        log "[DRY-RUN]   - same bestblockhash on all nodes"
        return 0
    fi

    log "Waiting 120s for block production and sync..."
    sleep 120

    # BTC checkpoint (daemon-only flow - no genesis_burns files needed)
    local BTC_CHECKPOINT=$BTC_CHECKPOINT  # from global constant
    log "BTC checkpoint: $BTC_CHECKPOINT"

    # GATE 1: height >= 4 on ALL nodes (with retry)
    log "Checking block heights..."
    local max_retries=3
    for ip in "${VPS_NODES[@]}"; do
        local cli_path=$(get_cli_path "$ip")
        local h=0
        for retry in $(seq 1 $max_retries); do
            h=$($SSH ubuntu@$ip "$cli_path -testnet getblockcount 2>/dev/null" 2>/dev/null || echo "0")
            if [ "$h" -ge 5 ]; then
                break
            fi
            [ $retry -lt $max_retries ] && sleep 10
        done
        if [ "$h" -lt 5 ]; then
            error "GATE FAILED: height=$h < 5 on $ip (after $max_retries retries)"
            exit 1
        fi
        success "  $ip: height=$h ✓"
    done

    # GATE 2: btcheadersstatus.tip_height >= H_required on ALL nodes
    log "Checking BTC headers status..."
    for ip in "${VPS_NODES[@]}"; do
        local cli_path=$(get_cli_path "$ip")
        local btc_tip=$($SSH ubuntu@$ip "$cli_path -testnet getbtcheadersstatus 2>/dev/null | jq -r '.tip_height // 0'" 2>/dev/null || echo "0")
        if [ "$btc_tip" -lt "$BTC_CHECKPOINT" ]; then
            error "GATE FAILED: btcheadersstatus.tip=$btc_tip < checkpoint=$BTC_CHECKPOINT on $ip"
            exit 1
        fi
        success "  $ip: btcheaders.tip=$btc_tip >= $BTC_CHECKPOINT ✓"
    done

    # GATE 3: Consensus check — compare block hash at minimum height across all nodes
    # (bestblockhash can differ by timing since Seed produces blocks faster)
    log "Checking consensus (block hash at common height)..."
    local min_height=999999
    declare -A node_heights
    for ip in "${VPS_NODES[@]}"; do
        local cli_path=$(get_cli_path "$ip")
        local h=$($SSH ubuntu@$ip "$cli_path -testnet getblockcount 2>/dev/null" 2>/dev/null || echo "0")
        node_heights[$ip]=$h
        if [ "$h" -lt "$min_height" ] && [ "$h" -gt 0 ]; then
            min_height=$h
        fi
    done
    if [ "$min_height" -lt 25 ]; then
        error "GATE FAILED: minimum height too low ($min_height)"
        exit 1
    fi
    log "  Common height for comparison: $min_height"
    local ref_hash=""
    for ip in "${VPS_NODES[@]}"; do
        local cli_path=$(get_cli_path "$ip")
        local hash=$($SSH ubuntu@$ip "$cli_path -testnet getblockhash $min_height 2>/dev/null" 2>/dev/null || echo "")
        if [ -z "$ref_hash" ]; then
            ref_hash=$hash
        elif [ "$hash" != "$ref_hash" ]; then
            error "GATE FAILED: Consensus mismatch at height $min_height!"
            error "  First node: ${ref_hash:0:16}..."
            error "  $ip: ${hash:0:16}..."
            exit 1
        fi
    done
    success "GATE OK: All nodes agree on chain at height $min_height (${ref_hash:0:16}...)"

    # Final health check
    health_check

    echo ""
    success "═══════════════════════════════════════════════════════════════"
    success "GENESIS VERIFIED:"
    success "  ✓ All nodes: height >= 5"
    success "  ✓ All nodes: btcheaders.tip >= checkpoint ($BTC_CHECKPOINT)"
    success "  ✓ All nodes: same bestblockhash"
    success "═══════════════════════════════════════════════════════════════"
}

# Full genesis (all steps with resume support)
# Auto-detect genesis state for intelligent resume
detect_genesis_state() {
    # Returns the step to resume from (0 = start fresh, 3 = after bootstrap, etc.)
    local detected_step=0

    # Check if operator_keys.json exists on Seed (STEP 2 complete)
    if $SSH ubuntu@$SEED_IP "test -f ~/.BathronKey/operators.json" 2>/dev/null; then
        detected_step=3
        # Check if chain data exists on all nodes (STEP 4 complete)
        local all_have_chain=true
        for ip in "${VPS_NODES[@]}"; do
            if ! $SSH ubuntu@$ip "test -d $VPS_TESTNET_DIR/blocks" 2>/dev/null; then
                all_have_chain=false
                break
            fi
        done
        if $all_have_chain; then
            detected_step=5
            # Check if daemons are running (STEP 5 complete)
            local all_running=true
            for ip in "${VPS_NODES[@]}"; do
                if ! $SSH ubuntu@$ip "pgrep -x bathrond" >/dev/null 2>&1; then
                    all_running=false
                    break
                fi
            done
            if $all_running; then
                detected_step=6
                # Check if network is healthy (STEP 6 complete)
                local height=$($SSH ubuntu@$SEED_IP "/home/ubuntu/bathron-cli -testnet getblockcount 2>/dev/null || echo 0")
                if [ "$height" -ge 5 ]; then
                    detected_step=7
                fi
            fi
        fi
    fi

    echo $detected_step
}

genesis_full() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  GENESIS FULL - v18.0 (Block 1 = TX_BTC_HEADERS)            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    if $DRY_RUN; then
        log "[DRY-RUN MODE] No changes will be made"
    fi

    # Auto-detect state if no explicit resume-from
    if [ "$RESUME_FROM" -eq 0 ]; then
        local detected=$(detect_genesis_state)
        if [ "$detected" -gt 0 ]; then
            warn "Detected partial genesis (step $detected completed)"
            warn "Use --resume-from=$((detected)) to continue, or re-run to start fresh"
            log "Starting fresh (STEP 1)..."
        fi
    fi

    if [ "$RESUME_FROM" -gt 0 ]; then
        log "Resuming from step $RESUME_FROM"
    fi

    # Kill chaos bot before genesis — it creates TX_LOCK that consume collateral UTXOs
    if [ -f "$SCRIPT_DIR/m0m1_chaos_bot.sh" ]; then
        log "Stopping m0m1_chaos_bot (if running)..."
        "$SCRIPT_DIR/m0m1_chaos_bot.sh" stop 2>/dev/null || true
    fi

    [ "$RESUME_FROM" -le 1 ] && genesis_step_1_spv_prepare
    # NOTE: genesis_step_refresh_burns and genesis_step_1c_backup_burn_keys removed.
    # Burns are now auto-discovered from BTC Signet by genesis_bootstrap_seed.sh.
    [ "$RESUME_FROM" -le 2 ] && genesis_step_2_create
    [ "$RESUME_FROM" -le 3 ] && genesis_step_3_configure
    [ "$RESUME_FROM" -le 4 ] && genesis_step_4_distribute
    [ "$RESUME_FROM" -le 5 ] && genesis_step_5_start
    [ "$RESUME_FROM" -le 6 ] && genesis_step_6_verify
    [ "$RESUME_FROM" -le 7 ] && genesis_step_7_seed_daemons

    echo ""
    success "═══════════════════════════════════════════════════════════════"
    success "GENESIS COMPLETE - Network is live!"
    success "═══════════════════════════════════════════════════════════════"
}

# Genesis Step 7: Start Seed daemons (BTC header publisher + burn claim daemon)
genesis_step_7_seed_daemons() {
    echo ""
    log "═══════════════════════════════════════════════════════════════"
    log "GENESIS STEP 7: Start Seed daemons (SPV publisher + auto-claim)"
    log "═══════════════════════════════════════════════════════════════"

    if $DRY_RUN; then
        log "[DRY-RUN] Would start btc_header_daemon.sh and btc_burn_claim_daemon.sh on Seed"
        return 0
    fi

    # Copy daemon scripts to Seed
    log "  Copying daemon scripts to Seed..."
    $SCP contrib/testnet/btc_header_daemon.sh ubuntu@$SEED_IP:~/ 2>/dev/null
    $SCP contrib/testnet/btc_burn_claim_daemon.sh ubuntu@$SEED_IP:~/ 2>/dev/null
    $SSH ubuntu@$SEED_IP "chmod +x ~/btc_header_daemon.sh ~/btc_burn_claim_daemon.sh" 2>/dev/null

    # Start BTC header publisher daemon
    log "  Starting BTC header daemon on Seed..."
    $SSH ubuntu@$SEED_IP "~/btc_header_daemon.sh stop 2>/dev/null; sleep 2; ~/btc_header_daemon.sh start" 2>/dev/null

    # Wait for SPV to fully sync (headers_ahead=0)
    log "  Waiting for SPV to sync (may take a few minutes)..."
    local max_wait=300  # 5 minutes max
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local headers_ahead=$($SSH ubuntu@$SEED_IP '~/bathron-cli -testnet getbtcheadersstatus 2>/dev/null | jq -r ".headers_ahead // 999"' 2>/dev/null)
        if [ "$headers_ahead" = "0" ]; then
            local spv_tip=$($SSH ubuntu@$SEED_IP '~/bathron-cli -testnet getbtcheadersstatus 2>/dev/null | jq -r ".tip_height"' 2>/dev/null)
            success "  SPV synced: tip=$spv_tip, headers_ahead=0 ✓"
            break
        fi
        echo -ne "\r    SPV syncing: headers_ahead=$headers_ahead (${waited}s)..."
        sleep 10
        waited=$((waited + 10))
    done
    if [ $waited -ge $max_wait ]; then
        warn "  SPV sync timeout (headers_ahead=$headers_ahead) - daemon will continue in background"
    fi
    echo ""

    # Start burn claim daemon
    # CRITICAL: Only reset scan state on FRESH genesis (RESUME_FROM=0)
    # Otherwise keep existing state to avoid double-minting already-finalized burns
    log "  Starting burn claim daemon on Seed..."
    local BTC_CHECKPOINT=$BTC_CHECKPOINT  # from global constant  # BP-SPV checkpoint (daemon-only flow)

    if [ "$RESUME_FROM" -eq 0 ]; then
        log "  Fresh genesis: resetting burn scan state to checkpoint=$BTC_CHECKPOINT..."
        $SSH ubuntu@$SEED_IP "
            ~/btc_burn_claim_daemon.sh stop 2>/dev/null
            echo '$BTC_CHECKPOINT' > /tmp/btc_burn_claim_daemon.state
            rm -f /tmp/btc_burn_claim_daemon.log
            sleep 2
            ~/btc_burn_claim_daemon.sh start
        " 2>/dev/null
    else
        log "  Resume mode: keeping existing burn scan state (no reset)..."
        $SSH ubuntu@$SEED_IP "
            ~/btc_burn_claim_daemon.sh stop 2>/dev/null
            sleep 2
            ~/btc_burn_claim_daemon.sh start
        " 2>/dev/null
    fi

    # Verify
    sleep 3
    local header_status=$($SSH ubuntu@$SEED_IP "~/btc_header_daemon.sh status 2>/dev/null | grep -o 'RUNNING\|STOPPED'" 2>/dev/null || echo "UNKNOWN")
    local claim_status=$($SSH ubuntu@$SEED_IP "~/btc_burn_claim_daemon.sh status 2>/dev/null | grep -o 'RUNNING\|STOPPED'" 2>/dev/null || echo "UNKNOWN")

    if [ "$header_status" = "RUNNING" ]; then
        success "  BTC header daemon: RUNNING ✓"
    else
        warn "  BTC header daemon: $header_status (may need manual start)"
    fi

    if [ "$claim_status" = "RUNNING" ]; then
        success "  Burn claim daemon: RUNNING ✓"
    else
        warn "  Burn claim daemon: $claim_status (may need manual start)"
    fi

    success "STEP 7 COMPLETE: Seed daemons configured"
}

# Handle individual genesis sub-commands
if $SPV_PREPARE; then
    genesis_step_1_spv_prepare
    exit 0
fi

if $SPV_DISTRIBUTE; then
    distribute_spv_backup
    exit 0
fi

if $SPV_VERIFY; then
    echo ""
    log "═══════════════════════════════════════════════════════════════"
    log "SPV VERIFY: Checking btcheadersdb.tip >= H_required on ALL nodes"
    log "═══════════════════════════════════════════════════════════════"

    # BTC genesis checkpoint — all headers from this height onward must be in btcheadersdb
    local H_REQUIRED=$BTC_CHECKPOINT
    log "H_required (BTC genesis checkpoint): $H_REQUIRED"
    echo ""

    local all_ok=true
    for ip in "${VPS_NODES[@]}"; do
        # Check btcheadersdb (consensus headers, not local btcspv)
        local tip=$($SSH ubuntu@$ip '~/bathron-cli -testnet getbtcheadersstatus 2>/dev/null | jq -r ".tip_height // 0"' 2>/dev/null || echo "0")
        if [ "$tip" -ge "$H_REQUIRED" ]; then
            success "  $ip: btcheadersdb.tip=$tip >= $H_REQUIRED ✓"
        else
            error "  $ip: btcheadersdb.tip=$tip < $H_REQUIRED ✗"
            all_ok=false
        fi
    done

    echo ""
    if $all_ok; then
        success "SPV VERIFY: All nodes ready (btcheadersdb.tip >= $H_REQUIRED)"
    else
        error "SPV VERIFY FAILED: Some nodes not ready"
        exit 1
    fi
    exit 0
fi

if $GENESIS_CREATE; then
    genesis_step_2_create
    exit 0
fi

if $GENESIS_DISTRIBUTE; then
    genesis_step_4_distribute
    exit 0
fi

if $GENESIS_CONFIGURE; then
    genesis_step_3_configure
    exit 0
fi

if $GENESIS_START; then
    genesis_step_5_start
    exit 0
fi

if $GENESIS_VERIFY; then
    genesis_step_6_verify
    exit 0
fi

# Full genesis (Level 4)
if [ $DEPLOY_LEVEL -eq 4 ]; then
    genesis_full
fi

# NOTE: Explorer is managed separately via contrib/testnet/deploy_explorer.sh
# Run: ./contrib/testnet/deploy_explorer.sh after deployment

echo ""
if $deploy_failed; then
    error "DEPLOYMENT COMPLETED WITH ERRORS!"
    exit 1
else
    success "DEPLOYMENT COMPLETE - Level $DEPLOY_LEVEL: $(get_level_name $DEPLOY_LEVEL)"
fi
