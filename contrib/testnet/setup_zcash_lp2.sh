#!/usr/bin/env bash
# =============================================================================
# Zcash Testnet Setup for LP2 (OP2 — 57.131.33.214)
#
# Downloads Zcash v6.11.0, fetches Sapling params, configures testnet,
# saves credentials to ~/.BathronKey/zcash.json
#
# Usage:
#   ./setup_zcash_lp2.sh setup     # Full install + config
#   ./setup_zcash_lp2.sh status    # Check daemon & sync status
#   ./setup_zcash_lp2.sh start     # Start zcashd
#   ./setup_zcash_lp2.sh stop      # Stop zcashd
#   ./setup_zcash_lp2.sh address   # Show LP wallet address
#   ./setup_zcash_lp2.sh logs      # Show debug logs
#   ./setup_zcash_lp2.sh keycheck  # Verify key file
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
ZCASH_VERSION="6.11.0"
ZCASH_TAR="zcash-${ZCASH_VERSION}-linux64-debian-bookworm.tar.gz"
ZCASH_URL="https://download.z.cash/downloads/${ZCASH_TAR}"
ZCASH_DIR="$HOME/zcash"
ZCASH_BIN="$ZCASH_DIR/bin"
ZCASH_DATADIR="$HOME/.zcash"
ZCASH_CONF="$ZCASH_DATADIR/zcash.conf"
ZCASHD="$ZCASH_BIN/zcashd"
ZCASH_CLI="$ZCASH_BIN/zcash-cli"
KEY_DIR="$HOME/.BathronKey"
KEY_FILE="$KEY_DIR/zcash.json"

# SSH config
OP2_IP="57.131.33.214"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@$OP2_IP"

# ── Helpers ───────────────────────────────────────────────────────────────────
log_info()  { echo -e "\033[36m[ZEC]\033[0m $*"; }
log_ok()    { echo -e "\033[32m[ZEC ✓]\033[0m $*"; }
log_warn()  { echo -e "\033[33m[ZEC !]\033[0m $*"; }
log_err()   { echo -e "\033[31m[ZEC ✗]\033[0m $*"; }

remote() { $SSH_CMD "$@"; }

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_setup() {
    log_info "=== Zcash Testnet Setup on LP2 ($OP2_IP) ==="

    # Step 1: Download & extract
    log_info "Step 1/7: Downloading Zcash v${ZCASH_VERSION}..."
    remote "
        if [ -x $ZCASHD ]; then
            echo 'Zcash binary already exists, skipping download'
        else
            mkdir -p $ZCASH_DIR
            cd /tmp
            # Try bookworm first, then bullseye
            if [ ! -f zcash-${ZCASH_VERSION}-linux64.tar.gz ]; then
                wget -q --show-progress '$ZCASH_URL' -O zcash-${ZCASH_VERSION}-linux64.tar.gz 2>/dev/null || \
                wget -q --show-progress 'https://download.z.cash/downloads/zcash-${ZCASH_VERSION}-linux64-debian-bullseye.tar.gz' -O zcash-${ZCASH_VERSION}-linux64.tar.gz
            fi
            tar xzf zcash-${ZCASH_VERSION}-linux64.tar.gz
            mkdir -p $ZCASH_BIN
            # Zcash extracts to zcash-VERSION/bin/
            cp zcash-${ZCASH_VERSION}-linux64/bin/zcashd $ZCASH_BIN/ 2>/dev/null || \
            cp zcash-${ZCASH_VERSION}*/bin/zcashd $ZCASH_BIN/
            cp zcash-${ZCASH_VERSION}-linux64/bin/zcash-cli $ZCASH_BIN/ 2>/dev/null || \
            cp zcash-${ZCASH_VERSION}*/bin/zcash-cli $ZCASH_BIN/
            # Also copy zcash-fetch-params if available
            cp zcash-${ZCASH_VERSION}*/bin/zcash-fetch-params $ZCASH_BIN/ 2>/dev/null || true
            chmod +x $ZCASH_BIN/*
            rm -rf zcash-${ZCASH_VERSION}*
            echo 'Zcash binaries installed'
        fi
    "
    log_ok "Binaries ready"

    # Step 2: Fetch Sapling params (needed for zcashd)
    log_info "Step 2/7: Fetching Sapling parameters (may take a few minutes)..."
    remote "
        if [ -f ~/.zcash-params/sapling-spend.params ]; then
            echo 'Sapling params already present'
        else
            if [ -x $ZCASH_BIN/zcash-fetch-params ]; then
                $ZCASH_BIN/zcash-fetch-params
            else
                # Manual download of required params
                mkdir -p ~/.zcash-params
                cd ~/.zcash-params
                wget -q --show-progress https://download.z.cash/downloads/sapling-spend.params -O sapling-spend.params || true
                wget -q --show-progress https://download.z.cash/downloads/sapling-output.params -O sapling-output.params || true
                wget -q --show-progress https://download.z.cash/downloads/sprout-groth16.params -O sprout-groth16.params || true
                echo 'Params downloaded'
            fi
        fi
    "
    log_ok "Params ready"

    # Step 3: Configure
    log_info "Step 3/7: Configuring zcash.conf..."
    local rpc_pass
    rpc_pass=$(openssl rand -hex 16)

    remote "
        mkdir -p $ZCASH_DATADIR
        cat > $ZCASH_CONF << 'CONF'
# Zcash Testnet Configuration (LP2)
testnet=1
server=1
txindex=1
listen=1
daemon=1

# Deprecation acknowledgement (required for zcashd v6.x)
i-am-aware-zcashd-will-be-replaced-by-zebrad-and-zallet-in-2025=1

# Allow deprecated RPCs needed for HTLC transparent addresses
allowdeprecated=getnewaddress
allowdeprecated=z_getnewaddress

# RPC
rpcuser=zcash_lp_rpc
rpcpassword=${rpc_pass}
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcport=18232

# Performance
maxconnections=32
dbcache=256
CONF
        chmod 600 $ZCASH_CONF
    "
    log_ok "Config written"

    # Step 4: Start daemon
    log_info "Step 4/7: Starting zcashd testnet..."
    remote "
        pkill -x zcashd 2>/dev/null || true
        sleep 2
        rm -f $ZCASH_DATADIR/testnet3/.lock 2>/dev/null
        $ZCASHD -daemon 2>&1
        sleep 5
        if pgrep -x zcashd > /dev/null; then
            echo 'zcashd started successfully'
        else
            echo 'ERROR: zcashd failed to start'
            exit 1
        fi
    "
    log_ok "Daemon started"

    # Step 5: Wait for RPC
    log_info "Step 5/7: Waiting for RPC..."
    local retries=0
    while [ $retries -lt 30 ]; do
        if remote "$ZCASH_CLI -testnet getblockchaininfo" &>/dev/null; then
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

    # Step 6: Generate address
    log_info "Step 6/7: Generating LP address..."
    local lp_address
    lp_address=$(remote "$ZCASH_CLI -testnet getnewaddress" 2>/dev/null || echo "")
    if [ -z "$lp_address" ]; then
        log_warn "Could not generate address yet. Use: ./setup_zcash_lp2.sh address"
    else
        log_ok "LP Address: $lp_address"
    fi

    # Step 7: Save credentials
    log_info "Step 7/7: Saving credentials..."
    remote "
        mkdir -p $KEY_DIR
        chmod 700 $KEY_DIR
        cat > $KEY_FILE << KEYEOF
{
    \"name\": \"lp_zcash\",
    \"role\": \"liquidity_provider\",
    \"network\": \"testnet\",
    \"address\": \"${lp_address:-pending}\",
    \"wallet\": \"default\",
    \"rpc_user\": \"zcash_lp_rpc\",
    \"rpc_password\": \"${rpc_pass}\",
    \"rpc_port\": 18232
}
KEYEOF
        chmod 600 $KEY_FILE
    "
    log_ok "Credentials saved"

    echo ""
    log_info "=== Setup Complete ==="
    log_info "Address: ${lp_address:-pending}"
    log_info "Faucet: https://faucet.zecpages.com/"
    log_info "Explorer: https://explorer.testnet.z.cash/"
}

cmd_status() {
    log_info "=== Zcash Status on LP2 ($OP2_IP) ==="
    if ! remote "test -x $ZCASHD" 2>/dev/null; then
        log_err "Binary not found"; return 1
    fi
    log_ok "Binary: $ZCASHD"

    if ! remote "pgrep -x zcashd" &>/dev/null; then
        log_err "Daemon: NOT running"; return 1
    fi
    log_ok "Daemon: running"

    local info
    info=$(remote "$ZCASH_CLI -testnet getblockchaininfo" 2>/dev/null || echo "{}")
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
    balance=$(remote "$ZCASH_CLI -testnet getbalance" 2>/dev/null || echo "?")
    peers=$(remote "$ZCASH_CLI -testnet getconnectioncount" 2>/dev/null || echo "?")
    address=$(remote "cat $KEY_FILE 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('address','?'))\"" 2>/dev/null || echo "?")
    log_info "Balance:  $balance ZEC"
    log_info "Address:  $address"
    log_info "Peers:    $peers"
}

cmd_start() {
    log_info "Starting Zcash daemon on LP2..."
    remote "
        if pgrep -x zcashd > /dev/null; then echo 'Already running'
        else
            rm -f $ZCASH_DATADIR/testnet3/.lock 2>/dev/null
            $ZCASHD -daemon 2>&1
            sleep 5
            pgrep -x zcashd > /dev/null && echo 'Started' || { echo 'Failed'; exit 1; }
        fi
    "
    log_ok "Done"
}

cmd_stop() {
    log_info "Stopping Zcash daemon on LP2..."
    remote "$ZCASH_CLI -testnet stop 2>/dev/null || pkill -x zcashd 2>/dev/null || true"
    sleep 2
    log_ok "Stopped"
}

cmd_fix_deprecated() {
    log_info "Adding allowdeprecated=getnewaddress to zcash.conf..."
    remote "
        if grep -q 'allowdeprecated=getnewaddress' $ZCASH_CONF 2>/dev/null; then
            echo 'Already present'
        else
            echo '' >> $ZCASH_CONF
            echo '# Allow deprecated RPCs needed for HTLC transparent addresses' >> $ZCASH_CONF
            echo 'allowdeprecated=getnewaddress' >> $ZCASH_CONF
            echo 'allowdeprecated=z_getnewaddress' >> $ZCASH_CONF
            echo 'Added allowdeprecated lines'
        fi
        cat $ZCASH_CONF
    "
    log_ok "Config updated"

    log_info "Acknowledging wallet backup (zcashd-wallet-tool)..."
    remote "
        WALLET_TOOL=$ZCASH_BIN/zcashd-wallet-tool
        if [ -x \$WALLET_TOOL ]; then
            echo 'yes' | \$WALLET_TOOL -datadir=$ZCASH_DATADIR seed-phrase-backup 2>&1 || true
        else
            # Try to find zcashd-wallet-tool or skip
            echo 'zcashd-wallet-tool not found, trying RPC...'
            # Alternative: create a marker file that zcashd checks
            touch $ZCASH_DATADIR/.seed_phrase_backed_up 2>/dev/null || true
        fi
    "

    log_info "Restarting zcashd..."
    remote "$ZCASH_CLI -testnet stop 2>/dev/null || pkill -x zcashd 2>/dev/null || true"
    sleep 3
    remote "
        rm -f $ZCASH_DATADIR/testnet3/.lock 2>/dev/null
        $ZCASHD -daemon 2>&1
        sleep 5
        pgrep -x zcashd > /dev/null && echo 'Restarted OK' || echo 'FAILED to restart'
    "
    log_ok "Done"
}

cmd_fix_wallet() {
    log_info "Fixing Zcash wallet — downloading wallet-tool + acknowledging backup..."
    remote "
        WALLET_TOOL=$ZCASH_BIN/zcashd-wallet-tool

        # Download wallet-tool if missing
        if [ ! -x \$WALLET_TOOL ]; then
            echo 'Downloading zcashd-wallet-tool from release tarball...'
            cd /tmp
            if [ ! -f zcash-${ZCASH_VERSION}-linux64.tar.gz ]; then
                wget -q --show-progress '$ZCASH_URL' -O zcash-${ZCASH_VERSION}-linux64.tar.gz 2>/dev/null || \
                wget -q --show-progress 'https://download.z.cash/downloads/zcash-${ZCASH_VERSION}-linux64-debian-bullseye.tar.gz' -O zcash-${ZCASH_VERSION}-linux64.tar.gz
            fi
            tar xzf zcash-${ZCASH_VERSION}-linux64.tar.gz 2>/dev/null || true
            # Copy wallet tool + any other missing binaries
            for bin in zcashd-wallet-tool zcash-tx; do
                SRC=\$(find /tmp/zcash-${ZCASH_VERSION}* -name \"\$bin\" -type f 2>/dev/null | head -1)
                if [ -n \"\$SRC\" ] && [ -f \"\$SRC\" ]; then
                    cp \"\$SRC\" $ZCASH_BIN/
                    chmod +x $ZCASH_BIN/\$bin
                    echo \"Installed \$bin\"
                fi
            done
            rm -rf /tmp/zcash-${ZCASH_VERSION}*
        fi

        if [ -x \$WALLET_TOOL ]; then
            echo '=== Acknowledging wallet backup ==='
            # 1. Stop current daemon
            $ZCASH_CLI -testnet stop 2>/dev/null || true
            sleep 3
            pkill -x zcashd 2>/dev/null || true
            sleep 2

            # 2. Restart with -exportdir (required by wallet-tool)
            rm -f $ZCASH_DATADIR/testnet3/.lock 2>/dev/null
            $ZCASHD -daemon -exportdir=/tmp 2>&1

            # Wait for RPC to be ready
            echo 'Waiting for zcashd RPC...'
            for i in \$(seq 1 60); do
                if $ZCASH_CLI -testnet getblockchaininfo > /dev/null 2>&1; then
                    echo \"RPC ready after \${i}s\"
                    break
                fi
                sleep 2
            done

            # 3. Create automation script on remote and run it
            echo 'Creating wallet-tool automation script...'
            rm -f /tmp/export* /tmp/y /tmp/backup* /tmp/zcash_lp_backup* 2>/dev/null

            cat > /tmp/zcash_wallet_fix.py << 'PYEOF'
#!/usr/bin/env python3
import os, re, time, pty, select, sys

tool = '/home/ubuntu/zcash/bin/zcashd-wallet-tool'
args = [tool, '-testnet']

master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    os.setsid()
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(slave)
    os.execvp(args[0], args)

os.close(slave)
full = ''
phrase = {}

def read(timeout=15):
    global full
    buf = b''
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([master], [], [], 1)
        if r:
            try:
                d = os.read(master, 8192)
                if d: buf += d
            except: break
    t = buf.decode('utf-8', errors='replace')
    full += t
    return t

def send(s):
    os.write(master, (s + '\n').encode())
    time.sleep(1)

# Phase 1: filename
out = read(20)
sys.stdout.write(f'[1] Got: ...{out[-100:]}\n')
sys.stdout.flush()
send('zcashlpbk')

# Phase 2: phrase
out = read(15)
sys.stdout.write(f'[2] Got: ...{out[-100:]}\n')
sys.stdout.flush()

for m in re.finditer(r'(\d+):\s+([a-z]+)', full):
    phrase[int(m.group(1))] = m.group(2)
sys.stdout.write(f'[2] Words: {phrase}\n')
sys.stdout.flush()

if not phrase:
    sys.stdout.write('[!] No phrase found, aborting\n')
    os.kill(pid, 9)
    os.close(master)
    sys.exit(1)

# Press Enter
send('')

# Phase 3: quiz
for i in range(8):
    out = read(8)
    sys.stdout.write(f'[3.{i}] Got: {out.strip()[-120:]}\n')
    sys.stdout.flush()
    m = re.search(r'enter the (\d+)', out, re.I)
    if m:
        n = int(m.group(1))
        w = phrase.get(n, '')
        sys.stdout.write(f'[3.{i}] -> word {n} = {w}\n')
        sys.stdout.flush()
        send(w)
    elif 'confirmed' in out.lower() or 'success' in out.lower() or 'backed' in out.lower():
        sys.stdout.write('[OK] Backup confirmed!\n')
        break
    else:
        r, _, _ = select.select([master], [], [], 2)
        if not r:
            # Check if process exited
            p, status = os.waitpid(pid, os.WNOHANG)
            if p != 0:
                sys.stdout.write(f'[!] Process exited with status {status}\n')
                break

try: os.kill(pid, 9)
except: pass
os.close(master)
os.waitpid(pid, 0)
sys.stdout.write('[DONE]\n')
PYEOF
            chmod +x /tmp/zcash_wallet_fix.py
            python3 /tmp/zcash_wallet_fix.py

            # 4. Stop and restart without -exportdir
            $ZCASH_CLI -testnet stop 2>/dev/null || true
            sleep 3
            pkill -x zcashd 2>/dev/null || true
            sleep 2
            rm -f $ZCASH_DATADIR/testnet3/.lock 2>/dev/null
            $ZCASHD -daemon 2>&1
            sleep 5
            pgrep -x zcashd > /dev/null && echo 'Daemon restarted OK' || echo 'FAILED to restart'
        else
            echo 'ERROR: Could not find zcashd-wallet-tool'
        fi
    "
}

cmd_address() {
    local address
    address=$(remote "cat $KEY_FILE 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('address',''))\"" 2>/dev/null || echo "")
    if [ -z "$address" ] || [ "$address" = "pending" ]; then
        log_info "Generating new address..."
        local addr_output
        addr_output=$(remote "timeout 30 $ZCASH_CLI -testnet getnewaddress 2>&1" 2>&1)
        log_info "Output: $addr_output"
        address=$(echo "$addr_output" | grep -v error | grep -v Error | grep -v Traceback | grep -v File | grep -v timeout | grep -E '^t' | head -1)
        if [ -n "$address" ]; then
            remote "
                mkdir -p $KEY_DIR && chmod 700 $KEY_DIR
                python3 -c \"
import json, os
path = '$KEY_FILE'
try:
    with open(path) as f: d = json.load(f)
except: d = {'name':'lp_zcash','role':'liquidity_provider','network':'testnet','wallet':'default','rpc_port':18232}
d['address'] = '$address'
with open(path, 'w') as f: json.dump(d, f, indent=4)
os.chmod(path, 0o600)
\"
            "
            log_ok "Address saved"
        else
            log_err "Could not generate address"; return 1
        fi
    fi
    echo ""
    log_info "Zcash LP Address: $address"
    log_info "Faucet: https://faucet.zecpages.com/"
}

cmd_logs() {
    log_info "=== Zcash Debug Logs ==="
    remote "
        for d in ~/.zcash/testnet3 ~/.zcash; do
            if [ -f \"\$d/debug.log\" ]; then
                echo \"--- \$d/debug.log (last 30) ---\"
                tail -30 \"\$d/debug.log\"
                break
            fi
        done
        echo ''
        echo '--- Port 18232 check ---'
        ss -tlnp 2>/dev/null | grep 18232 || echo 'Port 18232 not in use'
        echo '--- zcashd processes ---'
        ps aux | grep zcashd 2>/dev/null | grep -v grep || echo 'No zcashd processes'
    "
}

cmd_keycheck() {
    log_info "=== Zcash Key File on LP2 ==="
    remote "
        echo '--- zcash.json ---'
        cat ~/.BathronKey/zcash.json 2>/dev/null || echo '(file not found)'
        echo ''
        python3 -c \"
import json, os
key_path = '$KEY_FILE'
conf_path = '$ZCASH_CONF'
key_dir = '$KEY_DIR'
os.makedirs(key_dir, mode=0o700, exist_ok=True)

# Load or create
try:
    with open(key_path) as f: d = json.load(f)
except:
    d = {'name':'lp_zcash','role':'liquidity_provider','network':'testnet','address':'pending','wallet':'default','rpc_port':18232}

# Read RPC credentials from zcash.conf
if 'rpc_user' not in d or 'rpc_password' not in d:
    rpc_user = rpc_pass = ''
    try:
        with open(conf_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith('rpcuser='): rpc_user = line.split('=',1)[1]
                elif line.startswith('rpcpassword='): rpc_pass = line.split('=',1)[1]
    except: pass
    if rpc_user and rpc_pass:
        d['rpc_user'] = rpc_user
        d['rpc_password'] = rpc_pass

with open(key_path, 'w') as f: json.dump(d, f, indent=4)
os.chmod(key_path, 0o600)
print('Key file OK')
\"
        echo '--- updated ---'
        cat $KEY_FILE 2>/dev/null || echo '(error)'
    "
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
    setup)          cmd_setup ;;
    status)         cmd_status ;;
    start)          cmd_start ;;
    stop)           cmd_stop ;;
    address)        cmd_address ;;
    logs)           cmd_logs ;;
    keycheck)       cmd_keycheck ;;
    fix-deprecated) cmd_fix_deprecated ;;
    fix-wallet)     cmd_fix_wallet ;;
    rpc)            shift; remote "$ZCASH_CLI -testnet $*" ;;
    *) echo "Usage: $0 {setup|status|start|stop|address|logs|keycheck|fix-deprecated|fix-wallet|rpc <cmd>}"; exit 1 ;;
esac
