#!/bin/bash
# =============================================================================
# setup_test_wallets.sh - Import test wallet keys and check/claim burns
# =============================================================================

set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# SSH config
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# Nodes
SEED_IP="57.131.33.151"
OP1_IP="57.131.33.152"
CORESDK_IP="162.19.251.75"
OP2_IP="57.131.33.214"
OP3_IP="51.75.31.44"

# CLI paths (repo nodes have different path)
# Repo nodes: 57.131.33.151 (Seed), 162.19.251.75 (CoreSDK)
# OP2: custom binary path
# Bin nodes: others
get_cli() {
    local ip=$1
    if [ "$ip" = "$SEED_IP" ] || [ "$ip" = "$CORESDK_IP" ]; then
        echo "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
    elif [ "$ip" = "$OP2_IP" ]; then
        echo "/home/ubuntu/bathron/bin/bathron-cli -testnet"
    else
        echo "/home/ubuntu/bathron-cli -testnet"
    fi
}

# Test user keys (from ~/.BathronKey/testnet_keys.json)
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
ALICE_WIF="cTuaDJPC5HvAYD4XzFxWUszUDfVeSmaN47N6qvCxnpaucgeYzxb2"

BOB_ADDR="y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk"
BOB_WIF="cNNCM6nSmDydVCL3zqdDzUS44tJ9LGMDck1A22fvKrrUgsYS4eMm"

CHARLIE_ADDR="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"
CHARLIE_WIF="cPtPSZLkcufXMryYoCTr63zkPDGPtYWxbZ24NGBWzDfzJUuZaEbE"

PILPOUS_ADDR="xyszqryssGaNw13qpjbxB4PVoRqGat7RPd"
PILPOUS_WIF="cQvp6t3Jz8MQ5FJEVM4ewucabskCfyhy73N1eP9c82xGxgEA71CX"

DEV_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"
DEV_WIF="cSNJfpBoKt43ojNuvG7TjkxsUiTdXy6HihcKxBewNgk5jALCXYaa"

# FIXED: Import only the LOCAL node's key (not all 5!)
# Old import_keys() imported ALL 5 WIFs on every node, creating shared wallets.
# Each node must have ONLY its own key for proper wallet isolation.
import_local_key() {
    local IP=$1
    local NAME=$2
    local WIF=$3
    local LABEL=$4
    local CLI=$(get_cli $IP)

    log_step "Importing $LABEL key on $NAME ($IP)"

    $SSH ubuntu@$IP "
        CLI='$CLI'
        echo 'Importing $LABEL...'
        \$CLI importprivkey '$WIF' '$LABEL' true 2>/dev/null || echo '  (already imported or error)'
        echo 'Rescan complete.'
    "

    log_ok "$LABEL key imported on $NAME"
}

check_balances() {
    local IP=$1
    local NAME=$2
    local CLI=$(get_cli $IP)

    log_step "Checking balances on $NAME ($IP)"

    $SSH ubuntu@$IP "
        CLI='$CLI'

        echo 'Total wallet balance:'
        \$CLI getbalance 2>/dev/null || echo 'error'

        echo ''
        echo 'Address balances:'
        for ADDR in '$ALICE_ADDR' '$BOB_ADDR' '$PILPOUS_ADDR' '$DEV_ADDR'; do
            BAL=\$(\$CLI getreceivedbyaddress \"\$ADDR\" 0 2>/dev/null || echo '0')
            echo \"  \$ADDR: \$BAL\"
        done

        echo ''
        echo 'Wallet state (M0/M1):'
        \$CLI getwalletstate true 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(f\"  M0 balance: {d.get(\"m0_balance\", 0)}\")
    receipts = d.get(\"m1_receipts\", [])
    total_m1 = sum(r.get(\"amount\", 0) for r in receipts)
    print(f\"  M1 receipts: {len(receipts)}, total: {total_m1}\")
except Exception as e:
    print(f\"  Error: {e}\")
'
    "
}

check_burn_status() {
    local IP=$1
    local CLI=$(get_cli $IP)

    log_step "Checking burn claim status on $IP"

    $SSH ubuntu@$IP "
        CLI='$CLI'

        echo 'BTC headers status:'
        \$CLI getbtcheadersstatus 2>&1 | head -5

        echo ''
        echo 'Network state:'
        \$CLI getstate 2>&1 | head -15

        echo ''
        echo 'Block count:'
        \$CLI getblockcount 2>&1
    "
}

check_burn_daemon() {
    log_step "Checking burn daemon on Seed"

    $SSH ubuntu@$SEED_IP "
        if pgrep -f 'btc_burn_claim_daemon' > /dev/null; then
            echo 'Burn daemon: RUNNING'
            ps aux | grep burn_claim | grep -v grep | head -1
        else
            echo 'Burn daemon: NOT RUNNING'
        fi

        echo ''
        echo 'Recent burn daemon logs:'
        tail -20 ~/burn_daemon.log 2>/dev/null || echo '(no logs)'
    "
}

start_burn_daemon() {
    log_step "Starting burn daemon on Seed"

    $SSH ubuntu@$SEED_IP "
        if pgrep -f 'btc_burn_claim_daemon' > /dev/null; then
            echo 'Burn daemon already running'
        else
            echo 'Starting burn daemon...'
            cd ~ && nohup ./btc_burn_claim_daemon.sh > burn_daemon.log 2>&1 &
            sleep 3
            if pgrep -f 'btc_burn_claim_daemon' > /dev/null; then
                echo 'Burn daemon started'
            else
                echo 'Failed to start burn daemon'
            fi
        fi
    "
}

fund_from_dev() {
    local TO_ADDR=$1
    local AMOUNT=$2
    local IP=$SEED_IP
    local CLI=$(get_cli $IP)

    log_step "Sending $AMOUNT from dev to $TO_ADDR"

    $SSH ubuntu@$IP "
        CLI='$CLI'

        # Check dev balance first
        DEV_BAL=\$(\$CLI getreceivedbyaddress '$DEV_ADDR' 0 2>/dev/null || echo '0')
        echo \"Dev wallet balance: \$DEV_BAL\"

        if [ \"\$DEV_BAL\" = \"0\" ] || [ \"\$DEV_BAL\" = \"0.00000000\" ]; then
            echo 'Dev wallet has no funds!'
            exit 1
        fi

        # Send
        TXID=\$(\$CLI sendmany '' '{\"$TO_ADDR\": $AMOUNT}' 2>&1)
        echo \"TX: \$TXID\"
    "
}

lock_m1() {
    local AMOUNT="${1:-10000}"
    local IP=$SEED_IP
    local CLI=$(get_cli $IP)

    log_step "Locking $AMOUNT M0 -> M1"

    $SSH ubuntu@$IP "
        CLI='$CLI'

        echo 'Current M1 receipts:'
        \$CLI getwalletstate true 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
receipts = d.get(\"m1_receipts\", [])
print(f\"  Count: {len(receipts)}\")
for r in receipts[:5]:
    print(f\"    {r.get(\"outpoint\")}: {r.get(\"amount\")} M1\")
'

        echo ''
        echo 'Locking $AMOUNT M0...'
        RESULT=\$(\$CLI lock $AMOUNT 2>&1)
        echo \"\$RESULT\"
    "
}

send_m0() {
    local FROM=$1
    local TO=$2
    local AMOUNT=$3
    local IP=$SEED_IP
    local CLI=$(get_cli $IP)

    log_step "Sending $AMOUNT M0 from $FROM to $TO"

    $SSH ubuntu@$IP "
        CLI='$CLI'
        \$CLI sendmany '' '{\"$TO\": $AMOUNT}' 2>&1
    "
}

htlc_test() {
    local IP=$SEED_IP
    local CLI=$(get_cli $IP)

    log_step "Full HTLC Test"

    $SSH ubuntu@$IP "
        CLI='$CLI'

        echo '=== Step 1: Check M1 receipts ==='
        echo 'Raw getwalletstate output:'
        \$CLI getwalletstate true 2>/dev/null | head -50
        echo ''

        # Try to find M1 receipts in various formats
        RECEIPT=\$(\$CLI getwalletstate true 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    # Try different possible keys
    receipts = d.get(\"m1_receipts\", d.get(\"receipts\", d.get(\"m1\", [])))
    if isinstance(receipts, list) and receipts:
        r = receipts[0]
        outpoint = r.get(\"outpoint\", r.get(\"txid\", \"\"))
        if outpoint:
            print(outpoint)
        else:
            print(\"\")
    else:
        print(\"\")
except Exception as e:
    print(\"\", file=sys.stderr)
    print(f\"Parse error: {e}\", file=sys.stderr)
')

        if [ -z \"\$RECEIPT\" ]; then
            echo 'No M1 receipts found. Locking 10000 M0...'
            LOCK=\$(\$CLI lock 10000 2>&1)
            echo \"\$LOCK\"

            # Get receipt directly from lock result
            RECEIPT=\$(echo \"\$LOCK\" | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"receipt_outpoint\",\"\"))' 2>/dev/null)

            if [ -n \"\$RECEIPT\" ]; then
                echo \"Got receipt from lock result: \$RECEIPT\"
                echo 'Waiting for confirmation (65s)...'
                sleep 65
            else
                echo 'ERROR: Could not get receipt from lock!'
                exit 1
            fi
        fi

        if [ -z \"\$RECEIPT\" ]; then
            echo 'ERROR: Still no M1 receipt!'
            exit 1
        fi

        echo \"Using receipt: \$RECEIPT\"

        echo ''
        echo '=== Step 2: Generate secret/hashlock ==='
        SECRET_DATA=\$(\$CLI htlc_generate 2>&1)
        echo \"\$SECRET_DATA\"
        SECRET=\$(echo \"\$SECRET_DATA\" | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"secret\"])')
        HASHLOCK=\$(echo \"\$SECRET_DATA\" | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"hashlock\"])')

        echo ''
        echo '=== Step 3: Create HTLC ==='
        # Use a wallet address for claim so we can claim it
        CLAIM_ADDR=\$(\$CLI getnewaddress 'htlc_test_claim' 2>/dev/null)
        echo \"Claim address: \$CLAIM_ADDR\"
        HTLC=\$(\$CLI htlc_create_m1 \"\$RECEIPT\" \"\$HASHLOCK\" \"\$CLAIM_ADDR\" 2>&1)
        echo \"\$HTLC\"
        HTLC_TXID=\$(echo \"\$HTLC\" | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"txid\",\"\"))' 2>/dev/null)

        if [ -z \"\$HTLC_TXID\" ]; then
            echo 'ERROR: HTLC creation failed'
            exit 1
        fi

        echo 'Waiting for HTLC confirmation (65s)...'
        sleep 65

        echo ''
        echo '=== Step 4: Verify HTLC ==='
        HTLC_DATA=\$(\$CLI htlc_get \"\${HTLC_TXID}:0\" 2>&1)
        echo \"\$HTLC_DATA\"

        echo ''
        echo '=== Step 5: Claim HTLC ==='
        CLAIM=\$(\$CLI htlc_claim \"\${HTLC_TXID}:0\" \"\$SECRET\" 2>&1)
        echo \"\$CLAIM\"

        echo ''
        echo '=== DONE ==='
    "
}

case "${1:-help}" in
    import)
        # 1 key per node — NEVER import all keys on same node
        import_local_key "$SEED_IP" "Seed" "$PILPOUS_WIF" "pilpous"
        import_local_key "$CORESDK_IP" "CoreSDK" "$BOB_WIF" "bob"
        import_local_key "$OP1_IP" "OP1" "$ALICE_WIF" "alice"
        import_local_key "$OP2_IP" "OP2" "$DEV_WIF" "dev"
        import_local_key "$OP3_IP" "OP3" "$CHARLIE_WIF" "charlie"
        ;;

    balance|balances)
        check_balances "$SEED_IP" "Seed"
        ;;

    status)
        check_burn_status "$SEED_IP"
        check_balances "$SEED_IP" "Seed"
        ;;

    burn-daemon)
        check_burn_daemon
        ;;

    start-burn)
        start_burn_daemon
        ;;

    fund)
        TO="${2:-$ALICE_ADDR}"
        AMOUNT="${3:-10000}"
        fund_from_dev "$TO" "$AMOUNT"
        ;;

    lock)
        AMOUNT="${2:-10000}"
        lock_m1 "$AMOUNT"
        ;;

    send)
        FROM="${2:-$ALICE_ADDR}"
        TO="${3:-$BOB_ADDR}"
        AMOUNT="${4:-1000}"
        send_m0 "$FROM" "$TO" "$AMOUNT"
        ;;

    htlc)
        htlc_test
        ;;

    all)
        import_local_key "$SEED_IP" "Seed" "$PILPOUS_WIF" "pilpous"
        import_local_key "$CORESDK_IP" "CoreSDK" "$BOB_WIF" "bob"
        import_local_key "$OP1_IP" "OP1" "$ALICE_WIF" "alice"
        import_local_key "$OP2_IP" "OP2" "$DEV_WIF" "dev"
        import_local_key "$OP3_IP" "OP3" "$CHARLIE_WIF" "charlie"
        check_burn_status "$SEED_IP"
        check_balances "$SEED_IP" "Seed"
        check_burn_daemon
        ;;

    *)
        echo "Usage: $0 {import|balance|status|burn-daemon|start-burn|fund|lock|send|htlc|all}"
        echo ""
        echo "Commands:"
        echo "  import      - Import 1 key per node (isolated wallets)"
        echo "  balance     - Check wallet balances"
        echo "  status      - Check burn/network status"
        echo "  burn-daemon - Check burn claim daemon status"
        echo "  start-burn  - Start burn claim daemon"
        echo "  fund        - Send from dev wallet to address"
        echo "  lock [amt]  - Lock M0 -> M1"
        echo "  send        - Send M0 between addresses"
        echo "  htlc        - Full HTLC test cycle"
        echo "  all         - Run all checks"
        ;;
esac
