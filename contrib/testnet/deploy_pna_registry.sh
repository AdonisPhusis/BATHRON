#!/bin/bash
# =============================================================================
# deploy_pna_registry.sh - Deploy PNA LP Registry to Core+SDK VPS
# =============================================================================
#
# Usage:
#   ./contrib/testnet/deploy_pna_registry.sh [command]
#
# Commands:
#   deploy    - Deploy registry and start service (default)
#   start     - Start registry only
#   stop      - Stop registry
#   status    - Check status
#   logs      - View logs
#
# =============================================================================

# Configuration
CORE_SDK_IP="162.19.251.75"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
SCP="scp -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

REGISTRY_PORT=3003

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REGISTRY_DIR="$PROJECT_ROOT/contrib/dex/pna-registry"

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
    log_info "Checking local registry files..."

    if [ ! -f "$REGISTRY_DIR/registry_service.py" ]; then
        log_error "registry_service.py not found in $REGISTRY_DIR"
        return 1
    fi

    if [ ! -f "$REGISTRY_DIR/requirements.txt" ]; then
        log_error "requirements.txt not found"
        return 1
    fi

    log_success "Local files OK"
    return 0
}

stop_registry() {
    log_info "Stopping registry service..."
    $SSH ubuntu@$CORE_SDK_IP "
        pkill -f 'uvicorn registry_service:app' 2>/dev/null
        pkill -f 'registry_service' 2>/dev/null
        sleep 1
        # Force kill if still running
        pkill -9 -f 'registry_service' 2>/dev/null
        true
    "
    log_success "Registry stopped"
}

deploy_files() {
    log_info "Deploying registry files..."

    # Create directory
    $SSH ubuntu@$CORE_SDK_IP "mkdir -p ~/pna-registry"

    # Copy files
    log_info "Copying registry_service.py..."
    $SCP "$REGISTRY_DIR/registry_service.py" ubuntu@$CORE_SDK_IP:~/pna-registry/

    log_info "Copying requirements.txt..."
    $SCP "$REGISTRY_DIR/requirements.txt" ubuntu@$CORE_SDK_IP:~/pna-registry/

    log_success "Files deployed to ~/pna-registry/"
}

install_deps() {
    log_info "Installing Python dependencies..."
    $SSH ubuntu@$CORE_SDK_IP "
        cd ~/pna-registry
        # Use venv if available, otherwise --break-system-packages
        if [ -d venv ]; then
            source venv/bin/activate
            pip install -q -r requirements.txt 2>&1 | tail -3
        elif python3 -m venv venv 2>/dev/null; then
            source venv/bin/activate
            pip install -q -r requirements.txt 2>&1 | tail -3
        else
            pip3 install -q --break-system-packages -r requirements.txt 2>&1 | tail -3
        fi
    "
    log_success "Dependencies installed"
}

start_registry() {
    log_info "Starting registry on port $REGISTRY_PORT..."

    $SSH ubuntu@$CORE_SDK_IP "
cat > /tmp/start_registry.sh << 'REMOTESCRIPT'
#!/bin/bash
cd ~/pna-registry
# Activate venv if it exists
if [ -f venv/bin/activate ]; then
    source venv/bin/activate
fi
nohup python3 -m uvicorn registry_service:app \
    --host 0.0.0.0 \
    --port 3003 \
    --log-level info \
    >> /tmp/pna-registry.log 2>&1 &
echo \$!
REMOTESCRIPT
chmod +x /tmp/start_registry.sh
setsid /tmp/start_registry.sh < /dev/null > /tmp/registry_start.out 2>&1
sleep 3
cat /tmp/registry_start.out
pgrep -f 'registry_service' > /dev/null && echo 'Registry OK' || echo 'FAILED'
"

    log_success "Registry running at http://$CORE_SDK_IP:$REGISTRY_PORT/"
}

check_status() {
    echo ""
    echo "=========================================="
    echo "  PNA LP Registry Status"
    echo "=========================================="
    echo ""

    echo -n "Registry (port $REGISTRY_PORT): "
    local status_json
    status_json=$($SSH ubuntu@$CORE_SDK_IP "curl -s http://127.0.0.1:$REGISTRY_PORT/api/registry/status 2>/dev/null")
    if [ $? -eq 0 ] && [ -n "$status_json" ]; then
        echo -e "${GREEN}RUNNING${NC}"
        echo ""
        echo "  Chain height:     $(echo "$status_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('chain_height','?'))" 2>/dev/null)"
        echo "  Scanned to:       $(echo "$status_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('last_scanned_height','?'))" 2>/dev/null)"
        echo "  Total LPs:        $(echo "$status_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('lp_count_total','?'))" 2>/dev/null)"
        echo "  Online LPs:       $(echo "$status_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('lp_count_online','?'))" 2>/dev/null)"
        echo "  Tier 1 LPs:       $(echo "$status_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('lp_count_tier1','?'))" 2>/dev/null)"
    else
        echo -e "${RED}NOT RUNNING${NC}"
    fi

    echo ""
    echo "API: http://$CORE_SDK_IP:$REGISTRY_PORT/api/registry/lps"
    echo ""
}

view_logs() {
    echo "=== PNA Registry Logs ==="
    $SSH ubuntu@$CORE_SDK_IP "tail -50 /tmp/pna-registry.log 2>/dev/null || echo 'No logs'"
}

full_deploy() {
    log_info "Full PNA Registry deployment starting..."
    echo ""

    check_ssh || exit 1
    check_local_files || exit 1

    stop_registry
    deploy_files
    install_deps
    start_registry

    echo ""
    check_status
}

# =============================================================================
# MAIN
# =============================================================================

CMD="${1:-deploy}"

case "$CMD" in
    deploy)  full_deploy ;;
    start)   check_ssh && start_registry ;;
    stop)    check_ssh && stop_registry ;;
    restart) check_ssh && stop_registry && start_registry && sleep 3 && check_status ;;
    reset)
        # Wipe persisted state and rescan from block 0
        check_ssh || exit 1
        stop_registry
        log_info "Wiping persisted registry state..."
        $SSH ubuntu@$CORE_SDK_IP "rm -f ~/.bathron/lp_registry.json"
        log_success "Registry state wiped"
        start_registry
        sleep 5
        check_status
        ;;
    status)  check_ssh && check_status ;;
    logs)    check_ssh && view_logs ;;
    *)
        echo "Usage: $0 {deploy|start|stop|restart|reset|status|logs}"
        exit 1
        ;;
esac
