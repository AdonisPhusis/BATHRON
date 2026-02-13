#!/usr/bin/env bash
# =============================================================================
# fix_wallet_import.sh - Import wallet keys + rescan on all VPS nodes
# =============================================================================
#
# PROBLEM: After genesis, wallets show M0=0 because:
#   1. genesis_bootstrap_seed.sh called "rescanwallet" (doesn't exist, should be "rescanblockchain")
#   2. Non-Seed nodes never imported their keys from ~/.BathronKey/wallet.json
#
# FIX: Import private key from ~/.BathronKey/wallet.json + rescanblockchain on each VPS
#
# Usage:
#   ./fix_wallet_import.sh          # Fix all nodes
#   ./fix_wallet_import.sh status   # Check wallet balances only
# =============================================================================

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

# All nodes: name|ip|cli_path
NODES=(
    "Seed (pilpous)|57.131.33.151|/home/ubuntu/BATHRON-Core/src/bathron-cli"
    "CoreSDK (bob)|162.19.251.75|/home/ubuntu/BATHRON-Core/src/bathron-cli"
    "OP1 (alice)|57.131.33.152|/home/ubuntu/bathron-cli"
    "OP2 (dev)|57.131.33.214|/home/ubuntu/bathron-cli"
    "OP3 (charlie)|51.75.31.44|/home/ubuntu/bathron-cli"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

show_status() {
    echo "=== Wallet Balances (all nodes) ==="
    echo ""
    for entry in "${NODES[@]}"; do
        IFS='|' read -r name ip cli <<< "$entry"
        echo -n "  $name: "
        BALANCE=$(ssh $SSH_OPTS ubuntu@$ip "$cli -testnet getbalance" 2>&1 || echo "ERROR")
        M0=$(echo "$BALANCE" | jq -r '.m0 // "?"' 2>/dev/null || echo "?")
        M1=$(echo "$BALANCE" | jq -r '.m1 // "?"' 2>/dev/null || echo "?")
        TOTAL=$(echo "$BALANCE" | jq -r '.total // "?"' 2>/dev/null || echo "?")
        echo -e "M0=${GREEN}$M0${NC}  M1=${GREEN}$M1${NC}  total=${TOTAL}"
    done
    echo ""

    echo "=== Global Settlement State ==="
    ssh $SSH_OPTS ubuntu@57.131.33.151 \
        "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getstate" 2>&1 \
        | jq '.supply' 2>/dev/null || echo "ERROR"
}

do_fix() {
    echo "=== Importing wallet keys + rescanblockchain on all nodes ==="
    echo ""

    for entry in "${NODES[@]}"; do
        IFS='|' read -r name ip cli <<< "$entry"
        echo -n "  $name ($ip): "

        RESULT=$(ssh $SSH_OPTS ubuntu@$ip "
            if [ -f ~/.BathronKey/wallet.json ]; then
                WIF=\$(jq -r '.wif' ~/.BathronKey/wallet.json 2>/dev/null)
                WNAME=\$(jq -r '.name' ~/.BathronKey/wallet.json 2>/dev/null)
                ADDR=\$(jq -r '.address' ~/.BathronKey/wallet.json 2>/dev/null)
                if [ -n \"\$WIF\" ] && [ \"\$WIF\" != 'null' ]; then
                    # Import key (rescan=false, we'll do a single rescan after)
                    $cli -testnet importprivkey \"\$WIF\" \"\$WNAME\" false 2>/dev/null && echo -n 'key_ok ' || echo -n 'key_exists '
                    # Rescan blockchain from block 0
                    $cli -testnet rescanblockchain 0 2>/dev/null && echo -n 'rescan_ok ' || echo -n 'rescan_fail '
                    # Show result
                    BAL=\$($cli -testnet getbalance 2>/dev/null | jq -r '.m0 // 0')
                    echo \"balance_m0=\$BAL wallet=\$WNAME addr=\$ADDR\"
                else
                    echo 'ERROR: no WIF in wallet.json'
                fi
            else
                echo 'ERROR: no ~/.BathronKey/wallet.json'
            fi
        " 2>&1)

        if echo "$RESULT" | grep -q "balance_m0=0"; then
            echo -e "${YELLOW}$RESULT${NC}"
        elif echo "$RESULT" | grep -q "ERROR"; then
            echo -e "${RED}$RESULT${NC}"
        else
            echo -e "${GREEN}$RESULT${NC}"
        fi
    done

    echo ""
    echo "=== Post-fix Status ==="
    show_status
}

case "${1:-fix}" in
    status)
        show_status
        ;;
    fix|"")
        do_fix
        ;;
    *)
        echo "Usage: $0 [fix|status]"
        exit 1
        ;;
esac
