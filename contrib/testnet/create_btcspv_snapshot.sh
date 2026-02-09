#!/usr/bin/env bash
# ==============================================================================
# create_btcspv_snapshot.sh - Create btcspv snapshot for genesis bootstrap
# ==============================================================================
#
# Creates a btcspv snapshot that includes headers from checkpoint (286000)
# up to current BTC Signet tip. This snapshot can be restored on any node
# to skip the header sync phase during genesis.
#
# Usage:
#   ./create_btcspv_snapshot.sh          # Create snapshot
#   ./create_btcspv_snapshot.sh status   # Check btcspv status
#
# Output:
#   ~/btcspv_snapshot_YYYYMMDD_HHMMSS.tar.gz
#   ~/btcspv_snapshot_latest.tar.gz (symlink)
#
# ==============================================================================

set -euo pipefail

# Configuration
CHECKPOINT=286000
BATHRON_CLI="${BATHRON_CLI:-$HOME/bathron-cli}"
BATHRON_CMD="$BATHRON_CLI -testnet"
BATHROND="${BATHROND:-$HOME/bathrond}"
DATADIR="${DATADIR:-$HOME/.bathron/testnet5}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

show_status() {
    echo ""
    echo "=== btcspv Status ==="

    if ! $BATHRON_CMD getbtcspvstatus >/dev/null 2>&1; then
        error "Cannot reach BATHRON daemon"
        exit 1
    fi

    local status=$($BATHRON_CMD getbtcspvstatus 2>/dev/null)
    echo "$status" | jq '.'

    local tip=$(echo "$status" | jq -r '.tip_height // 0')
    local min=$(echo "$status" | jq -r '.min_supported_height // 0')

    echo ""
    echo "Tip height:     $tip"
    echo "Min supported:  $min"
    echo "Headers count:  $((tip - min + 1))"
    exit 0
}

# Handle status command
if [[ "${1:-}" == "status" ]]; then
    show_status
fi

echo ""
echo "=== btcspv Snapshot Creator ==="
echo ""

# Check daemon is running
if ! $BATHRON_CMD getblockcount >/dev/null 2>&1; then
    error "BATHRON daemon not running"
    error "Start with: $BATHROND -testnet -daemon"
    exit 1
fi

# Get current btcspv status
log "Checking btcspv status..."
if ! $BATHRON_CMD getbtcspvstatus >/dev/null 2>&1; then
    error "btcspv not available - is daemon running?"
    exit 1
fi

SPV_STATUS=$($BATHRON_CMD getbtcspvstatus)
SPV_TIP=$(echo "$SPV_STATUS" | jq -r '.tip_height // 0')
SPV_MIN=$(echo "$SPV_STATUS" | jq -r '.min_supported_height // 0')

log "btcspv tip: $SPV_TIP (min: $SPV_MIN)"

if [[ "$SPV_TIP" -lt "$CHECKPOINT" ]]; then
    error "btcspv tip ($SPV_TIP) is below checkpoint ($CHECKPOINT)"
    error "Run btc_header_daemon.sh to sync headers first"
    exit 1
fi

# Stop daemon for clean snapshot
log "Stopping daemon for clean snapshot..."
$BATHRON_CMD stop 2>/dev/null || true
sleep 5

# Check btcspv directory exists
if [[ ! -d "$DATADIR/btcspv" ]]; then
    error "btcspv directory not found: $DATADIR/btcspv"
    exit 1
fi

# Create snapshot
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
SNAPSHOT_FILE="$HOME/btcspv_snapshot_${TIMESTAMP}.tar.gz"
LATEST_LINK="$HOME/btcspv_snapshot_latest.tar.gz"

log "Creating snapshot..."
cd "$DATADIR"
tar -czf "$SNAPSHOT_FILE" btcspv/

# Update latest symlink
rm -f "$LATEST_LINK"
ln -s "$SNAPSHOT_FILE" "$LATEST_LINK"

# Get size
SIZE=$(du -h "$SNAPSHOT_FILE" | cut -f1)

success "Snapshot created!"
echo ""
echo "  File:    $SNAPSHOT_FILE"
echo "  Latest:  $LATEST_LINK"
echo "  Size:    $SIZE"
echo "  Headers: $SPV_MIN - $SPV_TIP ($((SPV_TIP - SPV_MIN + 1)) headers)"
echo ""

# Restart daemon
log "Restarting daemon..."
$BATHROND -testnet -daemon
sleep 10

if $BATHRON_CMD getblockcount >/dev/null 2>&1; then
    success "Daemon restarted"
else
    warn "Daemon may not have started - check manually"
fi

echo ""
echo "To use this snapshot on another node:"
echo "  scp $LATEST_LINK user@node:~/"
echo "  ssh user@node 'cd ~/.bathron/testnet5 && rm -rf btcspv && tar xzf ~/btcspv_snapshot_latest.tar.gz'"
