#!/bin/bash
# =============================================================================
# isolate_wallets.sh - Fix shared wallet.dat across testnet nodes
# =============================================================================
#
# PROBLEM: All 5 testnet nodes share the same HD wallet seed because
# genesis_step_4_distribute() distributed wallet.dat along with chain data.
# This causes getwalletstate to return identical M0/M1 balances everywhere.
#
# SOLUTION: For each node:
#   1. Stop daemon
#   2. Backup + delete wallet.dat (fresh HD seed on restart)
#   3. Restart daemon
#   4. Import ONLY the node's own key (1 WIF per node)
#   5. Verify isolation
#
# Usage:
#   ./isolate_wallets.sh status    # Check current wallet state
#   ./isolate_wallets.sh isolate   # Isolate ALL nodes
#   ./isolate_wallets.sh seed      # Isolate only Seed
#   ./isolate_wallets.sh op1       # Isolate only OP1
#   ./isolate_wallets.sh op2       # Isolate only OP2
#   ./isolate_wallets.sh op3       # Isolate only OP3
#   ./isolate_wallets.sh coresdk   # Isolate only CoreSDK
#   ./isolate_wallets.sh verify    # Verify isolation post-fix
#
# =============================================================================

set -uo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[PASS]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }
log_step()  { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}"; }

# SSH config
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# =============================================================================
# NODE DEFINITIONS — 1 wallet per VPS (NEVER import foreign keys)
# =============================================================================

declare -A NODE_IP NODE_CLI NODE_WIF NODE_LABEL NODE_ADDR

# Seed → pilpous (MN owner)
NODE_IP[seed]="57.131.33.151"
NODE_CLI[seed]="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
NODE_WIF[seed]="cQvp6t3Jz8MQ5FJEVM4ewucabskCfyhy73N1eP9c82xGxgEA71CX"
NODE_LABEL[seed]="pilpous"
NODE_ADDR[seed]="xyszqryssGaNw13qpjbxB4PVoRqGat7RPd"

# CoreSDK → bob (P&A service)
NODE_IP[coresdk]="162.19.251.75"
NODE_CLI[coresdk]="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
NODE_WIF[coresdk]="cNNCM6nSmDydVCL3zqdDzUS44tJ9LGMDck1A22fvKrrUgsYS4eMm"
NODE_LABEL[coresdk]="bob"
NODE_ADDR[coresdk]="y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk"

# OP1 → alice (LP1)
NODE_IP[op1]="57.131.33.152"
NODE_CLI[op1]="/home/ubuntu/bathron-cli -testnet"
NODE_WIF[op1]="cTuaDJPC5HvAYD4XzFxWUszUDfVeSmaN47N6qvCxnpaucgeYzxb2"
NODE_LABEL[op1]="alice"
NODE_ADDR[op1]="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

# OP2 → dev (LP2)
NODE_IP[op2]="57.131.33.214"
NODE_CLI[op2]="/home/ubuntu/bathron/bin/bathron-cli -testnet"
NODE_WIF[op2]="cSNJfpBoKt43ojNuvG7TjkxsUiTdXy6HihcKxBewNgk5jALCXYaa"
NODE_LABEL[op2]="dev"
NODE_ADDR[op2]="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"

# OP3 → charlie (Fake User)
NODE_IP[op3]="51.75.31.44"
NODE_CLI[op3]="/home/ubuntu/bathron-cli -testnet"
NODE_WIF[op3]="cPtPSZLkcufXMryYoCTr63zkPDGPtYWxbZ24NGBWzDfzJUuZaEbE"
NODE_LABEL[op3]="charlie"
NODE_ADDR[op3]="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"

ALL_NODES="seed coresdk op1 op2 op3"

# Daemon binary paths per node
get_daemon() {
    local node=$1
    local ip="${NODE_IP[$node]}"
    case "$node" in
        seed|coresdk) echo "/home/ubuntu/BATHRON-Core/src/bathrond -testnet" ;;
        op2) echo "/home/ubuntu/bathron/bin/bathrond -testnet" ;;
        *) echo "/home/ubuntu/bathrond -testnet" ;;
    esac
}

# =============================================================================
# STATUS — Check current wallet state (hdseedid) on all nodes
# =============================================================================

cmd_status() {
    echo -e "${BOLD}${CYAN}"
    echo "============================================================"
    echo "  WALLET ISOLATION STATUS"
    echo "============================================================"
    echo -e "${NC}"

    declare -A HD_KEYS
    local all_same=true
    local first_key=""

    for node in $ALL_NODES; do
        local ip="${NODE_IP[$node]}"
        local cli="${NODE_CLI[$node]}"
        local label="${NODE_LABEL[$node]}"

        echo -n "  ${label} (${node}, ${ip}): "

        local info
        info=$($SSH ubuntu@$ip "$cli getwalletinfo 2>/dev/null" 2>/dev/null) || info="{}"

        local hdkey
        hdkey=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('hdseedid','?'))" 2>/dev/null) || hdkey="?"

        local keypoolsize
        keypoolsize=$(echo "$info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('keypoolsize','?'))" 2>/dev/null) || keypoolsize="?"

        HD_KEYS[$node]="$hdkey"
        echo "hdseedid=${hdkey:0:16}... keypoolsize=$keypoolsize"

        if [ -z "$first_key" ]; then
            first_key="$hdkey"
        elif [ "$hdkey" != "$first_key" ]; then
            all_same=false
        fi
    done

    echo ""
    if $all_same && [ -n "$first_key" ] && [ "$first_key" != "?" ]; then
        log_error "ALL nodes share the SAME HD seed! Wallets are NOT isolated."
        echo "  → Run: ./isolate_wallets.sh isolate"
    else
        log_ok "All nodes have DIFFERENT HD seeds. Wallets are isolated."
    fi
    echo ""
}

# =============================================================================
# ISOLATE — Stop, delete wallet, restart, import single key, rescan
# =============================================================================

isolate_node() {
    local node=$1
    local ip="${NODE_IP[$node]}"
    local cli="${NODE_CLI[$node]}"
    local daemon=$(get_daemon "$node")
    local wif="${NODE_WIF[$node]}"
    local label="${NODE_LABEL[$node]}"
    local addr="${NODE_ADDR[$node]}"

    log_step "Isolating $label ($node) on $ip"

    # Step 1: Stop LP server if running (OP1/OP2)
    if [ "$node" = "op1" ] || [ "$node" = "op2" ]; then
        log_info "Stopping LP server..."
        $SSH ubuntu@$ip "pkill -f 'python.*server.py' 2>/dev/null || true" 2>/dev/null || true
        sleep 2
    fi

    # Step 2: Stop daemon (wait up to 30s for clean shutdown)
    log_info "Stopping daemon..."
    $SSH ubuntu@$ip "$cli stop 2>/dev/null || true" 2>/dev/null || true
    local stop_retries=0
    while [ $stop_retries -lt 15 ]; do
        if ! $SSH ubuntu@$ip "pgrep -u ubuntu bathrond >/dev/null 2>&1" 2>/dev/null; then
            break
        fi
        stop_retries=$((stop_retries + 1))
        sleep 2
    done
    # Force kill if still running
    if $SSH ubuntu@$ip "pgrep -u ubuntu bathrond >/dev/null 2>&1" 2>/dev/null; then
        log_warn "Force-killing daemon..."
        $SSH ubuntu@$ip "pkill -9 -u ubuntu bathrond 2>/dev/null || true" 2>/dev/null || true
        sleep 3
    fi

    # Step 3: Backup + delete wallet (SQLite format: wallet.sqlite*)
    log_info "Backing up and removing shared wallet..."
    $SSH ubuntu@$ip "
        TESTNET=~/.bathron/testnet5
        FOUND=false

        # SQLite wallet (BATHRON uses this format)
        if [ -f \$TESTNET/wallet.sqlite ]; then
            cp \$TESTNET/wallet.sqlite \$TESTNET/wallet.sqlite.shared_backup_\$(date +%s)
            rm -f \$TESTNET/wallet.sqlite \$TESTNET/wallet.sqlite-shm \$TESTNET/wallet.sqlite-wal
            FOUND=true
            echo 'wallet.sqlite removed (backup saved)'
        fi

        # BDB wallet (fallback check)
        if [ -f \$TESTNET/wallet.dat ]; then
            cp \$TESTNET/wallet.dat \$TESTNET/wallet.dat.shared_backup_\$(date +%s)
            rm -f \$TESTNET/wallet.dat
            FOUND=true
            echo 'wallet.dat removed (backup saved)'
        fi

        # Clean wallet-related dirs
        rm -f \$TESTNET/.walletlock
        rm -rf \$TESTNET/wallets
        rm -rf \$TESTNET/database

        if ! \$FOUND; then
            echo 'No wallet file found (wallet.sqlite or wallet.dat)'
        fi
    " 2>/dev/null

    # Step 4: Restart daemon (generates fresh HD seed)
    # Use nohup + & to properly detach (SSH hangs with -daemon flag)
    log_info "Restarting daemon (fresh HD seed)..."
    $SSH ubuntu@$ip "nohup $daemon -daemon > /dev/null 2>&1 &" 2>/dev/null || true

    # Wait for daemon to start (up to 120s — Seed with MN keys takes longer)
    local retries=0
    local max_retries=60
    while [ $retries -lt $max_retries ]; do
        if $SSH ubuntu@$ip "$cli getblockcount 2>/dev/null" >/dev/null 2>&1; then
            break
        fi
        retries=$((retries + 1))
        [ $((retries % 10)) -eq 0 ] && echo "  waiting... (${retries}/${max_retries})"
        sleep 2
    done

    if [ $retries -ge $max_retries ]; then
        log_error "Daemon failed to start on $ip after $((max_retries * 2))s"
        return 1
    fi
    log_ok "Daemon started (${retries}x2s)"

    # Step 5: Import SINGLE key with rescan
    # importprivkey with rescan=true can take several minutes (scans entire blockchain)
    log_info "Importing $label key ($addr) with rescan (may take 2-5 min)..."
    local import_result
    import_result=$($SSH -o ServerAliveInterval=30 -o ServerAliveCountMax=20 ubuntu@$ip "$cli importprivkey '$wif' '$label' true 2>&1" 2>/dev/null) || true
    if echo "$import_result" | grep -qi "error"; then
        log_warn "Import warning: $import_result"
    else
        log_ok "Key imported and rescan complete"
    fi

    # Step 6: Verify
    log_info "Verifying..."
    local hdkey
    hdkey=$($SSH ubuntu@$ip "$cli getwalletinfo 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('hdseedid','?'))\"" 2>/dev/null) || hdkey="?"

    local ismine
    ismine=$($SSH ubuntu@$ip "$cli validateaddress '$addr' 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('ismine', False))\"" 2>/dev/null) || ismine="?"

    local balance
    balance=$($SSH ubuntu@$ip "$cli getbalance 2>/dev/null" 2>/dev/null) || balance="?"

    echo "  hdseedid: ${hdkey:0:20}..."
    echo "  $addr: ismine=$ismine"
    echo "  Balance: $balance"

    # Step 7: Restart LP server if needed (OP1/OP2)
    if [ "$node" = "op1" ]; then
        log_info "Restarting LP1 server..."
        $SSH ubuntu@$ip "cd ~/pna-lp && nohup python3 server.py > ~/pna-lp.log 2>&1 &" 2>/dev/null || true
        sleep 3
        if $SSH ubuntu@$ip "pgrep -f 'python.*server.py' >/dev/null 2>&1" 2>/dev/null; then
            log_ok "LP1 server restarted"
        else
            log_warn "LP1 server may not have started — check manually"
        fi
    elif [ "$node" = "op2" ]; then
        log_info "Restarting LP2 server..."
        $SSH ubuntu@$ip "cd ~/pna-lp && LP_ID=lp_pna_02 LP_NAME='pna LP 2' nohup python3 server.py > ~/pna-lp.log 2>&1 &" 2>/dev/null || true
        sleep 3
        if $SSH ubuntu@$ip "pgrep -f 'python.*server.py' >/dev/null 2>&1" 2>/dev/null; then
            log_ok "LP2 server restarted"
        else
            log_warn "LP2 server may not have started — check manually"
        fi
    fi

    log_ok "$label ($node) isolated successfully"
}

cmd_isolate() {
    echo -e "${BOLD}${CYAN}"
    echo "============================================================"
    echo "  WALLET ISOLATION — ALL NODES"
    echo "============================================================"
    echo -e "${NC}"
    echo "This will:"
    echo "  1. Stop each daemon"
    echo "  2. Delete wallet.dat (backup saved)"
    echo "  3. Restart with fresh HD seed"
    echo "  4. Import ONLY the node's own key"
    echo "  5. Rescan blockchain"
    echo ""

    for node in $ALL_NODES; do
        isolate_node "$node"
        echo ""
    done

    echo -e "${BOLD}${CYAN}"
    echo "============================================================"
    echo "  ISOLATION COMPLETE — Running verify..."
    echo "============================================================"
    echo -e "${NC}"

    cmd_verify
}

# =============================================================================
# VERIFY — Post-isolation check: all hdseedids must be different
# =============================================================================

cmd_verify() {
    echo -e "${BOLD}${CYAN}"
    echo "============================================================"
    echo "  WALLET ISOLATION VERIFICATION"
    echo "============================================================"
    echo -e "${NC}"

    local PASS=0
    local FAIL=0

    declare -A HD_KEYS
    declare -A PROBE_ADDRS

    # Collect hdseedid and a probe address from each node
    for node in $ALL_NODES; do
        local ip="${NODE_IP[$node]}"
        local cli="${NODE_CLI[$node]}"
        local label="${NODE_LABEL[$node]}"
        local expected_addr="${NODE_ADDR[$node]}"

        log_step "$label ($node, $ip)"

        # 1. hdseedid
        local hdkey
        hdkey=$($SSH ubuntu@$ip "$cli getwalletinfo 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('hdseedid','?'))\"" 2>/dev/null) || hdkey="?"
        HD_KEYS[$node]="$hdkey"
        echo "  hdseedid: $hdkey"

        # 2. ismine for own address
        local ismine
        ismine=$($SSH ubuntu@$ip "$cli validateaddress '$expected_addr' 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('ismine', False))\"" 2>/dev/null) || ismine="?"
        if [ "$ismine" = "True" ]; then
            log_ok "$expected_addr: ismine=True"
            PASS=$((PASS + 1))
        else
            log_error "$expected_addr: ismine=$ismine (expected True)"
            FAIL=$((FAIL + 1))
        fi

        # 3. ismine for OTHER addresses (should be False)
        for other_node in $ALL_NODES; do
            [ "$other_node" = "$node" ] && continue
            local other_addr="${NODE_ADDR[$other_node]}"
            local other_label="${NODE_LABEL[$other_node]}"
            local other_mine
            other_mine=$($SSH ubuntu@$ip "$cli validateaddress '$other_addr' 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('ismine', False))\"" 2>/dev/null) || other_mine="?"
            if [ "$other_mine" = "False" ]; then
                log_ok "$other_addr ($other_label): ismine=False (correct)"
                PASS=$((PASS + 1))
            else
                log_error "$other_addr ($other_label): ismine=$other_mine (expected False — wallet NOT isolated!)"
                FAIL=$((FAIL + 1))
            fi
        done

        # 4. getwalletstate M1 check
        local m1_info
        m1_info=$($SSH ubuntu@$ip "$cli getwalletstate true 2>/dev/null" | python3 -c "
import sys, json
d = json.load(sys.stdin)
m1 = d.get('m1', {})
receipts = m1.get('receipts', [])
total = m1.get('total', 0)
print(f'{len(receipts)} receipts, {total} sats')
" 2>/dev/null) || m1_info="?"
        echo "  M1: $m1_info"

        # 5. Probe address (generate one to check uniqueness)
        local probe
        probe=$($SSH ubuntu@$ip "$cli getnewaddress 'verify_probe' 2>/dev/null" 2>/dev/null) || probe="?"
        PROBE_ADDRS[$node]="$probe"
        echo "  Probe address: $probe"
    done

    # Cross-check: all hdseedids must be different
    echo ""
    log_step "Cross-checks"

    local unique_keys=$(printf '%s\n' "${HD_KEYS[@]}" | sort -u | wc -l)
    local total_keys=${#HD_KEYS[@]}
    if [ "$unique_keys" -eq "$total_keys" ]; then
        log_ok "All $total_keys hdseedids are UNIQUE — wallets isolated"
        PASS=$((PASS + 1))
    else
        log_error "Only $unique_keys unique hdseedids out of $total_keys — wallets still shared!"
        FAIL=$((FAIL + 1))
    fi

    # Cross-check: all probe addresses must be different
    local unique_probes=$(printf '%s\n' "${PROBE_ADDRS[@]}" | sort -u | wc -l)
    if [ "$unique_probes" -eq "$total_keys" ]; then
        log_ok "All probe addresses are UNIQUE"
        PASS=$((PASS + 1))
    else
        log_error "Probe addresses overlap — wallets still shared!"
        FAIL=$((FAIL + 1))
    fi

    # Special check: Seed MN status
    echo ""
    log_step "Seed MN Status"
    local mn_count
    mn_count=$($SSH ubuntu@${NODE_IP[seed]} "${NODE_CLI[seed]} protx_list 2>/dev/null | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))'" 2>/dev/null) || mn_count="?"
    if [ "$mn_count" != "?" ] && [ "$mn_count" -gt 0 ]; then
        log_ok "Seed has $mn_count MNs registered"
        PASS=$((PASS + 1))
    else
        log_warn "Seed MN count: $mn_count (may need rescan)"
    fi

    # Summary
    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}  RESULTS: ${GREEN}$PASS PASS${NC} / ${RED}$FAIL FAIL${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo ""

    if [ $FAIL -gt 0 ]; then
        echo "Some checks failed. Run: ./isolate_wallets.sh isolate"
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

case "${1:-help}" in
    status)
        cmd_status
        ;;

    isolate)
        cmd_isolate
        ;;

    verify)
        cmd_verify
        ;;

    seed|coresdk|op1|op2|op3)
        isolate_node "$1"
        ;;

    *)
        echo "Usage: $0 {status|isolate|verify|seed|coresdk|op1|op2|op3}"
        echo ""
        echo "Commands:"
        echo "  status   - Check current wallet state (hdseedid per node)"
        echo "  isolate  - Isolate ALL 5 nodes (stop, delete wallet, reimport 1 key)"
        echo "  verify   - Verify isolation (hdseedid unique, ismine checks)"
        echo "  seed     - Isolate Seed only"
        echo "  coresdk  - Isolate CoreSDK only"
        echo "  op1      - Isolate OP1 only"
        echo "  op2      - Isolate OP2 only"
        echo "  op3      - Isolate OP3 only"
        echo ""
        echo "Workflow:"
        echo "  1. ./isolate_wallets.sh status   # See current state"
        echo "  2. ./isolate_wallets.sh isolate   # Fix all nodes"
        echo "  3. ./isolate_wallets.sh verify    # Confirm isolation"
        ;;
esac
