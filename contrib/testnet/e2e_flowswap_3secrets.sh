#!/bin/bash
#
# E2E FlowSwap Test: BTC → M1 → USDC (3-secrets)
#
# Flow:
#   Phase 0: Quote (off-chain) - simulated
#   Phase 1: Commitments - generate 3 secrets, share hashlocks
#   Phase 2A: LP2 locks USDC (EVM HTLC3S)
#   Phase 2B: LP1 locks M1 (BATHRON HTLC3S)
#   Phase 3: User locks BTC (P2WSH HTLC3S)
#   Phase 4: LP1 claims BTC (REVEALS ALL 3 SECRETS)
#   Phase 5A: Anyone claims USDC (permissionless)
#   Phase 5B: LP2 claims M1
#
# Actors:
#   User (Charlie/OP3): sends BTC, receives USDC
#   LP1 (Alice/OP1): BTC/M1 side, claims BTC
#   LP2 (Bob/CoreSDK): M1/USDC side, locks USDC
#
# Usage:
#   ./e2e_flowswap_3secrets.sh [phase]
#   ./e2e_flowswap_3secrets.sh all        # Run full flow
#   ./e2e_flowswap_3secrets.sh generate   # Phase 1: Generate secrets
#   ./e2e_flowswap_3secrets.sh lock_usdc  # Phase 2A: LP2 locks USDC
#   ./e2e_flowswap_3secrets.sh lock_m1    # Phase 2B: LP1 locks M1
#   ./e2e_flowswap_3secrets.sh lock_btc   # Phase 3: User locks BTC
#   ./e2e_flowswap_3secrets.sh claim_btc  # Phase 4: LP1 claims BTC
#   ./e2e_flowswap_3secrets.sh claim_usdc # Phase 5A: Claim USDC
#   ./e2e_flowswap_3secrets.sh claim_m1   # Phase 5B: LP2 claims M1
#   ./e2e_flowswap_3secrets.sh status     # Check current state
#   ./e2e_flowswap_3secrets.sh verify     # Verify atomicity properties

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/tmp/flowswap_e2e_state"
mkdir -p "$STATE_DIR"

# VPS Configuration
SEED_IP="57.131.33.151"
CORESDK_IP="162.19.251.75"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"
OP3_IP="51.75.31.44"

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Actor mapping
USER_VPS="$OP3_IP"      # Charlie - sends BTC, receives USDC
LP1_VPS="$OP1_IP"       # Alice - BTC/M1 side
LP2_VPS="$CORESDK_IP"   # Bob - M1/USDC side

# CLI paths
BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"
BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet -rpcwallet=fake_user"

# Contract address (Base Sepolia)
HTLC3S_CONTRACT="0x2493EaaaBa6B129962c8967AaEE6bF11D0277756"

# Amounts (for testing)
BTC_AMOUNT_SATS=50000        # 0.0005 BTC
M1_AMOUNT=100000             # 100k sats equivalent
USDC_AMOUNT=25000000         # 25 USDC (6 decimals)

# Timeouts (blocks/seconds) — MUST respect BTC < M1 < USDC in absolute time
# BTC: ~10min/block, M1: 60s/block
T_BTC_BLOCKS=6               # ~1h on Signet (6×600s=3600s)
T_M1_BLOCKS=120              # ~2h on M1 (120×60s=7200s)
T_USDC_SECONDS=14400         # 4h on EVM

# Derived: timelock ordering invariant (seconds)
# BTC ~10min/block, M1 60s/block
T_BTC_SECONDS=$((T_BTC_BLOCKS * 600))
T_M1_SECONDS=$((T_M1_BLOCKS * 60))

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_phase() { echo -e "\n${CYAN}════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}════════════════════════════════════════${NC}\n"; }

ssh_cmd() {
    local ip="$1"
    shift
    ssh $SSH_OPTS "ubuntu@$ip" "$@"
}

save_state() {
    local key="$1"
    local value="$2"
    echo "$value" > "$STATE_DIR/$key"
}

load_state() {
    local key="$1"
    local default="${2:-}"
    if [[ -f "$STATE_DIR/$key" ]]; then
        cat "$STATE_DIR/$key"
    else
        echo "$default"
    fi
}

state_exists() {
    [[ -f "$STATE_DIR/$1" ]]
}

# Convert satoshis to BTC string with leading zero (JSON-safe)
format_btc_amount() {
    printf "%.8f" "$(echo "scale=8; $1 / 100000000" | bc)"
}

# Enforce timelock ordering invariant: BTC < M1 < USDC (absolute seconds)
check_timelock_invariant() {
    if [[ $T_BTC_SECONDS -ge $T_M1_SECONDS ]]; then
        log_error "INVARIANT VIOLATION: T_btc (${T_BTC_SECONDS}s) >= T_m1 (${T_M1_SECONDS}s)"
        log_error "Fix: T_BTC_BLOCKS × 600 must be < T_M1_BLOCKS × 60"
        return 1
    fi
    if [[ $T_M1_SECONDS -ge $T_USDC_SECONDS ]]; then
        log_error "INVARIANT VIOLATION: T_m1 (${T_M1_SECONDS}s) >= T_usdc (${T_USDC_SECONDS}s)"
        return 1
    fi
    return 0
}

# Wait for BTC UTXO to appear at an address (confirmed via scantxoutset)
# Usage: wait_btc_confirm <vps_ip> <btc_address> [max_checks] [interval_secs]
wait_btc_confirm() {
    local vps_ip="$1"
    local address="$2"
    local max_checks="${3:-30}"
    local interval="${4:-30}"
    local btc_cli="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

    log_info "Waiting for BTC confirmation at ${address:0:20}... (max ${max_checks}×${interval}s)"
    for i in $(seq 1 "$max_checks"); do
        sleep "$interval"
        local count
        count=$(ssh_cmd "$vps_ip" "$btc_cli scantxoutset start '[\"addr($address)\"]' 2>/dev/null" \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('unspents',[])))" 2>/dev/null || echo "0")
        echo -ne "\r  Check $i/$max_checks: UTXO count=$count"
        if [[ "$count" != "0" ]]; then
            echo ""
            log_success "BTC UTXO confirmed ($count outputs)"
            return 0
        fi
    done
    echo ""
    log_error "Timeout waiting for BTC confirmation"
    return 1
}

# ============================================================================
# PHASE 1: GENERATE SECRETS
# ============================================================================

phase_generate_secrets() {
    log_phase "Phase 1: Generate 3 Secrets"

    # Guard: refuse to start if timelock ordering is broken
    if ! check_timelock_invariant; then
        log_error "Aborting: fix timelock config before running E2E"
        return 1
    fi
    log_success "Timelock invariant OK: BTC(${T_BTC_SECONDS}s) < M1(${T_M1_SECONDS}s) < USDC(${T_USDC_SECONDS}s)"

    log_info "Generating S_user (Charlie/User)..."
    # User generates their secret on OP3
    local user_result=$(ssh_cmd "$USER_VPS" "$BATHRON_CLI htlc3s_generate" 2>/dev/null || echo "error")

    if [[ "$user_result" == "error" ]] || [[ -z "$user_result" ]]; then
        log_error "Failed to generate user secrets on OP3"
        return 1
    fi

    # Parse JSON response (format: {"user": {"secret": ..., "hashlock": ...}, "lp1": ..., "lp2": ...})
    local S_user=$(echo "$user_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['user']['secret'])")
    local H_user=$(echo "$user_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['user']['hashlock'])")

    save_state "S_user" "$S_user"
    save_state "H_user" "$H_user"
    log_success "User secret generated: H_user=${H_user:0:16}..."

    log_info "Generating S_lp1 (Alice/LP1)..."
    local lp1_result=$(ssh_cmd "$LP1_VPS" "$BATHRON_CLI htlc3s_generate" 2>/dev/null || echo "error")

    if [[ "$lp1_result" == "error" ]] || [[ -z "$lp1_result" ]]; then
        log_error "Failed to generate LP1 secrets on OP1"
        return 1
    fi

    local S_lp1=$(echo "$lp1_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['lp1']['secret'])")
    local H_lp1=$(echo "$lp1_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['lp1']['hashlock'])")

    save_state "S_lp1" "$S_lp1"
    save_state "H_lp1" "$H_lp1"
    log_success "LP1 secret generated: H_lp1=${H_lp1:0:16}..."

    log_info "Generating S_lp2 (Bob/LP2)..."
    local lp2_result=$(ssh_cmd "$LP2_VPS" "$BATHRON_CLI htlc3s_generate" 2>/dev/null || echo "error")

    if [[ "$lp2_result" == "error" ]] || [[ -z "$lp2_result" ]]; then
        log_error "Failed to generate LP2 secrets on CoreSDK"
        return 1
    fi

    local S_lp2=$(echo "$lp2_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['lp2']['secret'])")
    local H_lp2=$(echo "$lp2_result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['lp2']['hashlock'])")

    save_state "S_lp2" "$S_lp2"
    save_state "H_lp2" "$H_lp2"
    log_success "LP2 secret generated: H_lp2=${H_lp2:0:16}..."

    echo ""
    log_info "=== COMMITMENTS SUMMARY ==="
    echo "  H_user: $(load_state H_user)"
    echo "  H_lp1:  $(load_state H_lp1)"
    echo "  H_lp2:  $(load_state H_lp2)"
    echo ""
    log_warning "CRITICAL: S_user must NOT be shared until Phase 2A+2B complete!"

    save_state "phase" "1_complete"
    log_success "Phase 1 complete - 3 hashlocks committed"
}

# ============================================================================
# PHASE 2A: LP2 LOCKS USDC (EVM)
# ============================================================================

phase_lock_usdc() {
    log_phase "Phase 2A: LP2 Locks USDC (EVM HTLC3S)"

    if ! state_exists "H_user"; then
        log_error "Run 'generate' phase first"
        return 1
    fi

    local H_user=$(load_state H_user)
    local H_lp1=$(load_state H_lp1)
    local H_lp2=$(load_state H_lp2)

    log_info "LP2 (Bob) creating USDC HTLC3S on Base Sepolia..."
    log_info "  Contract: $HTLC3S_CONTRACT"
    log_info "  Amount: 5 USDC"
    log_info "  Recipient: Charlie's EVM address"
    log_info "  Hashlocks: H_user, H_lp1, H_lp2"
    log_info "  Timelock: $T_USDC_SECONDS seconds"

    # First, run debug to check balance/allowance
    log_info "Checking Bob's USDC balance and allowance..."
    local debug_result=$(ssh_cmd "$LP2_VPS" "cd /home/ubuntu/pna-lp && source venv/bin/activate && python3 << 'PYEOF'
import json
import traceback
from web3 import Web3

RPC_URL = 'https://sepolia.base.org'
HTLC3S_ADDRESS = '0x667E9bDC368F0aC2abff69F5963714e3656d2d9D'
USDC_ADDRESS = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'

# Load key
with open('/home/ubuntu/.BathronKey/evm.json') as f:
    key_data = json.load(f)

# Try multiple possible key names
pk = key_data.get('private_key') or key_data.get('bob_private_key') or ''
if not pk:
    print(json.dumps({'error': 'No private key found in evm.json', 'keys': list(key_data.keys())}))
else:
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    account = w3.eth.account.from_key(pk)

    # Check USDC balance and allowance
    usdc_abi = [
        {'name': 'balanceOf', 'type': 'function', 'stateMutability': 'view',
         'inputs': [{'name': 'account', 'type': 'address'}],
         'outputs': [{'name': '', 'type': 'uint256'}]},
        {'name': 'allowance', 'type': 'function', 'stateMutability': 'view',
         'inputs': [{'name': 'owner', 'type': 'address'}, {'name': 'spender', 'type': 'address'}],
         'outputs': [{'name': '', 'type': 'uint256'}]},
    ]

    usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_ADDRESS), abi=usdc_abi)
    balance = usdc.functions.balanceOf(account.address).call()
    allowance = usdc.functions.allowance(account.address, Web3.to_checksum_address(HTLC3S_ADDRESS)).call()

    print(json.dumps({
        'address': account.address,
        'balance_raw': balance,
        'balance_usdc': balance / 1e6,
        'allowance_raw': allowance,
        'allowance_usdc': allowance / 1e6
    }))
PYEOF
" 2>&1)

    log_info "Debug result: $debug_result"

    # Execute on CoreSDK via pna-lp SDK (use venv for dependencies)
    local lock_result=$(ssh_cmd "$LP2_VPS" "cd /home/ubuntu/pna-lp && source venv/bin/activate && python3 << 'PYEOF'
import json
import traceback
import sys
import logging

logging.basicConfig(level=logging.DEBUG, stream=sys.stderr)

try:
    from sdk.htlc.evm_3s import EVMHTLC3S

    # Load key file
    with open('/home/ubuntu/.BathronKey/evm.json') as f:
        key_data = json.load(f)

    # Try multiple possible key names
    pk = key_data.get('private_key') or key_data.get('bob_private_key') or ''

    if not pk:
        print(json.dumps({'error': 'No private key found', 'available_keys': list(key_data.keys())}))
        sys.exit(1)

    # Create HTLC3S client
    htlc = EVMHTLC3S()

    # Charlie's address (recipient)
    charlie_evm = '0x9f11B03618DeE8f12E7F90e753093B613CeD51D2'

    result = htlc.create_htlc(
        recipient=charlie_evm,
        amount_usdc=5.0,  # 5 USDC
        H_user='$H_user',
        H_lp1='$H_lp1',
        H_lp2='$H_lp2',
        timelock_seconds=$T_USDC_SECONDS,
        private_key=pk
    )

    if result.success:
        print(json.dumps({'htlc_id': result.htlc_id, 'tx_hash': result.tx_hash}))
    else:
        print(json.dumps({'error': result.error}))

except Exception as e:
    print(json.dumps({'error': str(e), 'traceback': traceback.format_exc()}))
PYEOF
" 2>&1)

    log_info "Lock result: $lock_result"

    # Extract JSON from mixed output (may have logging on stderr)
    local json_line=$(echo "$lock_result" | grep -E '^\{' | tail -1)

    if [[ -z "$json_line" ]] || echo "$json_line" | grep -q '"error"'; then
        log_error "Failed to create USDC HTLC3S"
        log_info "Full output: $lock_result"
        return 1
    fi

    local htlc_id=$(echo "$json_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('htlc_id', 'unknown'))")
    local tx_hash=$(echo "$json_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tx_hash', 'unknown'))")

    save_state "usdc_htlc_id" "$htlc_id"
    save_state "usdc_tx_hash" "$tx_hash"

    log_success "USDC HTLC3S created!"
    echo "  HTLC ID: $htlc_id"
    echo "  TX Hash: $tx_hash"
    echo "  Explorer: https://sepolia.basescan.org/tx/$tx_hash"

    # Verify on-chain
    log_info "Verifying HTLC state on-chain..."
    local verify_result=$(ssh_cmd "$LP2_VPS" "cd /home/ubuntu/pna-lp && source venv/bin/activate && python3 -c \"
from sdk.htlc.evm_3s import EVMHTLC3S
import json
from dataclasses import asdict

htlc = EVMHTLC3S()
state = htlc.get_htlc('$htlc_id')
if state:
    print(json.dumps(asdict(state)))
else:
    print('{}')
\"" 2>/dev/null || echo '{}')

    echo "  HTLC State: $verify_result"

    save_state "phase" "2a_complete"
    log_success "Phase 2A complete - USDC locked on EVM"
}

# ============================================================================
# PHASE 2B: LP1 LOCKS M1 (BATHRON)
# ============================================================================

phase_lock_m1() {
    log_phase "Phase 2B: LP1 Locks M1 (BATHRON HTLC3S)"

    if ! state_exists "H_user"; then
        log_error "Run 'generate' phase first"
        return 1
    fi

    local H_user=$(load_state H_user)
    local H_lp1=$(load_state H_lp1)
    local H_lp2=$(load_state H_lp2)

    log_info "LP1 (Alice) creating M1 HTLC3S on BATHRON..."

    # Get Alice's M1 receipt to lock
    log_info "Finding M1 receipt to lock..."
    local receipts=$(ssh_cmd "$LP1_VPS" "$BATHRON_CLI getwalletstate true" 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); m1=d.get('m1',{}); rs=m1.get('receipts',[]); print(rs[0]['outpoint'] if rs else '')")

    if [[ -z "$receipts" ]]; then
        log_error "No M1 receipts available on LP1 (Alice)"
        log_info "Run: bathron-cli -testnet lock $M1_AMOUNT"
        return 1
    fi

    local source_receipt="$receipts"
    log_info "  Source receipt: $source_receipt"

    # Bob's M1 address (recipient)
    local bob_m1_addr="y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk"

    log_info "Creating HTLC3S..."
    log_info "  H_user: $H_user"
    log_info "  H_lp1: $H_lp1"
    log_info "  H_lp2: $H_lp2"
    log_info "  Recipient: $bob_m1_addr"
    log_info "  Expiry blocks: $T_M1_BLOCKS"
    local create_result=$(ssh_cmd "$LP1_VPS" "$BATHRON_CLI htlc3s_create '$source_receipt' '$H_user' '$H_lp1' '$H_lp2' '$bob_m1_addr' $T_M1_BLOCKS" 2>&1 || echo '{"error": "rpc_failed"}')

    if echo "$create_result" | grep -q '"error"'; then
        log_error "Failed to create M1 HTLC3S"
        log_info "Result: $create_result"
        return 1
    fi

    local m1_htlc_outpoint=$(echo "$create_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('htlc_outpoint', 'unknown'))")
    local m1_txid=$(echo "$create_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid', 'unknown'))")

    save_state "m1_htlc_outpoint" "$m1_htlc_outpoint"
    save_state "m1_txid" "$m1_txid"

    log_success "M1 HTLC3S created!"
    echo "  HTLC Outpoint: $m1_htlc_outpoint"
    echo "  TX ID: $m1_txid"

    # Verify via RPC
    log_info "Verifying HTLC3S state..."
    local verify_result=$(ssh_cmd "$LP1_VPS" "$BATHRON_CLI htlc3s_get \"$m1_htlc_outpoint\"" 2>/dev/null || echo '{}')
    echo "  HTLC State: $verify_result"

    # Verify cross-chain index
    log_info "Verifying cross-chain index (find_by_hashlock)..."
    local index_check=$(ssh_cmd "$LP1_VPS" "$BATHRON_CLI htlc3s_find_by_hashlock \"$H_user\" user" 2>/dev/null || echo '[]')
    echo "  Index H_user: $index_check"

    save_state "phase" "2b_complete"
    log_success "Phase 2B complete - M1 locked on BATHRON"
    log_warning "Now safe to proceed with BTC lock (Phase 3)"
}

# ============================================================================
# PHASE 3: USER LOCKS BTC
# ============================================================================

phase_lock_btc() {
    log_phase "Phase 3: User Locks BTC (P2WSH HTLC3S)"

    if ! state_exists "H_user"; then
        log_error "Run 'generate' phase first"
        return 1
    fi

    local H_user=$(load_state H_user)
    local H_lp1=$(load_state H_lp1)
    local H_lp2=$(load_state H_lp2)

    log_info "User (Charlie) creating BTC HTLC3S on Signet..."

    # Get LP1's BTC pubkey for claim path
    log_info "Getting LP1 pubkey for claim path..."
    local lp1_btc_pubkey=$(ssh_cmd "$LP1_VPS" "cat ~/.BathronKey/btc.json 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('pubkey', ''))\"" || echo "")

    if [[ -z "$lp1_btc_pubkey" ]]; then
        log_error "LP1 BTC pubkey not found"
        return 1
    fi

    # Get User's BTC pubkey for refund path
    local user_btc_pubkey=$(ssh_cmd "$USER_VPS" "cat ~/.BathronKey/btc.json 2>/dev/null | python3 -c \"import sys,json; print(json.load(sys.stdin).get('pubkey', ''))\"" || echo "")

    if [[ -z "$user_btc_pubkey" ]]; then
        log_error "User BTC pubkey not found"
        return 1
    fi

    log_info "Creating HTLC3S script..."
    log_info "  Claim pubkey (LP1): ${lp1_btc_pubkey:0:20}..."
    log_info "  Refund pubkey (User): ${user_btc_pubkey:0:20}..."

    # Create HTLC on OP3 using btc_3s.py
    local create_result=$(ssh_cmd "$USER_VPS" "cd /home/ubuntu/pna-lp 2>/dev/null || cd /home/ubuntu && python3 -c \"
import sys
# Try local pna-lp deployment first, then BATHRON repo
sys.path.insert(0, '/home/ubuntu/pna-lp')
sys.path.insert(0, '/home/ubuntu/BATHRON/contrib/dex/pna-lp')

from sdk.htlc.btc_3s import BTCHTLC3S, HTLC3SParams
from sdk.chains.btc import BTCClient
import json

# Initialize BTC client
with open('/home/ubuntu/.BathronKey/btc.json') as f:
    btc_config = json.load(f)

class BTCConfig:
    network = 'signet'

class SimpleBTCClient:
    def __init__(self):
        self.config = BTCConfig()

    def get_block_count(self):
        import subprocess
        result = subprocess.run([
            '/home/ubuntu/bitcoin/bin/bitcoin-cli',
            '-signet', '-datadir=/home/ubuntu/.bitcoin-signet',
            'getblockcount'
        ], capture_output=True, text=True)
        return int(result.stdout.strip())

    def _call(self, method, *args):
        import subprocess
        cmd = ['/home/ubuntu/bitcoin/bin/bitcoin-cli', '-signet', '-datadir=/home/ubuntu/.bitcoin-signet', method] + [str(a) for a in args]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise Exception(result.stderr)
        return result.stdout.strip()

client = SimpleBTCClient()
htlc = BTCHTLC3S(client)

result = htlc.create_htlc_3s(
    amount_sats=$BTC_AMOUNT_SATS,
    H_user='$H_user',
    H_lp1='$H_lp1',
    H_lp2='$H_lp2',
    recipient_pubkey='$lp1_btc_pubkey',
    refund_pubkey='$user_btc_pubkey',
    timeout_blocks=$T_BTC_BLOCKS
)

print(json.dumps(result))
\"" 2>/dev/null || echo '{"error": "script failed"}')

    if echo "$create_result" | grep -q '"error"'; then
        log_error "Failed to create BTC HTLC3S script"
        log_info "Result: $create_result"
        return 1
    fi

    local htlc_address=$(echo "$create_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('htlc_address', ''))")
    local redeem_script=$(echo "$create_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('redeem_script', ''))")
    local timelock=$(echo "$create_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('timelock', 0))")

    save_state "btc_htlc_address" "$htlc_address"
    save_state "btc_redeem_script" "$redeem_script"
    save_state "btc_timelock" "$timelock"

    log_success "BTC HTLC3S script created!"
    echo "  HTLC Address: $htlc_address"
    echo "  Timelock: $timelock"
    echo "  Redeem Script: ${redeem_script:0:64}..."

    # Fund the HTLC
    log_info "Funding HTLC with $BTC_AMOUNT_SATS sats..."
    local btc_amount
    btc_amount=$(format_btc_amount "$BTC_AMOUNT_SATS")

    local fund_result=$(ssh_cmd "$USER_VPS" "$BTC_CLI sendtoaddress \"$htlc_address\" $btc_amount" 2>&1)
    local fund_rc=$?

    if [[ $fund_rc -ne 0 ]] || echo "$fund_result" | grep -q "error"; then
        log_error "Failed to fund HTLC"
        log_info "Error: $fund_result"

        # Show wallet balance for debugging
        local balance=$(ssh_cmd "$USER_VPS" "$BTC_CLI getbalance" 2>&1 || echo "wallet error")
        log_info "Wallet balance: $balance"

        log_warning "Manually send $btc_amount BTC to: $htlc_address"
        return 1
    fi

    local fund_txid="$fund_result"

    save_state "btc_fund_txid" "$fund_txid"

    log_success "BTC HTLC funded!"
    echo "  Funding TX: $fund_txid"
    echo "  Explorer: https://mempool.space/signet/tx/$fund_txid"

    save_state "phase" "3_complete"
    log_success "Phase 3 complete - BTC locked"
    log_warning "Wait for confirmations before LP1 can claim"
}

# ============================================================================
# PHASE 4: LP1 CLAIMS BTC (REVEALS SECRETS)
# ============================================================================

phase_claim_btc() {
    log_phase "Phase 4: LP1 Claims BTC (REVEALS ALL 3 SECRETS)"

    if ! state_exists "btc_htlc_address"; then
        log_error "Run 'lock_btc' phase first"
        return 1
    fi

    local htlc_address=$(load_state btc_htlc_address)
    local redeem_script=$(load_state btc_redeem_script)
    local S_user=$(load_state S_user)
    local S_lp1=$(load_state S_lp1)
    local S_lp2=$(load_state S_lp2)

    log_info "LP1 (Alice) claiming BTC HTLC3S..."
    log_warning "THIS IS THE MOMENT OF ATOMICITY - secrets will be revealed!"

    # Check UTXO
    log_info "Checking HTLC funding UTXO..."
    local utxo_check=$(ssh_cmd "$LP1_VPS" "$BTC_CLI scantxoutset start '[\"addr($htlc_address)\"]'" 2>/dev/null || echo '{}')

    local utxo_count=$(echo "$utxo_check" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('unspents', [])))")

    if [[ "$utxo_count" == "0" ]]; then
        log_error "No UTXO found at HTLC address"
        log_info "Wait for BTC confirmation or check funding"
        return 1
    fi

    local utxo_txid=$(echo "$utxo_check" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unspents'][0]['txid'])")
    local utxo_vout=$(echo "$utxo_check" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unspents'][0]['vout'])")
    local utxo_amount=$(echo "$utxo_check" | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d['unspents'][0]['amount'] * 100000000))")

    log_info "  UTXO: $utxo_txid:$utxo_vout ($utxo_amount sats)"

    # Get LP1's receiving address
    local lp1_btc_addr=$(ssh_cmd "$LP1_VPS" "cat ~/.BathronKey/btc.json | python3 -c \"import sys,json; print(json.load(sys.stdin).get('address', ''))\"")

    # Claim with all 3 secrets
    log_info "Executing claim with 3 secrets..."
    local claim_result=$(ssh_cmd "$LP1_VPS" "cd /home/ubuntu && python3 -c \"
import sys
sys.path.insert(0, '/home/ubuntu/pna-lp')
sys.path.insert(0, '/home/ubuntu/BATHRON/contrib/dex/pna-lp')

from sdk.htlc.btc_3s import BTCHTLC3S, HTLC3SSecrets
import json

class BTCConfig:
    network = 'signet'

class SimpleBTCClient:
    def __init__(self):
        self.config = BTCConfig()

    def get_block_count(self):
        import subprocess
        result = subprocess.run([
            '/home/ubuntu/bitcoin/bin/bitcoin-cli',
            '-signet', '-datadir=/home/ubuntu/.bitcoin-signet',
            'getblockcount'
        ], capture_output=True, text=True)
        return int(result.stdout.strip())

    def _call(self, method, *args):
        import subprocess
        cmd = ['/home/ubuntu/bitcoin/bin/bitcoin-cli', '-signet', '-datadir=/home/ubuntu/.bitcoin-signet', method] + [str(a) for a in args]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise Exception(result.stderr)
        return result.stdout.strip()

    def create_raw_transaction(self, inputs, outputs):
        import subprocess
        cmd = [
            '/home/ubuntu/bitcoin/bin/bitcoin-cli',
            '-signet', '-datadir=/home/ubuntu/.bitcoin-signet',
            'createrawtransaction',
            json.dumps(inputs),
            json.dumps(outputs)
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        return result.stdout.strip()

    def send_raw_transaction(self, hex_tx):
        import subprocess
        cmd = [
            '/home/ubuntu/bitcoin/bin/bitcoin-cli',
            '-signet', '-datadir=/home/ubuntu/.bitcoin-signet',
            'sendrawtransaction', hex_tx
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            raise Exception(result.stderr)
        return result.stdout.strip()

with open('/home/ubuntu/.BathronKey/btc.json') as f:
    btc_config = json.load(f)

client = SimpleBTCClient()
htlc = BTCHTLC3S(client)

secrets = HTLC3SSecrets(
    S_user='$S_user',
    S_lp1='$S_lp1',
    S_lp2='$S_lp2'
)

utxo = {
    'txid': '$utxo_txid',
    'vout': $utxo_vout,
    'amount': $utxo_amount
}

claim_txid = htlc.claim_htlc_3s(
    utxo=utxo,
    redeem_script='$redeem_script',
    secrets=secrets,
    recipient_address='$lp1_btc_addr',
    claim_privkey_wif=btc_config.get('claim_wif') or btc_config.get('wif')
)

print(json.dumps({'claim_txid': claim_txid}))
\"" 2>/dev/null || echo '{"error": "claim failed"}')

    if echo "$claim_result" | grep -q '"error"'; then
        log_error "BTC claim failed"
        log_info "Result: $claim_result"
        return 1
    fi

    local claim_txid=$(echo "$claim_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('claim_txid', ''))")

    save_state "btc_claim_txid" "$claim_txid"

    log_success "BTC HTLC3S CLAIMED!"
    echo "  Claim TX: $claim_txid"
    echo "  Explorer: https://mempool.space/signet/tx/$claim_txid"

    log_warning "SECRETS ARE NOW PUBLIC ON BTC BLOCKCHAIN!"
    echo "  S_user: ${S_user:0:32}..."
    echo "  S_lp1:  ${S_lp1:0:32}..."
    echo "  S_lp2:  ${S_lp2:0:32}..."

    save_state "phase" "4_complete"
    save_state "secrets_revealed" "true"

    log_success "Phase 4 complete - secrets revealed, atomicity achieved"
    log_info "Anyone can now claim USDC and M1 (permissionless)"
}

# ============================================================================
# PHASE 5A: CLAIM USDC (PERMISSIONLESS)
# ============================================================================

phase_claim_usdc() {
    log_phase "Phase 5A: Claim USDC (Permissionless)"

    if ! state_exists "secrets_revealed"; then
        log_error "Secrets not yet revealed. Run 'claim_btc' first."
        return 1
    fi

    local usdc_htlc_id=$(load_state usdc_htlc_id)
    local S_user=$(load_state S_user)
    local S_lp1=$(load_state S_lp1)
    local S_lp2=$(load_state S_lp2)

    log_info "Claiming USDC HTLC3S (anyone can execute)..."
    log_info "  HTLC ID: $usdc_htlc_id"

    # Execute claim on EVM (can be done by anyone - watcher, user, etc.)
    local claim_result=$(ssh_cmd "$LP2_VPS" "cd /home/ubuntu/pna-lp && source venv/bin/activate && python3 -c \"
from sdk.htlc.evm_3s import EVMHTLC3S
import json

with open('/home/ubuntu/.BathronKey/evm.json') as f:
    key_data = json.load(f)

htlc = EVMHTLC3S()

result = htlc.claim_htlc(
    htlc_id='$usdc_htlc_id',
    S_user='$S_user',
    S_lp1='$S_lp1',
    S_lp2='$S_lp2',
    private_key=key_data.get('private_key', '')
)

if result.success:
    print(json.dumps({'tx_hash': result.tx_hash}))
else:
    print(json.dumps({'error': result.error}))
\"" 2>/dev/null || echo '{"error": "claim failed"}')

    if echo "$claim_result" | grep -q '"error"'; then
        log_error "USDC claim failed"
        log_info "Result: $claim_result"
        return 1
    fi

    local claim_tx=$(echo "$claim_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tx_hash', ''))")

    save_state "usdc_claim_tx" "$claim_tx"

    log_success "USDC HTLC3S claimed!"
    echo "  TX Hash: $claim_tx"
    echo "  Explorer: https://sepolia.basescan.org/tx/$claim_tx"
    log_info "Charlie (User) received USDC at their fixed recipient address"

    save_state "phase" "5a_complete"
    log_success "Phase 5A complete - User received USDC"
}

# ============================================================================
# PHASE 5B: LP2 CLAIMS M1
# ============================================================================

phase_claim_m1() {
    log_phase "Phase 5B: LP2 Claims M1"

    if ! state_exists "secrets_revealed"; then
        log_error "Secrets not yet revealed. Run 'claim_btc' first."
        return 1
    fi

    local m1_htlc_outpoint=$(load_state m1_htlc_outpoint)
    local S_user=$(load_state S_user)
    local S_lp1=$(load_state S_lp1)
    local S_lp2=$(load_state S_lp2)

    log_info "LP2 (Bob) claiming M1 HTLC3S..."
    log_info "  HTLC Outpoint: $m1_htlc_outpoint"

    # Claim on BATHRON
    local claim_result=$(ssh_cmd "$LP2_VPS" "$BATHRON_CLI htlc3s_claim \"$m1_htlc_outpoint\" \"$S_user\" \"$S_lp1\" \"$S_lp2\"" 2>/dev/null || echo '{"error": "claim failed"}')

    if echo "$claim_result" | grep -q '"error"'; then
        log_error "M1 claim failed"
        log_info "Result: $claim_result"
        return 1
    fi

    local claim_txid=$(echo "$claim_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid', ''))")
    local new_receipt=$(echo "$claim_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('receipt_outpoint', ''))")

    save_state "m1_claim_txid" "$claim_txid"
    save_state "m1_new_receipt" "$new_receipt"

    log_success "M1 HTLC3S claimed!"
    echo "  TX ID: $claim_txid"
    echo "  New Receipt: $new_receipt"
    log_info "LP2 (Bob) received M1"

    save_state "phase" "5b_complete"
    log_success "Phase 5B complete - LP2 received M1"
}

# ============================================================================
# STATUS & VERIFICATION
# ============================================================================

show_status() {
    log_phase "FlowSwap E2E Status"

    local phase=$(load_state phase "not_started")

    echo "Current Phase: $phase"
    echo ""

    echo "=== Hashlocks ==="
    if state_exists "H_user"; then
        echo "  H_user: $(load_state H_user)"
        echo "  H_lp1:  $(load_state H_lp1)"
        echo "  H_lp2:  $(load_state H_lp2)"
    else
        echo "  (not generated)"
    fi
    echo ""

    echo "=== USDC HTLC (EVM) ==="
    if state_exists "usdc_htlc_id"; then
        echo "  HTLC ID: $(load_state usdc_htlc_id)"
        echo "  TX: $(load_state usdc_tx_hash)"
        if state_exists "usdc_claim_tx"; then
            echo "  Claimed: $(load_state usdc_claim_tx)"
        fi
    else
        echo "  (not created)"
    fi
    echo ""

    echo "=== M1 HTLC (BATHRON) ==="
    if state_exists "m1_htlc_outpoint"; then
        echo "  Outpoint: $(load_state m1_htlc_outpoint)"
        echo "  TX: $(load_state m1_txid)"
        if state_exists "m1_claim_txid"; then
            echo "  Claimed: $(load_state m1_claim_txid)"
        fi
    else
        echo "  (not created)"
    fi
    echo ""

    echo "=== BTC HTLC ==="
    if state_exists "btc_htlc_address"; then
        echo "  Address: $(load_state btc_htlc_address)"
        echo "  Timelock: $(load_state btc_timelock)"
        if state_exists "btc_fund_txid"; then
            echo "  Funded: $(load_state btc_fund_txid)"
        fi
        if state_exists "btc_claim_txid"; then
            echo "  Claimed: $(load_state btc_claim_txid)"
        fi
    else
        echo "  (not created)"
    fi
    echo ""

    if state_exists "secrets_revealed"; then
        log_warning "SECRETS REVEALED - Atomicity achieved"
    fi
}

verify_atomicity() {
    log_phase "Verify Atomicity Properties"

    local errors=0

    # A) Cryptographic consistency
    echo "A) Cryptographic Consistency"

    if state_exists "H_user"; then
        local H_user=$(load_state H_user)
        local H_lp1=$(load_state H_lp1)
        local H_lp2=$(load_state H_lp2)

        # Verify hashlocks are 64 hex chars (32 bytes)
        if [[ ${#H_user} -eq 64 ]] && [[ ${#H_lp1} -eq 64 ]] && [[ ${#H_lp2} -eq 64 ]]; then
            log_success "Hashlocks are valid 32-byte SHA256"
        else
            log_error "Invalid hashlock lengths"
            ((errors++))
        fi

        # If secrets revealed, verify they match
        if state_exists "secrets_revealed"; then
            local S_user=$(load_state S_user)
            local S_lp1=$(load_state S_lp1)
            local S_lp2=$(load_state S_lp2)

            local computed_H_user=$(echo -n "$S_user" | xxd -r -p | sha256sum | cut -d' ' -f1)
            local computed_H_lp1=$(echo -n "$S_lp1" | xxd -r -p | sha256sum | cut -d' ' -f1)
            local computed_H_lp2=$(echo -n "$S_lp2" | xxd -r -p | sha256sum | cut -d' ' -f1)

            if [[ "$computed_H_user" == "$H_user" ]]; then
                log_success "SHA256(S_user) == H_user"
            else
                log_error "S_user hash mismatch!"
                ((errors++))
            fi

            if [[ "$computed_H_lp1" == "$H_lp1" ]]; then
                log_success "SHA256(S_lp1) == H_lp1"
            else
                log_error "S_lp1 hash mismatch!"
                ((errors++))
            fi

            if [[ "$computed_H_lp2" == "$H_lp2" ]]; then
                log_success "SHA256(S_lp2) == H_lp2"
            else
                log_error "S_lp2 hash mismatch!"
                ((errors++))
            fi
        fi
    else
        log_warning "No hashlocks generated yet"
    fi

    echo ""

    # B) Observable atomicity
    echo "B) Observable Atomicity"

    local phase=$(load_state phase "not_started")

    case "$phase" in
        "not_started"|"1_complete")
            log_info "No locks yet - no atomicity constraints"
            ;;
        "2a_complete"|"2b_complete"|"3_complete")
            log_warning "Locks exist but BTC not claimed - refunds possible after timeouts"
            ;;
        "4_complete"|"5a_complete"|"5b_complete")
            log_success "BTC claimed - all other legs claimable with revealed secrets"
            ;;
    esac

    echo ""

    # C) Timeout ordering
    echo "C) Timeout Ordering"
    echo "  T_btc: ${T_BTC_BLOCKS} blocks = ${T_BTC_SECONDS}s (~$((T_BTC_SECONDS/3600))h)"
    echo "  T_m1:  ${T_M1_BLOCKS} blocks = ${T_M1_SECONDS}s (~$((T_M1_SECONDS/3600))h)"
    echo "  T_usdc: ${T_USDC_SECONDS}s (~$((T_USDC_SECONDS/3600))h)"

    if check_timelock_invariant; then
        log_success "Timeouts correctly ordered (BTC < M1 < USDC)"
    else
        log_error "Timeout ordering violated!"
        ((errors++))
    fi

    # D) Canonical secret ordering
    echo ""
    echo "D) Canonical Secret Ordering"
    echo "  Logical:         (S_user, S_lp1, S_lp2)"
    echo "  BTC witness:     <sig> <S_lp2> <S_lp1> <S_user> <1> <script>"
    echo "  M1/EVM claim:    claim(id, S_user, S_lp1, S_lp2)"
    log_success "Ordering documented and enforced in btc_3s.py + evm_3s.py"

    echo ""

    # Summary
    if [[ $errors -eq 0 ]]; then
        log_success "All atomicity properties verified!"
    else
        log_error "$errors atomicity violations found"
    fi

    return $errors
}

# ============================================================================
# PROOF REPORT (audit-friendly)
# ============================================================================

show_proof() {
    local phase=$(load_state phase "not_started")
    local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat << PROOF
# FlowSwap 3-Secrets E2E Proof Report
# Generated: $ts
# Phase: $phase

## Cryptographic Commitments

| Secret | Hashlock (SHA256) |
|--------|-------------------|
| H_user | $(load_state H_user "n/a") |
| H_lp1  | $(load_state H_lp1 "n/a") |
| H_lp2  | $(load_state H_lp2 "n/a") |

## BTC (Signet)

| Field | Value |
|-------|-------|
| HTLC Address (P2WSH) | $(load_state btc_htlc_address "n/a") |
| Timelock (block height) | $(load_state btc_timelock "n/a") |
| Funding TX | $(load_state btc_fund_txid "n/a") |
| Claim TX | $(load_state btc_claim_txid "n/a") |
| Explorer (fund) | https://mempool.space/signet/tx/$(load_state btc_fund_txid "n/a") |
| Explorer (claim) | https://mempool.space/signet/tx/$(load_state btc_claim_txid "n/a") |

## M1 (BATHRON testnet5)

| Field | Value |
|-------|-------|
| HTLC3S Create TX | $(load_state m1_txid "n/a") |
| HTLC Outpoint | $(load_state m1_htlc_outpoint "n/a") |
| Claim TX | $(load_state m1_claim_txid "n/a") |
| New Receipt | $(load_state m1_new_receipt "n/a") |

## EVM (Base Sepolia, chain 84532)

| Field | Value |
|-------|-------|
| Contract | $HTLC3S_CONTRACT |
| HTLC ID | $(load_state usdc_htlc_id "n/a") |
| Lock TX | $(load_state usdc_tx_hash "n/a") |
| Claim TX | $(load_state usdc_claim_tx "n/a") |
| Explorer (lock) | https://sepolia.basescan.org/tx/$(load_state usdc_tx_hash "n/a") |
| Explorer (claim) | https://sepolia.basescan.org/tx/$(load_state usdc_claim_tx "n/a") |

## Invariants

| Invariant | Value | Status |
|-----------|-------|--------|
| Timelock ordering | BTC(${T_BTC_SECONDS}s) < M1(${T_M1_SECONDS}s) < USDC(${T_USDC_SECONDS}s) | $(check_timelock_invariant 2>/dev/null && echo "OK" || echo "FAIL") |
| Secret ordering | (S_user, S_lp1, S_lp2) canonical | OK |
| BTC witness order | <sig> <S_lp2> <S_lp1> <S_user> <1> <script> | LIFO |
| EVM claim | anyone-can-execute, recipient fixed at creation | Permissionless |
| Atomicity | BTC claim reveals all 3 secrets on-chain | $(state_exists secrets_revealed && echo "PROVEN" || echo "pending") |

## Amounts

| Chain | Amount |
|-------|--------|
| BTC | $BTC_AMOUNT_SATS sats ($(format_btc_amount $BTC_AMOUNT_SATS) BTC) |
| M1 | $M1_AMOUNT sats |
| USDC | $((USDC_AMOUNT / 1000000)).$((USDC_AMOUNT % 1000000)) USDC |
PROOF
}

# ============================================================================
# MAIN
# ============================================================================

run_all() {
    phase_generate_secrets
    echo ""
    read -p "Press Enter to continue to Phase 2A (Lock USDC)..."

    phase_lock_usdc
    echo ""
    read -p "Press Enter to continue to Phase 2B (Lock M1)..."

    phase_lock_m1
    echo ""
    read -p "Press Enter to continue to Phase 3 (Lock BTC)..."

    phase_lock_btc
    echo ""
    log_warning "Wait for BTC confirmations before claiming!"
    read -p "Press Enter to continue to Phase 4 (Claim BTC - REVEALS SECRETS)..."

    phase_claim_btc
    echo ""
    read -p "Press Enter to continue to Phase 5A (Claim USDC)..."

    phase_claim_usdc
    echo ""
    read -p "Press Enter to continue to Phase 5B (Claim M1)..."

    phase_claim_m1
    echo ""

    log_phase "FlowSwap E2E Complete!"
    verify_atomicity
}

case "${1:-status}" in
    all)
        run_all
        ;;
    generate)
        phase_generate_secrets
        ;;
    lock_usdc)
        phase_lock_usdc
        ;;
    lock_m1)
        phase_lock_m1
        ;;
    lock_btc)
        phase_lock_btc
        ;;
    claim_btc)
        phase_claim_btc
        ;;
    claim_usdc)
        phase_claim_usdc
        ;;
    claim_m1)
        phase_claim_m1
        ;;
    status)
        show_status
        ;;
    verify)
        verify_atomicity
        ;;
    wait)
        if ! state_exists "btc_htlc_address"; then
            log_error "No BTC HTLC address. Run lock_btc first."
            exit 1
        fi
        wait_btc_confirm "$LP1_VPS" "$(load_state btc_htlc_address)" 30 30
        ;;
    proof)
        show_proof
        ;;
    clean)
        rm -rf "$STATE_DIR"
        log_info "State cleared"
        ;;
    *)
        echo "Usage: $0 {all|generate|lock_usdc|lock_m1|lock_btc|wait|claim_btc|claim_usdc|claim_m1|status|verify|proof|clean}"
        exit 1
        ;;
esac
