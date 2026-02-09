#!/bin/bash
#
# Check FlowSwap wallet configurations on all VPS
#
# Verifies:
# - BATHRON wallets (~/.BathronKey/wallet.json)
# - BTC Signet wallets (OP1, OP3)
# - EVM wallets (OP1, CoreSDK, OP3)
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_err() { echo -e "${RED}[✗]${NC} $1"; }
log_section() { echo -e "\n${CYAN}═══ $1 ═══${NC}"; }

ssh_cmd() {
    local ip="$1"
    shift
    ssh $SSH_OPTS "ubuntu@$ip" "$@" 2>/dev/null
}

# VPS
SEED_IP="57.131.33.151"
CORESDK_IP="162.19.251.75"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"
OP3_IP="51.75.31.44"

BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         FlowSwap Wallet Configuration Check                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ============================================================================
# OP1 - Alice (LP1: BTC/M1 side)
# ============================================================================
log_section "OP1 - Alice (LP1: BTC/M1)"
echo "  IP: $OP1_IP"

# BATHRON wallet
bathron_wallet=$(ssh_cmd "$OP1_IP" "cat ~/.BathronKey/wallet.json 2>/dev/null" || echo '{}')
alice_name=$(echo "$bathron_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name', 'NOT SET'))" 2>/dev/null || echo "ERROR")
alice_addr=$(echo "$bathron_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address', 'NOT SET'))" 2>/dev/null || echo "ERROR")

if [[ "$alice_name" == "alice" ]]; then
    log_ok "BATHRON wallet: $alice_name"
    echo "      Address: $alice_addr"
else
    log_err "BATHRON wallet: expected 'alice', got '$alice_name'"
fi

# M1 balance
m1_balance=$(ssh_cmd "$OP1_IP" "$BATHRON_CLI getwalletstate true 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(sum(r['amount'] for r in d.get('m1_receipts',[])))\"" || echo "0")
echo "      M1 balance: $m1_balance sats"

# BTC wallet
btc_wallet=$(ssh_cmd "$OP1_IP" "cat ~/.BathronKey/btc.json 2>/dev/null" || echo '{}')
btc_addr=$(echo "$btc_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address', 'NOT SET'))" 2>/dev/null || echo "ERROR")
btc_pubkey=$(echo "$btc_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pubkey', 'NOT SET'))" 2>/dev/null || echo "ERROR")

if [[ "$btc_addr" != "NOT SET" ]] && [[ "$btc_addr" != "ERROR" ]]; then
    log_ok "BTC wallet configured"
    echo "      Address: $btc_addr"
    echo "      Pubkey: ${btc_pubkey:0:20}..."
else
    log_warn "BTC wallet NOT configured in ~/.BathronKey/btc.json"
fi

# BTC Signet running?
btc_running=$(ssh_cmd "$OP1_IP" "pgrep -x bitcoind >/dev/null && echo 'yes' || echo 'no'")
if [[ "$btc_running" == "yes" ]]; then
    btc_height=$(ssh_cmd "$OP1_IP" "$BTC_CLI getblockcount" || echo "0")
    btc_balance=$(ssh_cmd "$OP1_IP" "$BTC_CLI getbalance" || echo "0")
    log_ok "BTC Signet running, height=$btc_height"
    echo "      Balance: $btc_balance BTC"
else
    log_warn "BTC Signet NOT running"
fi

# EVM wallet
evm_wallet=$(ssh_cmd "$OP1_IP" "cat ~/.BathronKey/evm.json 2>/dev/null" || echo '{}')
evm_addr=$(echo "$evm_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address', 'NOT SET'))" 2>/dev/null || echo "ERROR")

if [[ "$evm_addr" != "NOT SET" ]] && [[ "$evm_addr" != "ERROR" ]]; then
    log_ok "EVM wallet configured"
    echo "      Address: $evm_addr"
else
    log_warn "EVM wallet NOT configured"
fi

# ============================================================================
# CoreSDK - Bob (LP2: M1/USDC side)
# ============================================================================
log_section "CoreSDK - Bob (LP2: M1/USDC)"
echo "  IP: $CORESDK_IP"

# BATHRON wallet
bathron_wallet=$(ssh_cmd "$CORESDK_IP" "cat ~/.BathronKey/wallet.json 2>/dev/null" || echo '{}')
bob_name=$(echo "$bathron_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name', 'NOT SET'))" 2>/dev/null || echo "ERROR")
bob_addr=$(echo "$bathron_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address', 'NOT SET'))" 2>/dev/null || echo "ERROR")

if [[ "$bob_name" == "bob" ]]; then
    log_ok "BATHRON wallet: $bob_name"
    echo "      Address: $bob_addr"
else
    log_err "BATHRON wallet: expected 'bob', got '$bob_name'"
fi

# M1 balance
m1_balance=$(ssh_cmd "$CORESDK_IP" "$BATHRON_CLI getwalletstate true 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(sum(r['amount'] for r in d.get('m1_receipts',[])))\"" || echo "0")
echo "      M1 balance: $m1_balance sats"

# EVM wallet
evm_wallet=$(ssh_cmd "$CORESDK_IP" "cat ~/.BathronKey/evm.json 2>/dev/null" || echo '{}')
evm_addr=$(echo "$evm_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address', 'NOT SET'))" 2>/dev/null || echo "ERROR")

if [[ "$evm_addr" != "NOT SET" ]] && [[ "$evm_addr" != "ERROR" ]]; then
    log_ok "EVM wallet configured"
    echo "      Address: $evm_addr"
else
    log_err "EVM wallet NOT configured (required for USDC lock)"
fi

# ============================================================================
# OP3 - Charlie (User: sends BTC, receives USDC)
# ============================================================================
log_section "OP3 - Charlie (User)"
echo "  IP: $OP3_IP"

# BATHRON wallet
bathron_wallet=$(ssh_cmd "$OP3_IP" "cat ~/.BathronKey/wallet.json 2>/dev/null" || echo '{}')
charlie_name=$(echo "$bathron_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name', 'NOT SET'))" 2>/dev/null || echo "ERROR")
charlie_addr=$(echo "$bathron_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address', 'NOT SET'))" 2>/dev/null || echo "ERROR")

if [[ "$charlie_name" == "charlie" ]]; then
    log_ok "BATHRON wallet: $charlie_name"
    echo "      Address: $charlie_addr"
else
    log_err "BATHRON wallet: expected 'charlie', got '$charlie_name'"
fi

# BTC wallet
btc_wallet=$(ssh_cmd "$OP3_IP" "cat ~/.BathronKey/btc.json 2>/dev/null" || echo '{}')
btc_addr=$(echo "$btc_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address', 'NOT SET'))" 2>/dev/null || echo "ERROR")
btc_pubkey=$(echo "$btc_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pubkey', 'NOT SET'))" 2>/dev/null || echo "ERROR")

if [[ "$btc_addr" != "NOT SET" ]] && [[ "$btc_addr" != "ERROR" ]]; then
    log_ok "BTC wallet configured"
    echo "      Address: $btc_addr"
    echo "      Pubkey: ${btc_pubkey:0:20}..."
else
    log_warn "BTC wallet NOT configured in ~/.BathronKey/btc.json"
fi

# BTC Signet running?
btc_running=$(ssh_cmd "$OP3_IP" "pgrep -x bitcoind >/dev/null && echo 'yes' || echo 'no'")
if [[ "$btc_running" == "yes" ]]; then
    btc_height=$(ssh_cmd "$OP3_IP" "$BTC_CLI getblockcount" || echo "0")
    btc_balance=$(ssh_cmd "$OP3_IP" "$BTC_CLI getbalance" || echo "0")
    log_ok "BTC Signet running, height=$btc_height"
    echo "      Balance: $btc_balance BTC"
else
    log_warn "BTC Signet NOT running"
fi

# EVM wallet
evm_wallet=$(ssh_cmd "$OP3_IP" "cat ~/.BathronKey/evm.json 2>/dev/null" || echo '{}')
evm_addr=$(echo "$evm_wallet" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address', 'NOT SET'))" 2>/dev/null || echo "ERROR")

if [[ "$evm_addr" != "NOT SET" ]] && [[ "$evm_addr" != "ERROR" ]]; then
    log_ok "EVM wallet configured"
    echo "      Address: $evm_addr"
else
    log_warn "EVM wallet NOT configured (user needs this for USDC receipt)"
fi

# ============================================================================
# Summary
# ============================================================================
log_section "HTLC3S Contract (Base Sepolia)"
echo "  Address: 0x667E9bDC368F0aC2abff69F5963714e3656d2d9D"
echo "  Explorer: https://sepolia.basescan.org/address/0x667E9bDC368F0aC2abff69F5963714e3656d2d9D"

log_section "Summary"
echo ""
echo "  FlowSwap Actors:"
echo "  ┌────────────┬────────────┬─────────────────────────────────────────┐"
echo "  │ Role       │ VPS        │ Wallets                                 │"
echo "  ├────────────┼────────────┼─────────────────────────────────────────┤"
echo "  │ User       │ OP3        │ BTC (send), EVM (receive USDC)          │"
echo "  │ LP1        │ OP1        │ BTC (claim), M1 (lock), EVM (optional)  │"
echo "  │ LP2        │ CoreSDK    │ M1 (claim), EVM (lock USDC)             │"
echo "  └────────────┴────────────┴─────────────────────────────────────────┘"
echo ""
