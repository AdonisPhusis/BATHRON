#!/usr/bin/env bash
# =============================================================================
# PIVX Testnet Setup for LP2 (OP2 — 57.131.33.214)
#
# Downloads PIVX v5.6.1, configures testnet, creates wallet,
# saves credentials to ~/.BathronKey/pivx.json
#
# Usage:
#   ./setup_pivx_lp2.sh setup     # Full install + config
#   ./setup_pivx_lp2.sh status    # Check daemon & sync status
#   ./setup_pivx_lp2.sh start     # Start pivxd
#   ./setup_pivx_lp2.sh stop      # Stop pivxd
#   ./setup_pivx_lp2.sh address   # Show LP wallet address
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PIVX_VERSION="5.6.1"
PIVX_TAR="pivx-${PIVX_VERSION}-x86_64-linux-gnu.tar.gz"
PIVX_URL="https://github.com/PIVX-Project/PIVX/releases/download/v${PIVX_VERSION}/${PIVX_TAR}"
PIVX_DIR="$HOME/pivx"
PIVX_BIN="$PIVX_DIR/bin"
PIVX_DATADIR="$HOME/.pivx"
PIVX_CONF="$PIVX_DATADIR/pivx.conf"
PIVXD="$PIVX_BIN/pivxd"
PIVX_CLI="$PIVX_BIN/pivx-cli"
WALLET_NAME="lp_pivx_wallet"
KEY_DIR="$HOME/.BathronKey"
KEY_FILE="$KEY_DIR/pivx.json"
LP_ID="${LP_ID:-lp_pna_02}"

# SSH config for remote execution
OP2_IP="57.131.33.214"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$OP2_IP"

# ── Helpers ───────────────────────────────────────────────────────────────────
log_info()  { echo -e "\033[36m[PIVX]\033[0m $*"; }
log_ok()    { echo -e "\033[32m[PIVX ✓]\033[0m $*"; }
log_warn()  { echo -e "\033[33m[PIVX !]\033[0m $*"; }
log_err()   { echo -e "\033[31m[PIVX ✗]\033[0m $*"; }

remote() {
    $SSH_CMD "$@"
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_setup() {
    log_info "=== PIVX Testnet Setup on LP2 ($OP2_IP) ==="

    # Step 1: Download & extract
    log_info "Step 1/7: Downloading PIVX v${PIVX_VERSION}..."
    remote "
        if [ -x $PIVXD ]; then
            echo 'PIVX binary already exists, skipping download'
        else
            mkdir -p $PIVX_DIR
            cd /tmp
            if [ ! -f $PIVX_TAR ]; then
                wget -q --show-progress '$PIVX_URL' -O $PIVX_TAR
            fi
            tar xzf $PIVX_TAR
            # PIVX extracts to pivx-VERSION/
            mkdir -p $PIVX_BIN
            cp pivx-${PIVX_VERSION}/bin/pivxd $PIVX_BIN/
            cp pivx-${PIVX_VERSION}/bin/pivx-cli $PIVX_BIN/
            chmod +x $PIVX_BIN/pivxd $PIVX_BIN/pivx-cli
            rm -rf pivx-${PIVX_VERSION}
            echo 'PIVX binaries installed'
        fi
    "
    log_ok "Binaries ready"

    # Step 2: Generate RPC password
    log_info "Step 2/7: Configuring pivx.conf..."
    local rpc_pass
    rpc_pass=$(openssl rand -hex 16)

    remote "
        mkdir -p $PIVX_DATADIR
        cat > $PIVX_CONF << 'CONF'
# PIVX Testnet Configuration (LP2)
testnet=1
server=1
txindex=1
listen=1
daemon=1

# RPC (global)
rpcuser=pivx_lp_rpc
rpcpassword=${rpc_pass}

[test]
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcport=51476
port=51474

# Performance
maxconnections=32
dbcache=256

# Logging
printtoconsole=0
CONF
        chmod 600 $PIVX_CONF
    "
    log_ok "Config written"

    # Step 3: Start daemon
    log_info "Step 3/7: Starting pivxd testnet..."
    remote "
        # Kill any existing instance & clean lock
        pkill -x pivxd 2>/dev/null || true
        sleep 2
        rm -f ~/.pivx/testnet5/.lock 2>/dev/null
        $PIVXD -daemon
        sleep 3
        # Verify it started
        if pgrep -x pivxd > /dev/null; then
            echo 'pivxd started successfully'
        else
            echo 'ERROR: pivxd failed to start'
            exit 1
        fi
    "
    log_ok "Daemon started"

    # Step 4: Wait for RPC to be ready
    log_info "Step 4/7: Waiting for RPC..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if remote "$PIVX_CLI -testnet getblockchaininfo" &>/dev/null; then
            break
        fi
        retries=$((retries + 1))
        sleep 2
    done
    if [ $retries -ge 30 ]; then
        log_err "RPC not ready after 60s"
        return 1
    fi
    log_ok "RPC ready"

    # Step 5: Create wallet
    log_info "Step 5/7: Creating wallet..."
    remote "
        # PIVX doesn't have multi-wallet like Bitcoin Core
        # The default wallet is used. Just generate an address.
        echo 'Using default PIVX wallet'
    "
    log_ok "Wallet ready"

    # Step 6: Generate address
    log_info "Step 6/7: Generating LP address..."
    local lp_address
    lp_address=$(remote "$PIVX_CLI -testnet getnewaddress lp_pivx legacy" 2>/dev/null || echo "")

    if [ -z "$lp_address" ]; then
        log_warn "Could not generate address (node may still be loading)"
        log_info "Try again with: ./setup_pivx_lp2.sh address"
    else
        log_ok "LP Address: $lp_address"
    fi

    # Step 7: Save to ~/.BathronKey/pivx.json
    log_info "Step 7/7: Saving credentials..."
    remote "
        mkdir -p $KEY_DIR
        chmod 700 $KEY_DIR
        cat > $KEY_FILE << KEYEOF
{
    \"name\": \"lp_pivx\",
    \"role\": \"liquidity_provider\",
    \"network\": \"testnet\",
    \"address\": \"${lp_address:-pending}\",
    \"wallet\": \"default\",
    \"rpc_user\": \"pivx_lp_rpc\",
    \"rpc_password\": \"${rpc_pass}\",
    \"rpc_port\": 51476
}
KEYEOF
        chmod 600 $KEY_FILE
    "
    log_ok "Credentials saved to $KEY_FILE"

    # Summary
    echo ""
    log_info "=== Setup Complete ==="
    log_info "PIVX Address: ${lp_address:-pending}"
    log_info "Faucet: https://faucet.pivx.link/"
    log_info "Explorer: https://testnet.pivx.link/"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Send testnet PIVX to: ${lp_address:-pending}"
    log_info "  2. Wait for sync: ./setup_pivx_lp2.sh status"
    log_info "  3. Deploy LP2 with PIVX support"
}

cmd_status() {
    log_info "=== PIVX Status on LP2 ($OP2_IP) ==="

    # Check binary
    if remote "test -x $PIVXD" 2>/dev/null; then
        log_ok "Binary: $PIVXD"
    else
        log_err "Binary not found at $PIVXD"
        return 1
    fi

    # Check daemon
    if remote "pgrep -x pivxd" &>/dev/null; then
        log_ok "Daemon: running"
    else
        log_err "Daemon: NOT running"
        log_info "Start with: ./setup_pivx_lp2.sh start"
        return 1
    fi

    # Blockchain info
    local info
    info=$(remote "$PIVX_CLI -testnet getblockchaininfo" 2>/dev/null || echo "{}")
    if [ "$info" = "{}" ]; then
        log_warn "Could not get blockchain info (RPC not ready?)"
        return 1
    fi

    local height headers chain progress
    height=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('blocks',0))" 2>/dev/null || echo "?")
    headers=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('headers',0))" 2>/dev/null || echo "?")
    chain=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('chain','?'))" 2>/dev/null || echo "?")
    progress=$(echo "$info" | python3 -c "import sys,json; print(f'{json.load(sys.stdin).get(\"verificationprogress\",0)*100:.1f}%')" 2>/dev/null || echo "?")

    log_info "Chain:    $chain"
    log_info "Height:   $height / $headers"
    log_info "Progress: $progress"

    # Balance
    local balance
    balance=$(remote "$PIVX_CLI -testnet getbalance" 2>/dev/null || echo "?")
    log_info "Balance:  $balance PIVX"

    # Wallet address
    local address
    address=$(remote "cat $KEY_FILE 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('address','?'))\"" 2>/dev/null || echo "?")
    log_info "Address:  $address"

    # Peers
    local peers
    peers=$(remote "$PIVX_CLI -testnet getconnectioncount" 2>/dev/null || echo "?")
    log_info "Peers:    $peers"
}

cmd_start() {
    log_info "Starting PIVX daemon on LP2..."
    remote "
        if pgrep -x pivxd > /dev/null; then
            echo 'Already running'
        else
            $PIVXD -daemon
            sleep 3
            if pgrep -x pivxd > /dev/null; then
                echo 'Started successfully'
            else
                echo 'Failed to start'
                exit 1
            fi
        fi
    "
    log_ok "Done"
}

cmd_stop() {
    log_info "Stopping PIVX daemon on LP2..."
    remote "$PIVX_CLI -testnet stop" 2>/dev/null || remote "pkill -f pivxd" 2>/dev/null || true
    sleep 2
    log_ok "Stopped"
}

cmd_address() {
    local address
    address=$(remote "cat $KEY_FILE 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('address',''))\"" 2>/dev/null || echo "")

    if [ -z "$address" ] || [ "$address" = "pending" ]; then
        log_info "Generating new address..."
        local addr_output
        addr_output=$(remote "$PIVX_CLI -testnet getnewaddress lp_pivx" 2>&1)
        log_info "getnewaddress output: $addr_output"
        address=$(echo "$addr_output" | grep -v error | grep -v Error | grep -v Traceback | grep -v File | head -1)
        if [ -n "$address" ]; then
            # Create or update key file
            remote "
                mkdir -p $KEY_DIR
                chmod 700 $KEY_DIR
                python3 -c \"
import json, os
path = '$KEY_FILE'
try:
    with open(path) as f:
        d = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    d = {'name': 'lp_pivx', 'role': 'liquidity_provider', 'network': 'testnet', 'wallet': 'default', 'rpc_port': 51476}
d['address'] = '$address'
with open(path, 'w') as f:
    json.dump(d, f, indent=4)
os.chmod(path, 0o600)
\"
            "
            log_ok "New address saved"
        else
            log_err "Could not generate address"
            return 1
        fi
    fi

    echo ""
    log_info "PIVX LP Address: $address"
    log_info "Faucet: https://faucet.pivx.link/"
}

cmd_keycheck() {
    log_info "=== PIVX Key File on LP2 ==="
    remote "
        echo '--- ~/.BathronKey/ ---'
        ls -la ~/.BathronKey/ 2>/dev/null || echo '(dir not found)'
        echo ''
        echo '--- pivx.json ---'
        cat ~/.BathronKey/pivx.json 2>/dev/null || echo '(file not found)'
        echo ''
        # Auto-fix: add rpc credentials from pivx.conf if missing
        python3 -c \"
import json
key_path = '$KEY_FILE'
conf_path = '$PIVX_CONF'
try:
    with open(key_path) as f:
        d = json.load(f)
except:
    print('Cannot read pivx.json')
    exit(0)
if 'rpc_user' in d and 'rpc_password' in d:
    print('RPC credentials already present')
    exit(0)
# Read from pivx.conf
rpc_user = rpc_pass = ''
with open(conf_path) as f:
    for line in f:
        line = line.strip()
        if line.startswith('rpcuser='):
            rpc_user = line.split('=',1)[1]
        elif line.startswith('rpcpassword='):
            rpc_pass = line.split('=',1)[1]
if rpc_user and rpc_pass:
    d['rpc_user'] = rpc_user
    d['rpc_password'] = rpc_pass
    with open(key_path, 'w') as f:
        json.dump(d, f, indent=4)
    import os; os.chmod(key_path, 0o600)
    print('Fixed: added rpc credentials from pivx.conf')
else:
    print('Warning: could not find RPC creds in pivx.conf')
\"
    "
}

cmd_logs() {
    log_info "=== PIVX Debug Logs ==="
    remote "
        echo '--- ~/.pivx/ contents ---'
        ls -la ~/.pivx/ 2>/dev/null || echo '(dir not found)'
        echo ''
        for d in ~/.pivx/testnet5 ~/.pivx/testnet3 ~/.pivx/testnet ~/.pivx; do
            if [ -f \"\$d/debug.log\" ]; then
                echo \"--- \$d/debug.log (last 50) ---\"
                tail -50 \"\$d/debug.log\"
                break
            fi
        done
        echo ''
        echo '--- Port 51475 check ---'
        ss -tlnp 2>/dev/null | grep 51475 || echo 'Port 51475 not in use'
        echo ''
        echo '--- Lock file check ---'
        ls -la ~/.pivx/testnet5/.lock 2>/dev/null || echo 'No lock file'
        echo ''
        echo '--- PIVX processes ---'
        ps aux | grep pivx 2>/dev/null | grep -v grep || echo 'No pivx processes'
        echo ''
        echo '--- pivxd version ---'
        $PIVXD --version 2>&1 | head -1 || echo 'pivxd --version failed'
    "
}

cmd_disk() {
    log_info "=== Disk Usage on LP2 ($OP2_IP) ==="
    remote "
        echo '--- Filesystem ---'
        df -h / /home 2>/dev/null | grep -v tmpfs
        echo ''
        echo '--- Chain data sizes ---'
        du -sh ~/.pivx 2>/dev/null || echo 'PIVX: (not found)'
        du -sh ~/.dashcore 2>/dev/null || echo 'Dash: (not found)'
        du -sh ~/.zcash 2>/dev/null || echo 'Zcash: (not found)'
        du -sh ~/.bitcoin-signet 2>/dev/null || echo 'BTC Signet: (not found)'
        du -sh ~/.bathron 2>/dev/null || echo 'BATHRON: (not found)'
        echo ''
        echo '--- Total home ---'
        du -sh ~ 2>/dev/null || echo '?'
    "
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
    setup)   cmd_setup ;;
    status)  cmd_status ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    address) cmd_address ;;
    logs)    cmd_logs ;;
    keycheck) cmd_keycheck ;;
    disk)    cmd_disk ;;
    *)
        echo "Usage: $0 {setup|status|start|stop|address|logs|keycheck}"
        exit 1
        ;;
esac
