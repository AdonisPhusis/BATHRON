#!/usr/bin/env bash
# ==============================================================================
# install_systemd_services.sh - Install systemd service files for BATHRON
# ==============================================================================
#
# Usage:
#   ./install_systemd_services.sh install <service>   # Install and enable
#   ./install_systemd_services.sh remove <service>    # Stop and remove
#   ./install_systemd_services.sh status              # Show status of all
#
# Services:
#   btc-header-daemon   - BTC header sync (Seed only)
#   btc-burn-claim-daemon - BTC burn detection (Seed only)
#   pna-lp              - LP server (OP1, OP2)
#
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_DIR="$SCRIPT_DIR/systemd"
TARGET_DIR="/etc/systemd/system"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <install|remove|status> [service-name]"
    echo ""
    echo "Services available:"
    for f in "$SYSTEMD_DIR"/*.service; do
        echo "  $(basename "$f" .service)"
    done
    exit 1
}

install_service() {
    local name="$1"
    local src="$SYSTEMD_DIR/${name}.service"

    if [ ! -f "$src" ]; then
        echo -e "${RED}Service file not found: $src${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Installing ${name}...${NC}"
    sudo cp "$src" "$TARGET_DIR/${name}.service"
    sudo systemctl daemon-reload
    sudo systemctl enable "$name"
    sudo systemctl start "$name"
    echo -e "${GREEN}${name} installed and started${NC}"
    sudo systemctl status "$name" --no-pager -l
}

remove_service() {
    local name="$1"

    echo -e "${YELLOW}Removing ${name}...${NC}"
    sudo systemctl stop "$name" 2>/dev/null || true
    sudo systemctl disable "$name" 2>/dev/null || true
    sudo rm -f "$TARGET_DIR/${name}.service"
    sudo systemctl daemon-reload
    echo -e "${GREEN}${name} removed${NC}"
}

show_status() {
    echo "=== BATHRON Systemd Services ==="
    echo ""
    for f in "$SYSTEMD_DIR"/*.service; do
        local name
        name="$(basename "$f" .service)"
        if systemctl is-active "$name" &>/dev/null; then
            echo -e "  ${GREEN}[ACTIVE]${NC}  $name"
        elif systemctl is-enabled "$name" &>/dev/null; then
            echo -e "  ${YELLOW}[STOPPED]${NC} $name"
        else
            echo -e "  ${RED}[NOT INSTALLED]${NC} $name"
        fi
    done
    echo ""
}

# --- Main ---
[ $# -lt 1 ] && usage

case "$1" in
    install)
        [ $# -lt 2 ] && usage
        install_service "$2"
        ;;
    remove)
        [ $# -lt 2 ] && usage
        remove_service "$2"
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
