#!/bin/bash
# =============================================================================
# deploy_dex.sh - Deploy DEX Demo + SDK to Core+SDK VPS
# =============================================================================
#
# Usage:
#   ./contrib/testnet/deploy_dex.sh [command]
#
# Commands:
#   deploy    - Deploy all files and restart services (default)
#   start     - Start all DEX services
#   stop      - Stop all DEX services
#   restart   - Restart all DEX services
#   status    - Check service status
#   logs      - View logs
#   sdk-only  - Deploy SDK files only
#   web-only  - Deploy web files only
#
# =============================================================================

set -e

# Configuration
CORE_SDK_IP="162.19.251.75"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SCP="scp -i $SSH_KEY -o StrictHostKeyChecking=no"

# Ports
SDK_PORT=8080
DEX_PORT=3002

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_ssh() {
    log_info "Checking SSH connection to Core+SDK VPS..."
    if $SSH ubuntu@$CORE_SDK_IP "echo 'SSH OK'" > /dev/null 2>&1; then
        log_success "SSH connection OK"
        return 0
    else
        log_error "Cannot connect to $CORE_SDK_IP"
        return 1
    fi
}

# =============================================================================
# DEPLOYMENT FUNCTIONS
# =============================================================================

deploy_sdk() {
    log_info "Deploying SDK files..."

    # Create directories
    $SSH ubuntu@$CORE_SDK_IP "mkdir -p ~/sdk"

    # Copy SDK files
    $SCP "$PROJECT_ROOT/contrib/dex/sdk/"*.py ubuntu@$CORE_SDK_IP:~/sdk/
    $SCP "$PROJECT_ROOT/contrib/dex/sdk/requirements.txt" ubuntu@$CORE_SDK_IP:~/sdk/

    # Copy LP watcher
    $SCP "$PROJECT_ROOT/contrib/dex/lp_watcher.py" ubuntu@$CORE_SDK_IP:~/sdk/

    # Copy .env.example if exists
    if [ -f "$PROJECT_ROOT/contrib/dex/.env.example" ]; then
        $SCP "$PROJECT_ROOT/contrib/dex/.env.example" ubuntu@$CORE_SDK_IP:~/sdk/
    fi

    # Setup venv and install dependencies
    log_info "Setting up Python virtual environment..."
    $SSH ubuntu@$CORE_SDK_IP "
        cd ~/sdk
        if [ ! -d venv ]; then
            python3 -m venv venv
            echo 'Created new venv'
        fi
        source venv/bin/activate
        pip install -q -r requirements.txt
        echo 'Dependencies installed'
    "

    log_success "SDK deployed"
}

deploy_web() {
    log_info "Deploying DEX web files..."

    # Create directories
    $SSH ubuntu@$CORE_SDK_IP "mkdir -p ~/dex-demo/{css,js,api}"

    # Copy all web files
    $SCP "$PROJECT_ROOT/contrib/dex/dex-demo/index.php" ubuntu@$CORE_SDK_IP:~/dex-demo/
    $SCP "$PROJECT_ROOT/contrib/dex/dex-demo/css/"*.css ubuntu@$CORE_SDK_IP:~/dex-demo/css/ 2>/dev/null || true
    $SCP "$PROJECT_ROOT/contrib/dex/dex-demo/js/"*.js ubuntu@$CORE_SDK_IP:~/dex-demo/js/

    log_success "DEX web files deployed"
}

start_services() {
    log_info "Starting DEX services..."

    # Start SDK server (with venv)
    $SSH ubuntu@$CORE_SDK_IP "
        cd ~/sdk
        pkill -f 'python3 server.py' 2>/dev/null || true
        sleep 1
        source venv/bin/activate
        nohup python3 server.py > /tmp/sdk_server.log 2>&1 &
        echo 'SDK server started (PID: '\$!')'
    "

    # Start DEX web server
    $SSH ubuntu@$CORE_SDK_IP "
        cd ~/dex-demo
        pkill -f 'php.*$DEX_PORT' 2>/dev/null || true
        sleep 1
        nohup php -S 0.0.0.0:$DEX_PORT > /tmp/dex_web.log 2>&1 &
        echo 'DEX web server started (PID: '\$!')'
    "

    # Note: LP watcher needs .env with private key - start manually
    log_warn "LP Watcher not auto-started (requires .env with LP_EVM_PRIVKEY)"
    log_info "To start LP watcher: ssh ubuntu@$CORE_SDK_IP 'cd ~/sdk && python3 lp_watcher.py'"

    sleep 2
    log_success "Services started"
}

stop_services() {
    log_info "Stopping DEX services..."

    $SSH ubuntu@$CORE_SDK_IP "
        pkill -f 'python3 server.py' 2>/dev/null || true
        pkill -f 'python3 lp_watcher.py' 2>/dev/null || true
        pkill -f 'php.*$DEX_PORT' 2>/dev/null || true
        echo 'All DEX services stopped'
    "

    log_success "Services stopped"
}

restart_services() {
    stop_services
    sleep 1
    start_services
}

check_status() {
    echo ""
    echo "=========================================="
    echo "  DEX Service Status (Core+SDK VPS)"
    echo "=========================================="
    echo ""

    # Check SDK server
    echo -n "SDK Server (port $SDK_PORT): "
    if $SSH ubuntu@$CORE_SDK_IP "curl -s http://127.0.0.1:$SDK_PORT/api/status" > /dev/null 2>&1; then
        echo -e "${GREEN}RUNNING${NC}"
        # Get status details
        STATUS=$($SSH ubuntu@$CORE_SDK_IP "curl -s http://127.0.0.1:$SDK_PORT/api/status")
        BATHRON_HEIGHT=$(echo "$STATUS" | grep -o '"height":[0-9]*' | head -1 | grep -o '[0-9]*')
        echo "  BATHRON height: ${BATHRON_HEIGHT:-?}"
    else
        echo -e "${RED}NOT RUNNING${NC}"
    fi

    # Check DEX web server
    echo -n "DEX Web (port $DEX_PORT): "
    if $SSH ubuntu@$CORE_SDK_IP "curl -s http://127.0.0.1:$DEX_PORT/" > /dev/null 2>&1; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${RED}NOT RUNNING${NC}"
    fi

    # Check LP Watcher
    echo -n "LP Watcher: "
    if $SSH ubuntu@$CORE_SDK_IP "pgrep -f 'python3 lp_watcher.py'" > /dev/null 2>&1; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${YELLOW}NOT RUNNING${NC} (optional - start manually with .env)"
    fi

    # Check bathrond
    echo -n "BATHRON Daemon: "
    if $SSH ubuntu@$CORE_SDK_IP "~/BATHRON-Core/src/bathron-cli -testnet getblockcount" > /dev/null 2>&1; then
        HEIGHT=$($SSH ubuntu@$CORE_SDK_IP "~/BATHRON-Core/src/bathron-cli -testnet getblockcount 2>/dev/null")
        echo -e "${GREEN}RUNNING${NC} (height: $HEIGHT)"
    else
        echo -e "${RED}NOT RUNNING${NC}"
    fi

    echo ""
    echo "URLs:"
    echo "  DEX:      http://$CORE_SDK_IP:$DEX_PORT/"
    echo "  SDK API:  http://$CORE_SDK_IP:$SDK_PORT/api/status"
    echo "  Explorer: http://57.131.33.151:3001/"
    echo ""
}

view_logs() {
    echo ""
    echo "=== SDK Server Log ==="
    $SSH ubuntu@$CORE_SDK_IP "tail -30 /tmp/sdk_server.log 2>/dev/null || echo 'No logs'"

    echo ""
    echo "=== DEX Web Log ==="
    $SSH ubuntu@$CORE_SDK_IP "tail -20 /tmp/dex_web.log 2>/dev/null || echo 'No logs'"

    echo ""
    echo "=== LP Watcher Log ==="
    $SSH ubuntu@$CORE_SDK_IP "tail -30 /tmp/lp_watcher.log 2>/dev/null || echo 'No logs'"
}

full_deploy() {
    log_info "Full DEX deployment starting..."
    echo ""

    check_ssh || exit 1

    stop_services
    deploy_sdk
    deploy_web
    start_services

    echo ""
    check_status
}

# =============================================================================
# MAIN
# =============================================================================

case "${1:-deploy}" in
    deploy)
        full_deploy
        ;;
    start)
        check_ssh && start_services && check_status
        ;;
    stop)
        check_ssh && stop_services
        ;;
    restart)
        check_ssh && restart_services && check_status
        ;;
    status)
        check_ssh && check_status
        ;;
    logs)
        check_ssh && view_logs
        ;;
    sdk-only)
        check_ssh && deploy_sdk
        ;;
    web-only)
        check_ssh && deploy_web
        ;;
    *)
        echo "Usage: $0 {deploy|start|stop|restart|status|logs|sdk-only|web-only}"
        echo ""
        echo "Commands:"
        echo "  deploy    - Deploy all files and restart services (default)"
        echo "  start     - Start all DEX services"
        echo "  stop      - Stop all DEX services"
        echo "  restart   - Restart all DEX services"
        echo "  status    - Check service status"
        echo "  logs      - View logs"
        echo "  sdk-only  - Deploy SDK files only"
        echo "  web-only  - Deploy web files only"
        exit 1
        ;;
esac
