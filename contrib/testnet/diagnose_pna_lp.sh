#!/bin/bash
# =============================================================================
# diagnose_pna_lp.sh - Diagnose and fix pna-lp server issues on OP1
# =============================================================================

set -e

OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# =============================================================================
# Functions
# =============================================================================

check_process() {
    log_info "Checking uvicorn process..."
    ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$OP1_IP "pgrep -fa uvicorn || echo 'NONE'"
}

check_port() {
    log_info "Checking port 8080..."
    ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$OP1_IP "netstat -tlnp 2>/dev/null | grep :8080 || echo 'NOT_LISTENING'"
}

view_logs() {
    local lines="${1:-50}"
    log_info "Recent logs (last $lines lines):"
    ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$OP1_IP "tail -$lines /tmp/pna-lp.log 2>/dev/null || echo 'No logs found'"
}

restart_server() {
    log_info "Restarting pna-lp server..."

    ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$OP1_IP << 'REMOTE'
cd ~/pna-lp || exit 1

# Kill existing processes
pkill -f 'uvicorn.*server:app' 2>/dev/null || true
sleep 2

# Start server (use system python3 with uvicorn)
nohup python3 -m uvicorn server:app --host 0.0.0.0 --port 8080 > /tmp/pna-lp.log 2>&1 &
sleep 3

# Verify
if pgrep -f uvicorn > /dev/null; then
    echo "SUCCESS: Server started (PID: $(pgrep -f uvicorn))"
    exit 0
else
    echo "FAILED: Server did not start"
    tail -20 /tmp/pna-lp.log
    exit 1
fi
REMOTE

    if [ $? -eq 0 ]; then
        log_success "Server restarted successfully"
        sleep 2
        test_endpoint
    else
        log_error "Restart failed - see logs above"
        return 1
    fi
}

test_endpoint() {
    log_info "Testing HTTP endpoint..."
    if curl -s --connect-timeout 5 "http://$OP1_IP:8080/api/status" | python3 -m json.tool 2>/dev/null; then
        log_success "Server is responding correctly"
    else
        log_error "Server not responding to HTTP requests"
        return 1
    fi
}

full_diagnostic() {
    echo -e "\n${BLUE}=== Full pna-lp Diagnostic ===${NC}\n"
    
    echo -e "${BLUE}[1] Process Status${NC}"
    check_process
    echo ""
    
    echo -e "${BLUE}[2] Port Status${NC}"
    check_port
    echo ""
    
    echo -e "${BLUE}[3] Recent Logs${NC}"
    view_logs 30
    echo ""
    
    echo -e "${BLUE}[4] HTTP Endpoint Test${NC}"
    test_endpoint
    echo ""
}

# =============================================================================
# Main
# =============================================================================

case "${1:-status}" in
    status|diagnostic)
        full_diagnostic
        ;;
    
    restart)
        restart_server
        ;;
    
    logs)
        view_logs "${2:-50}"
        ;;
    
    test)
        test_endpoint
        ;;
    
    *)
        echo "Usage: $0 {status|diagnostic|restart|logs [lines]|test}"
        echo ""
        echo "Commands:"
        echo "  status      - Full diagnostic (default)"
        echo "  restart     - Restart server"
        echo "  logs [N]    - View last N lines of logs (default: 50)"
        echo "  test        - Test HTTP endpoint"
        exit 1
        ;;
esac
