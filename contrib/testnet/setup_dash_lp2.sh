#!/usr/bin/env bash
# =============================================================================
# Dash Testnet Setup for LP2 (OP2 — 57.131.33.214)
#
# Downloads Dash Core v23.0.2, configures testnet, creates wallet,
# saves credentials to ~/.BathronKey/dash.json
#
# Usage:
#   ./setup_dash_lp2.sh setup     # Full install + config
#   ./setup_dash_lp2.sh status    # Check daemon & sync status
#   ./setup_dash_lp2.sh start     # Start dashd
#   ./setup_dash_lp2.sh stop      # Stop dashd
#   ./setup_dash_lp2.sh address   # Show LP wallet address
#   ./setup_dash_lp2.sh logs      # Show debug logs
#   ./setup_dash_lp2.sh keycheck  # Verify key file
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
DASH_VERSION="23.0.2"
DASH_TAR="dashcore-${DASH_VERSION}-x86_64-linux-gnu.tar.gz"
DASH_URL="https://github.com/dashpay/dash/releases/download/v${DASH_VERSION}/${DASH_TAR}"
DASH_DIR="$HOME/dash"
DASH_BIN="$DASH_DIR/bin"
DASH_DATADIR="$HOME/.dashcore"
DASH_CONF="$DASH_DATADIR/dash.conf"
DASHD="$DASH_BIN/dashd"
DASH_CLI="$DASH_BIN/dash-cli"
KEY_DIR="$HOME/.BathronKey"
KEY_FILE="$KEY_DIR/dash.json"

# SSH config
OP2_IP="57.131.33.214"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$OP2_IP"

# ── Helpers ───────────────────────────────────────────────────────────────────
log_info()  { echo -e "\033[36m[DASH]\033[0m $*"; }
log_ok()    { echo -e "\033[32m[DASH ✓]\033[0m $*"; }
log_warn()  { echo -e "\033[33m[DASH !]\033[0m $*"; }
log_err()   { echo -e "\033[31m[DASH ✗]\033[0m $*"; }

remote() { $SSH_CMD "$@"; }

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_setup() {
    log_info "=== Dash Testnet Setup on LP2 ($OP2_IP) ==="

    # Step 1: Download & extract
    log_info "Step 1/6: Downloading Dash Core v${DASH_VERSION}..."
    remote "
        if [ -x $DASHD ]; then
            echo 'Dash binary already exists, skipping download'
        else
            mkdir -p $DASH_DIR
            cd /tmp
            if [ ! -f $DASH_TAR ]; then
                wget -q --show-progress '$DASH_URL' -O $DASH_TAR
            fi
            tar xzf $DASH_TAR
            mkdir -p $DASH_BIN
            cp dashcore-${DASH_VERSION}/bin/dashd $DASH_BIN/
            cp dashcore-${DASH_VERSION}/bin/dash-cli $DASH_BIN/
            chmod +x $DASH_BIN/dashd $DASH_BIN/dash-cli
            rm -rf dashcore-${DASH_VERSION}
            echo 'Dash binaries installed'
        fi
    "
    log_ok "Binaries ready"

    # Step 2: Configure
    log_info "Step 2/6: Configuring dash.conf..."
    local rpc_pass
    rpc_pass=$(openssl rand -hex 16)

    remote "
        mkdir -p $DASH_DATADIR
        cat > $DASH_CONF << 'CONF'
# Dash Testnet Configuration (LP2)
testnet=1
server=1
txindex=1
listen=1
daemon=1

# RPC (global)
rpcuser=dash_lp_rpc
rpcpassword=${rpc_pass}

[test]
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcport=19998
port=19999

# Performance
maxconnections=32
dbcache=256
CONF
        chmod 600 $DASH_CONF
    "
    log_ok "Config written"

    # Step 3: Start daemon
    log_info "Step 3/6: Starting dashd testnet..."
    remote "
        pkill -x dashd 2>/dev/null || true
        sleep 2
        rm -f $DASH_DATADIR/testnet3/.lock 2>/dev/null
        $DASHD -daemon
        sleep 3
        if pgrep -x dashd > /dev/null; then
            echo 'dashd started successfully'
        else
            echo 'ERROR: dashd failed to start'
            exit 1
        fi
    "
    log_ok "Daemon started"

    # Step 4: Wait for RPC
    log_info "Step 4/6: Waiting for RPC..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if remote "$DASH_CLI -testnet getblockchaininfo" &>/dev/null; then
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done
    if [ $retries -ge 30 ]; then
        log_warn "RPC not ready after 60s (daemon may still be loading)"
    else
        log_ok "RPC ready"
    fi

    # Step 5: Generate address
    log_info "Step 5/6: Generating LP address..."
    local lp_address
    lp_address=$(remote "$DASH_CLI -testnet getnewaddress lp_dash" 2>/dev/null || echo "")
    if [ -z "$lp_address" ]; then
        log_warn "Could not generate address yet. Use: ./setup_dash_lp2.sh address"
    else
        log_ok "LP Address: $lp_address"
    fi

    # Step 6: Save credentials
    log_info "Step 6/6: Saving credentials..."
    remote "
        mkdir -p $KEY_DIR
        chmod 700 $KEY_DIR
        cat > $KEY_FILE << KEYEOF
{
    \"name\": \"lp_dash\",
    \"role\": \"liquidity_provider\",
    \"network\": \"testnet\",
    \"address\": \"${lp_address:-pending}\",
    \"wallet\": \"default\",
    \"rpc_user\": \"dash_lp_rpc\",
    \"rpc_password\": \"${rpc_pass}\",
    \"rpc_port\": 19998
}
KEYEOF
        chmod 600 $KEY_FILE
    "
    log_ok "Credentials saved"

    echo ""
    log_info "=== Setup Complete ==="
    log_info "Address: ${lp_address:-pending}"
    log_info "Faucet: http://faucet.testnet.networks.dash.org/"
    log_info "Explorer: https://testnet-insight.dashevo.org/insight/"
}

cmd_status() {
    log_info "=== Dash Status on LP2 ($OP2_IP) ==="
    if ! remote "test -x $DASHD" 2>/dev/null; then
        log_err "Binary not found"; return 1
    fi
    log_ok "Binary: $DASHD"

    if ! remote "pgrep -x dashd" &>/dev/null; then
        log_err "Daemon: NOT running"; return 1
    fi
    log_ok "Daemon: running"

    local info
    info=$(remote "$DASH_CLI -testnet getblockchaininfo" 2>/dev/null || echo "{}")
    if [ "$info" = "{}" ]; then log_warn "RPC not ready"; return 1; fi

    local height headers chain progress
    height=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('blocks',0))" 2>/dev/null || echo "?")
    headers=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('headers',0))" 2>/dev/null || echo "?")
    chain=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('chain','?'))" 2>/dev/null || echo "?")
    progress=$(echo "$info" | python3 -c "import sys,json; print(f'{json.load(sys.stdin).get(\"verificationprogress\",0)*100:.1f}%')" 2>/dev/null || echo "?")

    log_info "Chain:    $chain"
    log_info "Height:   $height / $headers"
    log_info "Progress: $progress"

    local balance peers address
    balance=$(remote "$DASH_CLI -testnet getbalance" 2>/dev/null || echo "?")
    peers=$(remote "$DASH_CLI -testnet getconnectioncount" 2>/dev/null || echo "?")
    address=$(remote "cat $KEY_FILE 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('address','?'))\"" 2>/dev/null || echo "?")
    log_info "Balance:  $balance DASH"
    log_info "Address:  $address"
    log_info "Peers:    $peers"
}

cmd_start() {
    log_info "Starting Dash daemon on LP2..."
    remote "
        if pgrep -x dashd > /dev/null; then echo 'Already running'
        else
            rm -f $DASH_DATADIR/testnet3/.lock 2>/dev/null
            $DASHD -daemon
            sleep 3
            pgrep -x dashd > /dev/null && echo 'Started' || { echo 'Failed'; exit 1; }
        fi
    "
    log_ok "Done"
}

cmd_stop() {
    log_info "Stopping Dash daemon on LP2..."
    remote "$DASH_CLI -testnet stop 2>/dev/null || pkill -x dashd 2>/dev/null || true"
    sleep 2
    log_ok "Stopped"
}

cmd_address() {
    local address
    address=$(remote "cat $KEY_FILE 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('address',''))\"" 2>/dev/null || echo "")
    if [ -z "$address" ] || [ "$address" = "pending" ]; then
        log_info "Generating new address..."
        log_info "Checking wallet status..."
        local wallets
        wallets=$(remote "timeout 15 $DASH_CLI -testnet listwallets 2>&1" || echo "timeout")
        log_info "Wallets: $wallets"

        # Create wallet if none loaded
        if echo "$wallets" | grep -q '^\[\]$'; then
            log_info "No wallet loaded, creating one..."
            remote "timeout 30 $DASH_CLI -testnet createwallet lp_dash_wallet 2>&1" || true
        fi

        local addr_output
        addr_output=$(remote "timeout 30 $DASH_CLI -testnet getnewaddress lp_dash" 2>&1)
        log_info "Output: $addr_output"
        address=$(echo "$addr_output" | grep -v error | grep -v Error | grep -v Traceback | grep -v File | grep -v timeout | grep -E '^[yY]' | head -1)
        if [ -n "$address" ]; then
            remote "
                mkdir -p $KEY_DIR && chmod 700 $KEY_DIR
                python3 -c \"
import json, os
path = '$KEY_FILE'
try:
    with open(path) as f: d = json.load(f)
except: d = {'name':'lp_dash','role':'liquidity_provider','network':'testnet','wallet':'default','rpc_port':19998}
d['address'] = '$address'
with open(path, 'w') as f: json.dump(d, f, indent=4)
os.chmod(path, 0o600)
\"
            "
            log_ok "Address saved"
        else
            log_err "Could not generate address (node still syncing? try again later)"
            return 1
        fi
    fi
    echo ""
    log_info "Dash LP Address: $address"
    log_info "Faucet: http://faucet.testnet.networks.dash.org/"
}

cmd_logs() {
    log_info "=== Dash Debug Logs ==="
    remote "
        for d in ~/.dashcore/testnet3 ~/.dashcore; do
            if [ -f \"\$d/debug.log\" ]; then
                echo \"--- \$d/debug.log (last 30) ---\"
                tail -30 \"\$d/debug.log\"
                break
            fi
        done
        echo ''
        echo '--- Port 19998 check ---'
        ss -tlnp 2>/dev/null | grep 19998 || echo 'Port 19998 not in use'
        echo '--- dashd processes ---'
        ps aux | grep dashd 2>/dev/null | grep -v grep || echo 'No dashd processes'
    "
}

cmd_keycheck() {
    log_info "=== Dash Key File on LP2 ==="
    remote "
        echo '--- dash.json ---'
        cat ~/.BathronKey/dash.json 2>/dev/null || echo '(file not found)'
        echo ''
        python3 -c \"
import json
key_path = '$KEY_FILE'
conf_path = '$DASH_CONF'
try:
    with open(key_path) as f: d = json.load(f)
except: print('Cannot read dash.json'); exit(0)
if 'rpc_user' in d and 'rpc_password' in d: print('RPC credentials present'); exit(0)
rpc_user = rpc_pass = ''
with open(conf_path) as f:
    for line in f:
        line = line.strip()
        if line.startswith('rpcuser='): rpc_user = line.split('=',1)[1]
        elif line.startswith('rpcpassword='): rpc_pass = line.split('=',1)[1]
if rpc_user and rpc_pass:
    d['rpc_user'] = rpc_user; d['rpc_password'] = rpc_pass
    with open(key_path, 'w') as f: json.dump(d, f, indent=4)
    import os; os.chmod(key_path, 0o600)
    print('Fixed: added rpc credentials')
else: print('Warning: no RPC creds in dash.conf')
\"
    "
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
    setup)    cmd_setup ;;
    status)   cmd_status ;;
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    address)  cmd_address ;;
    logs)     cmd_logs ;;
    keycheck) cmd_keycheck ;;
    *) echo "Usage: $0 {setup|status|start|stop|address|logs|keycheck}"; exit 1 ;;
esac
