#!/bin/bash
# =============================================================================
# execute_pna_swap.sh - Execute swap flow via pna-lp API
# =============================================================================
#
# Usage:
#   ./execute_pna_swap.sh status <swap_id>     - Get swap status
#   ./execute_pna_swap.sh send <swap_id>       - Send BTC deposit from OP3
#   ./execute_pna_swap.sh report <swap_id> <txid> - Report deposit
#   ./execute_pna_swap.sh confirm <swap_id>    - Confirm deposit
#   ./execute_pna_swap.sh settle <swap_id>     - Settle swap (send M1)
#   ./execute_pna_swap.sh full <swap_id>       - Execute full flow
#   ./execute_pna_swap.sh inventory            - Check LP inventory
#
# =============================================================================

set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# SSH configuration
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# Nodes
LP_API="http://57.131.33.152:8080"
OP3_IP="51.75.31.44"  # Fake user (charlie)
OP1_IP="57.131.33.152"  # LP

# CLI paths on VPS
BTC_CLI="~/bitcoin/bin/bitcoin-cli -signet -datadir=~/.bitcoin-signet"
BATHRON_CLI="~/bathron-cli -testnet"

get_swap_status() {
    local swap_id="$1"
    log_info "Getting status for swap: $swap_id"
    curl -s "$LP_API/api/swap/$swap_id" | jq '.'
}

check_inventory() {
    log_info "Refreshing LP inventory..."
    curl -s -X POST "$LP_API/api/lp/refresh" | jq '.'
    echo ""
    log_info "Current inventory:"
    curl -s "$LP_API/api/lp/config" | jq '.inventory'
}

send_btc_deposit() {
    local swap_id="$1"

    # Get swap details
    log_info "Getting swap details..."
    swap_data=$(curl -s "$LP_API/api/swap/$swap_id")

    deposit_addr=$(echo "$swap_data" | jq -r '.deposit_address')
    from_amount=$(echo "$swap_data" | jq -r '.from_amount')
    status=$(echo "$swap_data" | jq -r '.status')

    if [ "$status" != "pending_deposit" ]; then
        log_warn "Swap status is '$status', expected 'pending_deposit'"
        echo "$swap_data" | jq '.'
        return 1
    fi

    log_info "Deposit address: $deposit_addr"
    log_info "Amount to send: $from_amount BTC"

    # Check OP3 BTC balance first
    log_info "Checking OP3 BTC balance..."
    balance=$($SSH ubuntu@$OP3_IP "$BTC_CLI getbalance" 2>/dev/null)
    log_info "OP3 BTC balance: $balance BTC"

    if [ -z "$balance" ] || [ "$(echo "$balance < $from_amount" | bc -l)" -eq 1 ]; then
        log_error "Insufficient balance on OP3: $balance < $from_amount"
        log_info "Get signet BTC from: https://signetfaucet.com"
        return 1
    fi

    # Send BTC
    log_info "Sending $from_amount BTC to $deposit_addr..."
    txid=$($SSH ubuntu@$OP3_IP "$BTC_CLI sendtoaddress '$deposit_addr' $from_amount" 2>&1)

    if [[ "$txid" == *"error"* ]] || [[ "$txid" == *"Error"* ]]; then
        log_error "Failed to send BTC: $txid"
        return 1
    fi

    log_ok "BTC sent! TXID: $txid"
    echo "$txid"
}

report_deposit() {
    local swap_id="$1"
    local txid="$2"

    log_info "Reporting deposit: $txid"
    result=$(curl -s -X POST "$LP_API/api/swap/$swap_id/deposit?tx_hash=$txid")
    echo "$result" | jq '.'

    if echo "$result" | jq -e '.success' > /dev/null 2>&1; then
        log_ok "Deposit reported successfully"
    else
        log_error "Failed to report deposit"
        return 1
    fi
}

confirm_swap() {
    local swap_id="$1"

    # Wait for confirmation on Signet
    log_info "Waiting for BTC confirmation..."

    # Get the deposit tx
    swap_data=$(curl -s "$LP_API/api/swap/$swap_id")
    deposit_tx=$(echo "$swap_data" | jq -r '.deposit_tx')

    if [ "$deposit_tx" = "null" ] || [ -z "$deposit_tx" ]; then
        log_error "No deposit transaction found"
        return 1
    fi

    log_info "Checking confirmations for: $deposit_tx"

    # Check confirmations on LP's BTC node
    for i in {1..30}; do
        confs=$($SSH ubuntu@$OP1_IP "$BTC_CLI gettransaction '$deposit_tx' 2>/dev/null | jq -r '.confirmations'" 2>/dev/null || echo "0")

        if [ -z "$confs" ] || [ "$confs" = "null" ]; then
            confs="0"
        fi

        log_info "Confirmations: $confs (attempt $i/30)"

        if [ "$confs" -ge 1 ]; then
            log_ok "Transaction confirmed!"

            # Report confirmation
            result=$(curl -s -X POST "$LP_API/api/swap/$swap_id/confirm?confirmations=$confs")
            echo "$result" | jq '.'
            return 0
        fi

        log_info "Waiting 30s for confirmation..."
        sleep 30
    done

    log_warn "Timeout waiting for confirmation"
    log_info "You can manually confirm with: curl -X POST '$LP_API/api/swap/$swap_id/confirm?confirmations=1'"
    return 1
}

settle_swap() {
    local swap_id="$1"

    log_info "Settling swap: $swap_id"

    # First refresh inventory to ensure we have M1
    curl -s -X POST "$LP_API/api/lp/refresh" > /dev/null

    result=$(curl -s -X POST "$LP_API/api/swap/$swap_id/settle")
    echo "$result" | jq '.'

    if echo "$result" | jq -e '.success' > /dev/null 2>&1; then
        log_ok "Swap settled successfully!"
        claim_tx=$(echo "$result" | jq -r '.claim_tx')
        log_info "Claim TX: $claim_tx"
    else
        error=$(echo "$result" | jq -r '.detail // .error // "Unknown error"')
        log_error "Settlement failed: $error"
        return 1
    fi
}

full_flow() {
    local swap_id="$1"

    echo ""
    echo "=========================================="
    echo "  EXECUTING FULL SWAP FLOW"
    echo "  Swap ID: $swap_id"
    echo "=========================================="
    echo ""

    # Step 1: Get status
    get_swap_status "$swap_id"

    # Step 2: Send BTC
    echo ""
    log_info "=== Step 1: Send BTC deposit ==="
    txid=$(send_btc_deposit "$swap_id")

    if [ -z "$txid" ]; then
        log_error "Failed to send BTC"
        return 1
    fi

    # Step 3: Report deposit
    echo ""
    log_info "=== Step 2: Report deposit ==="
    report_deposit "$swap_id" "$txid"

    # Step 4: Wait for confirmation
    echo ""
    log_info "=== Step 3: Wait for confirmation ==="
    if ! confirm_swap "$swap_id"; then
        log_warn "Confirmation timeout - you may need to manually confirm"
        log_info "Command: curl -X POST '$LP_API/api/swap/$swap_id/confirm?confirmations=1'"
    fi

    # Step 5: Settle
    echo ""
    log_info "=== Step 4: Settle swap ==="
    settle_swap "$swap_id"

    echo ""
    echo "=========================================="
    echo "  SWAP COMPLETE"
    echo "=========================================="
    get_swap_status "$swap_id"
}

# Main
case "${1:-help}" in
    status)
        [ -z "$2" ] && { echo "Usage: $0 status <swap_id>"; exit 1; }
        get_swap_status "$2"
        ;;
    inventory)
        check_inventory
        ;;
    send)
        [ -z "$2" ] && { echo "Usage: $0 send <swap_id>"; exit 1; }
        send_btc_deposit "$2"
        ;;
    report)
        [ -z "$2" ] || [ -z "$3" ] && { echo "Usage: $0 report <swap_id> <txid>"; exit 1; }
        report_deposit "$2" "$3"
        ;;
    confirm)
        [ -z "$2" ] && { echo "Usage: $0 confirm <swap_id>"; exit 1; }
        confirm_swap "$2"
        ;;
    settle)
        [ -z "$2" ] && { echo "Usage: $0 settle <swap_id>"; exit 1; }
        settle_swap "$2"
        ;;
    full)
        [ -z "$2" ] && { echo "Usage: $0 full <swap_id>"; exit 1; }
        full_flow "$2"
        ;;
    *)
        echo "Usage: $0 {status|inventory|send|report|confirm|settle|full} [swap_id] [txid]"
        echo ""
        echo "Commands:"
        echo "  status <swap_id>          - Get swap status"
        echo "  inventory                 - Check LP inventory"
        echo "  send <swap_id>            - Send BTC deposit from OP3"
        echo "  report <swap_id> <txid>   - Report deposit transaction"
        echo "  confirm <swap_id>         - Wait for and confirm deposit"
        echo "  settle <swap_id>          - Execute M1 settlement"
        echo "  full <swap_id>            - Execute full flow"
        exit 1
        ;;
esac
