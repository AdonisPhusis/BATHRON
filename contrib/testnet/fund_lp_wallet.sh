#!/bin/bash
# =============================================================================
# fund_lp_wallet.sh - Fund LP wallet with M1 from testnet
# =============================================================================

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# Nodes
SEED_IP="57.131.33.151"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"

# LP address (alice on OP1)
LP_M1_ADDRESS="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
AMOUNT="${1:-1000}"  # Default 1000 M0 to LP

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_balance() {
    local ip=$1
    local name=$2

    echo -e "\n${BLUE}=== $name ($ip) ===${NC}"

    # Get balance
    balance=$($SSH ubuntu@$ip "~/bathron-cli -testnet getbalance 2>/dev/null || echo 'error'")
    if [[ "$balance" == "error" ]]; then
        log_error "Cannot connect to $name"
        return 1
    fi

    echo "Balance: $balance M0"

    # Get state
    state=$($SSH ubuntu@$ip "~/bathron-cli -testnet getstate 2>/dev/null | head -10" || echo "{}")
    echo "$state"
}

fund_lp() {
    local from_ip=$1
    local from_name=$2
    local amount=$3

    log_info "Sending $amount M0 from $from_name to LP ($LP_M1_ADDRESS)"

    # BATHRON uses sendmany, not sendtoaddress
    # Format: sendmany "from_account" {"address":amount}
    json_outputs="{\"$LP_M1_ADDRESS\":$amount}"

    result=$($SSH ubuntu@$from_ip "~/bathron-cli -testnet sendmany '' '$json_outputs' 2>&1")

    if [[ "$result" == *"error"* ]] || [[ "$result" == *"Error"* ]]; then
        log_error "Send failed: $result"
        return 1
    fi

    log_ok "TX sent: $result"
    return 0
}

check_wallet_state() {
    local ip=$1
    local name=$2

    echo -e "\n${BLUE}=== $name ($ip) Wallet State ===${NC}"
    $SSH ubuntu@$ip "~/bathron-cli -testnet getwalletstate true 2>&1" || echo "error"
}

case "${1:-check}" in
    check)
        log_info "Checking wallet balances on all nodes..."
        check_balance "$SEED_IP" "Seed"
        check_balance "$OP1_IP" "OP1"
        check_balance "$OP2_IP" "OP2"
        ;;

    state)
        ip="${2:-$OP1_IP}"
        check_wallet_state "$ip" "$ip"
        ;;

    test-htlc)
        ip="${2:-$OP1_IP}"
        log_info "Full HTLC cycle test on $ip"

        echo "=== Step 1: Lock M0 -> M1 ==="
        lock_result=$($SSH ubuntu@$ip '~/bathron-cli -testnet lock 1000 2>&1')
        echo "$lock_result"
        lock_txid=$(echo "$lock_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null)

        if [ -z "$lock_txid" ]; then
            echo "ERROR: Lock failed"
            exit 1
        fi
        echo "Lock txid: $lock_txid"

        echo ""
        echo "=== Step 2: Wait for confirmation (65s) ==="
        sleep 65

        echo ""
        echo "=== Step 3: Check M1 receipts ==="
        $SSH ubuntu@$ip '~/bathron-cli -testnet getwalletstate true 2>&1' | head -30

        # Get receipt outpoint (receipt is at vout[1], vault is at vout[0])
        receipt_outpoint="${lock_txid}:1"
        echo "Receipt outpoint: $receipt_outpoint"

        echo ""
        echo "=== Step 4: Generate secret/hashlock ==="
        secret_data=$($SSH ubuntu@$ip '~/bathron-cli -testnet htlc_generate 2>&1')
        echo "$secret_data"
        secret=$(echo "$secret_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['secret'])")
        hashlock=$(echo "$secret_data" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['hashlock'])")
        echo "Secret: $secret"
        echo "Hashlock: $hashlock"

        echo ""
        echo "=== Step 5: Create HTLC ==="
        htlc_result=$($SSH ubuntu@$ip "~/bathron-cli -testnet htlc_create_m1 '$receipt_outpoint' '$hashlock' 'y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk' 2>&1")
        echo "$htlc_result"
        htlc_txid=$(echo "$htlc_result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null)

        if [ -z "$htlc_txid" ]; then
            echo "ERROR: HTLC creation failed"
            exit 1
        fi

        echo ""
        echo "=== Step 6: Wait for HTLC confirmation (65s) ==="
        sleep 65

        echo ""
        echo "=== Step 7: Verify hashlock stored correctly ==="
        htlc_data=$($SSH ubuntu@$ip "~/bathron-cli -testnet htlc_get '${htlc_txid}:0' 2>&1")
        echo "$htlc_data"
        stored_hashlock=$(echo "$htlc_data" | python3 -c "import sys,json; print(json.load(sys.stdin).get('hashlock',''))" 2>/dev/null)

        if [ "$stored_hashlock" = "0000000000000000000000000000000000000000000000000000000000000000" ]; then
            echo "ERROR: Hashlock is still null! Bug not fixed."
            exit 1
        fi

        if [ "$stored_hashlock" = "$hashlock" ]; then
            echo "✓ Hashlock stored correctly: $stored_hashlock"
        else
            echo "WARNING: Stored hashlock differs: $stored_hashlock vs $hashlock"
        fi

        echo ""
        echo "=== Step 8: Claim HTLC with preimage ==="
        claim_result=$($SSH ubuntu@$ip "~/bathron-cli -testnet htlc_claim '${htlc_txid}:0' '$secret' 2>&1")
        echo "$claim_result"

        if echo "$claim_result" | grep -q "txid"; then
            echo ""
            echo "✓✓✓ HTLC CYCLE COMPLETE - ALL TESTS PASSED! ✓✓✓"
        else
            echo ""
            echo "ERROR: Claim failed"
            exit 1
        fi
        ;;

    fund)
        amount="${2:-1000}"
        log_info "Funding LP wallet with $amount M0..."

        # Try Seed first
        if fund_lp "$SEED_IP" "Seed" "$amount"; then
            log_ok "LP funded from Seed"
        else
            # Try OP2
            if fund_lp "$OP2_IP" "OP2" "$amount"; then
                log_ok "LP funded from OP2"
            else
                log_error "Could not fund LP from any node"
                exit 1
            fi
        fi
        ;;

    send)
        from_ip="${2:-$SEED_IP}"
        amount="${3:-1000}"
        log_info "Sending $amount M0 from $from_ip to LP"
        fund_lp "$from_ip" "$from_ip" "$amount"
        ;;

    create-m1)
        # Create M1 on OP1 by locking M0
        amount="${2:-100000}"
        log_info "Creating $amount M1 on OP1 (LP) by locking M0..."

        # Check M0 balance first
        balance=$($SSH ubuntu@$OP1_IP "~/bathron-cli -testnet getbalance 2>/dev/null || echo '0'")
        log_info "OP1 M0 balance: $balance"

        if [ "$(echo "$balance < $amount" | bc -l 2>/dev/null || echo 1)" -eq 1 ]; then
            log_warn "Insufficient M0 on OP1. Sending from Seed..."
            fund_lp "$SEED_IP" "Seed" "$amount"
            log_info "Waiting for confirmation (65s)..."
            sleep 65
        fi

        # Lock M0 -> M1
        log_info "Locking $amount M0 -> M1..."
        result=$($SSH ubuntu@$OP1_IP "~/bathron-cli -testnet lock $amount 2>&1")
        echo "$result"

        if echo "$result" | grep -q "txid"; then
            log_ok "M1 created! Wait for confirmation."
            log_info "Run 'fund_lp_wallet.sh state' to check receipts"
        else
            log_error "Lock failed: $result"
            exit 1
        fi
        ;;

    *)
        echo "Usage: $0 {check|state|fund [amount]|send <ip> <amount>|create-m1 [amount]|test-htlc}"
        echo ""
        echo "Commands:"
        echo "  check              - Check balances on all nodes"
        echo "  state [ip]         - Show wallet state (M1 receipts)"
        echo "  fund [amount]      - Send M0 to LP from Seed/OP2"
        echo "  create-m1 [amount] - Lock M0->M1 on OP1 (creates liquidity)"
        echo "  test-htlc          - Full HTLC cycle test"
        exit 1
        ;;
esac
