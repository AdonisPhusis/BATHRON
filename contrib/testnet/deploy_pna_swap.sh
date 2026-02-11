#!/bin/bash
# =============================================================================
# deploy_pna.sh - Deploy pna UI to Core+SDK VPS
# =============================================================================
#
# Usage:
#   ./contrib/testnet/deploy_pna.sh [command]
#
# Commands:
#   deploy    - Deploy pna files and start server (default)
#   start     - Start web server only
#   stop      - Stop web server
#   status    - Check status
#   logs      - View logs
#
# =============================================================================

# Don't use set -e, handle errors manually

# Configuration
CORE_SDK_IP="162.19.251.75"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
SCP="scp -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

# Port (same as old DEX)
WEB_PORT=3002

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
pna_DIR="$PROJECT_ROOT/contrib/dex/pna-swap"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# FUNCTIONS
# =============================================================================

check_ssh() {
    log_info "Checking SSH connection..."
    if $SSH ubuntu@$CORE_SDK_IP "echo 'SSH OK'" > /dev/null 2>&1; then
        log_success "SSH connection OK"
        return 0
    else
        log_error "Cannot connect to $CORE_SDK_IP"
        return 1
    fi
}

check_local_files() {
    log_info "Checking local pna files..."

    if [ ! -f "$pna_DIR/index.html" ]; then
        log_error "index.html not found in $pna_DIR"
        return 1
    fi

    if [ ! -f "$pna_DIR/css/style.css" ]; then
        log_error "css/style.css not found"
        return 1
    fi

    if [ ! -f "$pna_DIR/js/pna.js" ]; then
        log_error "js/pna.js not found"
        return 1
    fi

    log_success "Local files OK"
    return 0
}

stop_server() {
    log_info "Stopping old web server..."
    $SSH ubuntu@$CORE_SDK_IP "pkill -f 'http.server.*$WEB_PORT' 2>/dev/null; pkill -f 'php.*$WEB_PORT' 2>/dev/null; true"
    log_success "Server stopped"
}

deploy_files() {
    log_info "Deploying pna files..."

    # Create directories
    $SSH ubuntu@$CORE_SDK_IP "mkdir -p ~/pna/css ~/pna/js ~/pna/img"

    # Copy files one by one
    log_info "Copying index.html..."
    $SCP "$pna_DIR/index.html" ubuntu@$CORE_SDK_IP:~/pna/

    log_info "Copying style.css..."
    $SCP "$pna_DIR/css/style.css" ubuntu@$CORE_SDK_IP:~/pna/css/

    log_info "Copying pna.js..."
    $SCP "$pna_DIR/js/pna.js" ubuntu@$CORE_SDK_IP:~/pna/js/

    log_info "Copying images..."
    $SCP "$pna_DIR/img/"* ubuntu@$CORE_SDK_IP:~/pna/img/ 2>/dev/null || true

    # Copy config files (lp-config.json, etc.)
    if [ -f "$pna_DIR/lp-config.json" ]; then
        log_info "Copying lp-config.json..."
        $SCP "$pna_DIR/lp-config.json" ubuntu@$CORE_SDK_IP:~/pna/
    fi

    log_success "Files deployed to ~/pna/"
}

start_server() {
    log_info "Starting web server on port $WEB_PORT..."

    $SSH ubuntu@$CORE_SDK_IP "cat > /tmp/start_pna.sh << 'SCRIPT'
#!/bin/bash
cd ~/pna
nohup python3 -m http.server $WEB_PORT >> /tmp/pna.log 2>&1 &
echo \$!
SCRIPT
chmod +x /tmp/start_pna.sh
setsid /tmp/start_pna.sh < /dev/null > /tmp/pna_start.out 2>&1
sleep 2
cat /tmp/pna_start.out
pgrep -f 'http.server.*$WEB_PORT' > /dev/null && echo 'Server OK' || echo 'FAILED'
"

    log_success "pna running at http://$CORE_SDK_IP:$WEB_PORT/"
}

check_status() {
    echo ""
    echo "=========================================="
    echo "  pna Status"
    echo "=========================================="
    echo ""

    echo -n "Web Server (port $WEB_PORT): "
    if $SSH ubuntu@$CORE_SDK_IP "curl -s http://127.0.0.1:$WEB_PORT/" > /dev/null 2>&1; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${RED}NOT RUNNING${NC}"
    fi

    echo -n "SDK API (port 8080): "
    if $SSH ubuntu@$CORE_SDK_IP "curl -s http://127.0.0.1:8080/api/status" > /dev/null 2>&1; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${YELLOW}NOT RUNNING${NC} (optional for demo)"
    fi

    echo ""
    echo "URL: http://$CORE_SDK_IP:$WEB_PORT/"
    echo ""
}

view_logs() {
    echo "=== pna Logs ==="
    $SSH ubuntu@$CORE_SDK_IP "tail -50 /tmp/pna.log 2>/dev/null || echo 'No logs'"
}

full_deploy() {
    log_info "Full pna deployment starting..."
    echo ""

    check_ssh || exit 1
    check_local_files || exit 1

    stop_server
    deploy_files
    start_server

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
        check_ssh && start_server && check_status
        ;;
    stop)
        check_ssh && stop_server
        ;;
    status)
        check_ssh && check_status
        ;;
    logs)
        check_ssh && view_logs
        ;;
    *)
        echo "Usage: $0 {deploy|start|stop|status|logs}"
        echo ""
        echo "Commands:"
        echo "  deploy  - Deploy pna files and start server (default)"
        echo "  start   - Start web server only"
        echo "  stop    - Stop web server"
        echo "  status  - Check status"
        echo "  logs    - View logs"
        exit 1
        ;;
esac
