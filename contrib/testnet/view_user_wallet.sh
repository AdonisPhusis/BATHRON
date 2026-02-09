#!/bin/bash
# View all wallet balances for fake user on OP3
# Shows: M0, M1, BTC (Signet), ETH (Base Sepolia), USDC (Base Sepolia)

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP3_IP="51.75.31.44"

# Base Sepolia config
BASE_RPC="https://sepolia.base.org"
USDC_CONTRACT="0x036CbD53842c5426634e7929541eC2318f3dCF7e"  # Circle USDC on Base Sepolia

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           FAKE USER WALLET VIEWER (OP3)                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  charlie @ 51.75.31.44                                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────────────
# BATHRON (M0 + M1)
# ─────────────────────────────────────────────────────────────────────
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  BATHRON (M0 + M1)                                           │"
echo "└──────────────────────────────────────────────────────────────┘"

BATHRON_DATA=$(ssh $SSH_OPTS ubuntu@$OP3_IP '
CLI="$HOME/bathron-cli"
if [ ! -f "$CLI" ]; then
    CLI="$HOME/BATHRON-Core/src/bathron-cli"
fi

M0=$($CLI -testnet getbalance 2>/dev/null || echo "ERROR")
M1=$($CLI -testnet getbalance "*" 0 false "M1" 2>/dev/null || echo "ERROR")
ADDR=$($CLI -testnet getaccountaddress "" 2>/dev/null || echo "N/A")

echo "M0:$M0"
echo "M1:$M1"
echo "ADDR:$ADDR"
' 2>/dev/null || echo "M0:ERROR
M1:ERROR
ADDR:ERROR")

M0_BAL=$(echo "$BATHRON_DATA" | grep "^M0:" | cut -d: -f2)
M1_BAL=$(echo "$BATHRON_DATA" | grep "^M1:" | cut -d: -f2)
BATH_ADDR=$(echo "$BATHRON_DATA" | grep "^ADDR:" | cut -d: -f2)

printf "  Address:  %s\n" "$BATH_ADDR"
printf "  M0:       %s\n" "$M0_BAL"
printf "  M1:       %s\n" "$M1_BAL"
echo ""

# ─────────────────────────────────────────────────────────────────────
# BITCOIN (Signet)
# ─────────────────────────────────────────────────────────────────────
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  BITCOIN (Signet)                                            │"
echo "└──────────────────────────────────────────────────────────────┘"

BTC_DATA=$(ssh $SSH_OPTS ubuntu@$OP3_IP '
BTC_CLI="$HOME/bitcoin/bin/bitcoin-cli -signet -datadir=$HOME/.bitcoin-signet"

# Check if bitcoind is running
if ! $BTC_CLI getblockcount &>/dev/null; then
    echo "BTC:NOT_RUNNING"
    echo "ADDR:N/A"
    exit 0
fi

BAL=$($BTC_CLI getbalance 2>/dev/null || echo "0")
ADDR=$($BTC_CLI -rpcwallet=fake_user getnewaddress 2>/dev/null || $BTC_CLI getnewaddress 2>/dev/null || echo "N/A")

echo "BTC:$BAL"
echo "ADDR:$ADDR"
' 2>/dev/null || echo "BTC:ERROR
ADDR:ERROR")

BTC_BAL=$(echo "$BTC_DATA" | grep "^BTC:" | cut -d: -f2)
BTC_ADDR=$(echo "$BTC_DATA" | grep "^ADDR:" | cut -d: -f2)

if [ "$BTC_BAL" == "NOT_RUNNING" ]; then
    printf "  Status:   bitcoind not running\n"
else
    printf "  Address:  %s\n" "$BTC_ADDR"
    printf "  Balance:  %s BTC\n" "$BTC_BAL"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# EVM (Base Sepolia - ETH + USDC)
# ─────────────────────────────────────────────────────────────────────
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  EVM - Base Sepolia (ETH + USDC)                             │"
echo "└──────────────────────────────────────────────────────────────┘"

# Get EVM address from OP3
EVM_ADDR=$(ssh $SSH_OPTS ubuntu@$OP3_IP 'cat ~/.keys/user_evm.json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get(\"address\", \"N/A\"))" 2>/dev/null || echo "NOT_FOUND"')

if [ "$EVM_ADDR" == "NOT_FOUND" ] || [ -z "$EVM_ADDR" ]; then
    printf "  Status:   EVM wallet not configured\n"
    printf "  Run:      ./contrib/testnet/create_user_evm_wallet.sh\n"
else
    printf "  Address:  %s\n" "$EVM_ADDR"

    # Get ETH balance
    ETH_HEX=$(curl -s -X POST "$BASE_RPC" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$EVM_ADDR\",\"latest\"],\"id\":1}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('result', '0x0'))" 2>/dev/null || echo "0x0")

    ETH_WEI=$(python3 -c "print(int('$ETH_HEX', 16))" 2>/dev/null || echo "0")
    ETH_BAL=$(python3 -c "print(f'{int(\"$ETH_HEX\", 16) / 1e18:.6f}')" 2>/dev/null || echo "0.000000")

    printf "  ETH:      %s\n" "$ETH_BAL"

    # Get USDC balance (ERC20 balanceOf)
    # balanceOf(address) = 0x70a08231 + address padded to 32 bytes
    ADDR_PADDED=$(echo "$EVM_ADDR" | sed 's/0x//' | tr '[:upper:]' '[:lower:]')
    CALL_DATA="0x70a08231000000000000000000000000${ADDR_PADDED}"

    USDC_HEX=$(curl -s -X POST "$BASE_RPC" \
        -H "Content-Type: application/json" \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$USDC_CONTRACT\",\"data\":\"$CALL_DATA\"},\"latest\"],\"id\":1}" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('result', '0x0'))" 2>/dev/null || echo "0x0")

    # USDC has 6 decimals
    USDC_BAL=$(python3 -c "print(f'{int(\"$USDC_HEX\", 16) / 1e6:.2f}')" 2>/dev/null || echo "0.00")

    printf "  USDC:     %s\n" "$USDC_BAL"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  SUMMARY                                                     │"
echo "└──────────────────────────────────────────────────────────────┘"
printf "  %-10s %s\n" "M0:" "$M0_BAL"
printf "  %-10s %s\n" "M1:" "$M1_BAL"
printf "  %-10s %s BTC\n" "BTC:" "$BTC_BAL"
if [ "$EVM_ADDR" != "NOT_FOUND" ] && [ -n "$EVM_ADDR" ]; then
    printf "  %-10s %s ETH\n" "ETH:" "$ETH_BAL"
    printf "  %-10s %s USDC\n" "USDC:" "$USDC_BAL"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────
# Faucets
# ─────────────────────────────────────────────────────────────────────
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│  FAUCETS                                                     │"
echo "└──────────────────────────────────────────────────────────────┘"
echo "  BTC Signet:  https://signetfaucet.com"
echo "  ETH Base:    https://www.alchemy.com/faucets/base-sepolia"
echo "  USDC Base:   https://faucet.circle.com/"
echo ""
