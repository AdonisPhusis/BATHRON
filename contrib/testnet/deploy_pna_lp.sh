#!/bin/bash
# =============================================================================
# deploy_pna_lp.sh - Deploy pna-lp server (supports LP1 + LP2)
#
# Usage:
#   ./deploy_pna_lp.sh deploy        # LP1 on OP1 (default)
#   ./deploy_pna_lp.sh deploy lp2    # LP2 on OP2
#   ./deploy_pna_lp.sh status lp2
#   ./deploy_pna_lp.sh logs lp2
# =============================================================================

set -e

# LP target resolution
LP_TARGET="${2:-lp1}"
case "$LP_TARGET" in
    lp1|"")
        TARGET_IP="57.131.33.152"
        LP_ID="lp_pna_01"
        LP_NAME="pna LP"
        ;;
    lp2)
        TARGET_IP="57.131.33.214"
        LP_ID="lp_pna_02"
        LP_NAME="pna LP 2"
        ;;
    *)
        echo "Unknown LP target: $LP_TARGET (use 'lp1' or 'lp2')"
        exit 1
        ;;
esac

# Configuration
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
SCP="scp -i $SSH_KEY $SSH_OPTS -C"

SDK_PORT=8080

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SDK_DIR="$PROJECT_ROOT/contrib/dex/pna-lp"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${BLUE}Target: ${LP_NAME} (${LP_ID}) @ ${TARGET_IP}${NC}"

# =============================================================================
# FAST DEPLOY - Uses rsync and skips unchanged files
# =============================================================================

fast_deploy() {
    log_info "Fast deploy starting..."

    # Quick SSH check
    if ! $SSH ubuntu@$TARGET_IP "true" 2>/dev/null; then
        log_error "Cannot connect to $TARGET_IP"
        exit 1
    fi

    # Create remote dirs in one command
    $SSH ubuntu@$TARGET_IP "mkdir -p ~/pna-sdk/{static/css,static/js,scripts,routes} ~/bathron/bin ~/.bathron"

    # Deploy SDK core files using SCP (force overwrite to avoid rsync caching issues)
    log_info "Syncing SDK files..."
    $SCP "$SDK_DIR/server.py" "$SDK_DIR/requirements.txt" "$SDK_DIR/register_lp.py" ubuntu@$TARGET_IP:~/pna-sdk/

    rsync -avz \
        -e "ssh -i $SSH_KEY $SSH_OPTS" \
        "$SDK_DIR/static/" \
        ubuntu@$TARGET_IP:~/pna-sdk/static/

    rsync -avz \
        -e "ssh -i $SSH_KEY $SSH_OPTS" \
        "$SDK_DIR/scripts/" \
        ubuntu@$TARGET_IP:~/pna-sdk/scripts/

    # Deploy Python SDK module
    if [ -d "$SDK_DIR/sdk" ]; then
        log_info "Syncing Python SDK..."
        rsync -avz \
            -e "ssh -i $SSH_KEY $SSH_OPTS" \
            "$SDK_DIR/sdk/" \
            ubuntu@$TARGET_IP:~/pna-sdk/sdk/
    fi

    # Deploy route modules (extracted from server.py)
    if [ -d "$SDK_DIR/routes" ]; then
        log_info "Syncing route modules..."
        rsync -avz \
            -e "ssh -i $SSH_KEY $SSH_OPTS" \
            "$SDK_DIR/routes/" \
            ubuntu@$TARGET_IP:~/pna-sdk/routes/
    fi

    # Deploy BATHRON binaries (skip if unchanged)
    log_info "Syncing BATHRON binaries..."
    rsync -avz \
        -e "ssh -i $SSH_KEY $SSH_OPTS" \
        "$PROJECT_ROOT/src/bathrond" \
        "$PROJECT_ROOT/src/bathron-cli" \
        ubuntu@$TARGET_IP:~/bathron/bin/

    # Ensure firewall allows port 8080
    log_info "Ensuring port ${SDK_PORT} is open..."
    $SSH ubuntu@$TARGET_IP "sudo ufw allow ${SDK_PORT}/tcp 2>/dev/null || sudo iptables -C INPUT -p tcp --dport ${SDK_PORT} -j ACCEPT 2>/dev/null || sudo iptables -A INPUT -p tcp --dport ${SDK_PORT} -j ACCEPT 2>/dev/null || true"

    # Deploy BTC WIF extraction script
    if [ -f "$SDK_DIR/extract_btc_wif.py" ]; then
        $SCP "$SDK_DIR/extract_btc_wif.py" ubuntu@$TARGET_IP:~/pna-sdk/
    fi

    # Setup venv and install/update requirements
    log_info "Checking venv and requirements..."
    $SSH ubuntu@$TARGET_IP "cd ~/pna-sdk && chmod +x scripts/*.sh ~/bathron/bin/* 2>/dev/null; [ ! -d venv ] && python3 -m venv venv; ./venv/bin/pip install -q -r requirements.txt"

    # Extract BTC WIF if not already in btc.json
    if [ -f "$SDK_DIR/extract_btc_wif.py" ]; then
        if $SSH ubuntu@$TARGET_IP "grep -q claim_wif ~/.BathronKey/btc.json 2>/dev/null"; then
            log_info "BTC claim_wif already configured"
        else
            log_info "Extracting BTC claim_wif from wallet..."
            $SSH ubuntu@$TARGET_IP "cd ~/pna-sdk && ./venv/bin/python extract_btc_wif.py --cli-path ~/bitcoin/bin/bitcoin-cli --datadir ~/.bitcoin-signet 2>&1" || log_error "WIF extraction failed (non-fatal)"
        fi
    fi

    # Kill any existing server and start fresh
    log_info "Restarting server (LP_ID=$LP_ID)..."
    # Aggressively kill ALL related processes + stop Docker containers on same port
    $SSH ubuntu@$TARGET_IP "
        # Stop Docker container if running (pna-lp)
        docker stop pna-lp 2>/dev/null && echo 'Stopped Docker container pna-lp' || true
        docker rm pna-lp 2>/dev/null || true
        # Kill by port
        sudo fuser -k ${SDK_PORT}/tcp 2>/dev/null || true
        # Kill by name patterns
        pkill -9 -f 'uvicorn.*server' 2>/dev/null || true
        pkill -9 -f 'python.*server:app' 2>/dev/null || true
        pkill -9 -f 'python.*uvicorn' 2>/dev/null || true
        # Clear Python bytecode cache
        find ~/pna-sdk -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
        find ~/pna-sdk -name '*.pyc' -delete 2>/dev/null || true
        sleep 2
    " || true

    # Start server via a wrapper script to fully detach from SSH
    $SSH ubuntu@$TARGET_IP "cat > /tmp/start_lp.sh << 'SCRIPT'
#!/bin/bash
cd ~/pna-sdk
export LP_ID='$LP_ID'
export LP_NAME='$LP_NAME'
nohup ./venv/bin/python -m uvicorn server:app --host 0.0.0.0 --port $SDK_PORT --workers 1 >> /tmp/pna-sdk.log 2>&1 &
echo \$!
SCRIPT
chmod +x /tmp/start_lp.sh
setsid /tmp/start_lp.sh < /dev/null > /tmp/lp_start.out 2>&1
sleep 2
cat /tmp/lp_start.out
pgrep -f uvicorn > /dev/null && echo 'Server OK' || echo 'FAILED'
"

    # Quick healthcheck
    if curl -s --connect-timeout 5 "http://$TARGET_IP:$SDK_PORT/api/status" > /dev/null 2>&1; then
        log_success "Deployed and healthy! http://$TARGET_IP:$SDK_PORT/"
    else
        log_success "Deployed (server starting). http://$TARGET_IP:$SDK_PORT/"
    fi
}

# =============================================================================
# OTHER COMMANDS
# =============================================================================

stop_server() {
    log_info "Stopping pna-lp server on $TARGET_IP..."
    $SSH ubuntu@$TARGET_IP "pkill -f 'uvicorn.*server:app' 2>/dev/null; \
        fuser -k ${SDK_PORT}/tcp 2>/dev/null; sleep 1; echo done" || true
    log_success "Server stopped"
}

start_server() {
    log_info "Starting pna-lp server on $TARGET_IP (LP_ID=$LP_ID)..."
    $SSH ubuntu@$TARGET_IP "cd ~/pna-sdk && LP_ID='$LP_ID' LP_NAME='$LP_NAME' nohup ./venv/bin/python -m uvicorn server:app --host 0.0.0.0 --port $SDK_PORT --workers 1 > /tmp/pna-sdk.log 2>&1 &"
    sleep 3
    log_success "Server started: http://$TARGET_IP:$SDK_PORT/"
}

restart_server() {
    log_info "Restarting pna-lp server on $TARGET_IP..."

    # Stop
    $SSH ubuntu@$TARGET_IP "pkill -f 'uvicorn.*server:app' 2>/dev/null || true"
    log_info "Stopped (waiting 2s)..."
    sleep 2

    # Start
    $SSH ubuntu@$TARGET_IP "cd ~/pna-sdk && LP_ID='$LP_ID' LP_NAME='$LP_NAME' nohup ./venv/bin/python -m uvicorn server:app --host 0.0.0.0 --port $SDK_PORT --workers 1 > /tmp/pna-sdk.log 2>&1 &"
    log_info "Started (waiting 3s)..."
    sleep 3

    # Check
    log_info "Checking status..."
    check_status
}

check_status() {
    echo -e "\n${BLUE}=== pna SDK Status ($LP_NAME @ $TARGET_IP) ===${NC}\n"

    if curl -s --connect-timeout 3 "http://$TARGET_IP:$SDK_PORT/api/status" | python3 -m json.tool 2>/dev/null; then
        echo -e "\n${GREEN}Server is running${NC}"
    else
        echo -e "${RED}Server not responding${NC}"
        echo -e "\n${YELLOW}Recent logs:${NC}"
        $SSH ubuntu@$TARGET_IP "tail -20 /tmp/pna-sdk.log 2>/dev/null || echo 'No logs'"
    fi

    echo -e "\nURL: http://$TARGET_IP:$SDK_PORT/"
}

view_logs() {
    $SSH ubuntu@$TARGET_IP "tail -100 /tmp/pna-sdk.log 2>/dev/null || echo 'No logs'"
}

# =============================================================================
# MAIN
# =============================================================================

cleanup_stuck() {
    echo -e "\n${BLUE}=== Cleanup stuck swaps ($LP_NAME @ $TARGET_IP) ===${NC}\n"

    # List stuck swaps via admin endpoint (localhost-only on VPS)
    echo -e "${YELLOW}Listing stuck swaps...${NC}"
    STUCK=$($SSH ubuntu@$TARGET_IP "curl -s http://localhost:$SDK_PORT/api/admin/stuck-swaps" 2>/dev/null)
    COUNT=$(echo "$STUCK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null)

    if [ "$COUNT" = "0" ] || [ -z "$COUNT" ]; then
        echo -e "${GREEN}No stuck swaps found${NC}"
        return
    fi

    echo -e "${YELLOW}Found $COUNT stuck swap(s):${NC}"
    echo "$STUCK" | python3 -m json.tool

    # Force-fail each stuck swap
    SWAP_IDS=$(echo "$STUCK" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('stuck_swaps', []):
    print(s['swap_id'])
" 2>/dev/null)

    for SID in $SWAP_IDS; do
        echo -e "${YELLOW}Force-failing $SID...${NC}"
        RESULT=$($SSH ubuntu@$TARGET_IP "curl -s -X POST http://localhost:$SDK_PORT/api/admin/swap/$SID/force-fail" 2>/dev/null)
        echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
    done

    echo -e "\n${GREEN}Cleanup complete. Run '$0 status' to verify.${NC}"
}

case "${1:-deploy}" in
    deploy)  fast_deploy ;;
    start)   start_server ;;
    stop)    stop_server ;;
    restart) restart_server ;;
    status)  check_status ;;
    logs)    view_logs ;;
    cleanup) cleanup_stuck ;;
    *)
        echo "Usage: $0 {deploy|start|stop|restart|status|logs|cleanup} [lp1|lp2]"
        echo ""
        echo "  lp1 (default) - OP1 (57.131.33.152)"
        echo "  lp2           - OP2 (57.131.33.214)"
        exit 1
        ;;
esac
