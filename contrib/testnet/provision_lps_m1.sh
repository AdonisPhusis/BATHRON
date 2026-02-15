#!/bin/bash
# ==============================================================================
# provision_lps_m1.sh - Provision M1 to LP nodes (OP1-alice, OP2-dev)
# ==============================================================================
# Usage:
#   ./provision_lps_m1.sh          # Lock M0→M1 on each LP
#   ./provision_lps_m1.sh status   # Check M0/M1 balances on all nodes
#   ./provision_lps_m1.sh refresh  # Trigger inventory refresh on LP servers
# ==============================================================================

set -uo pipefail

SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Node map
SEED_IP="57.131.33.151"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"
OP3_IP="51.75.31.44"

CLI="/home/ubuntu/bathron-cli -testnet"

# Addresses
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
DEV_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"
CHARLIE_ADDR="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"

FEE_BUFFER=2000  # sats kept as M0 for future TX fees

CMD="${1:-provision}"

# ---------------------------------------------------------------------------
# Helper: lock M0→M1 on a node (all amounts in sats)
# ---------------------------------------------------------------------------
lock_m0_to_m1() {
    local IP="$1"
    local NAME="$2"

    echo "--- $NAME ($IP) ---"

    # Get current balance (sats)
    WALLET_STATE=$($SSH ubuntu@$IP "$CLI getwalletstate true 2>&1" 2>/dev/null)
    M0=$(echo "$WALLET_STATE" | jq -r '.m0.balance // 0')
    M1=$(echo "$WALLET_STATE" | jq -r '.m1.total // 0')
    M1_COUNT=$(echo "$WALLET_STATE" | jq -r '.m1.count // 0')
    echo "  Current: M0=${M0} sats  M1=${M1} sats ($M1_COUNT receipts)"

    # Calculate lock amount (M0 - fee buffer)
    LOCK_AMT=$((M0 - FEE_BUFFER))
    if [ "$LOCK_AMT" -le 1000 ] 2>/dev/null; then
        echo "  SKIP: Not enough M0 to lock (M0=$M0, buffer=$FEE_BUFFER)"
        return 0
    fi
    echo "  Locking: $LOCK_AMT sats M0 → M1 (keeping $FEE_BUFFER for fees)"

    # Lock
    LOCK_RESULT=$($SSH ubuntu@$IP "$CLI lock $LOCK_AMT 2>&1" 2>/dev/null)
    LOCK_TXID=$(echo "$LOCK_RESULT" | jq -r '.txid // empty' 2>/dev/null)
    if [ -z "$LOCK_TXID" ]; then
        echo "  ERROR: Lock failed: $LOCK_RESULT"
        return 1
    fi
    echo "  Lock TX: $LOCK_TXID"

    # Wait for confirmation
    echo "  Waiting for confirmation..."
    CONFS=0
    for i in $(seq 1 30); do
        sleep 5
        CONFS=$($SSH ubuntu@$IP "$CLI getrawtransaction $LOCK_TXID true 2>/dev/null | jq -r '.confirmations // 0'" 2>/dev/null)
        if [ "$CONFS" -gt 0 ] 2>/dev/null; then
            echo "  Confirmed ($CONFS confs) after $((i*5))s"
            break
        fi
        [ $((i % 6)) -eq 0 ] && echo "  ... still waiting ($((i*5))s)"
    done

    if ! [ "$CONFS" -gt 0 ] 2>/dev/null; then
        echo "  WARNING: TX not confirmed after 150s"
        return 1
    fi

    # Show final state
    WALLET_STATE=$($SSH ubuntu@$IP "$CLI getwalletstate true 2>&1" 2>/dev/null)
    M0=$(echo "$WALLET_STATE" | jq -r '.m0.balance // 0')
    M1=$(echo "$WALLET_STATE" | jq -r '.m1.total // 0')
    M1_COUNT=$(echo "$WALLET_STATE" | jq -r '.m1.count // 0')
    echo "  Result: M0=${M0} sats  M1=${M1} sats ($M1_COUNT receipts)"
    echo ""
}

case "$CMD" in
status)
    echo "=== M0/M1 Balances (all nodes, in sats) ==="
    for NODE in "$SEED_IP:Seed" "$OP1_IP:OP1-alice" "$OP2_IP:OP2-dev" "$OP3_IP:OP3-charlie"; do
        IP="${NODE%%:*}"
        NAME="${NODE##*:}"
        WALLET=$($SSH ubuntu@$IP "$CLI getwalletstate true 2>&1" 2>/dev/null)
        M0=$(echo "$WALLET" | jq -r '.m0.balance // "?"')
        M1=$(echo "$WALLET" | jq -r '.m1.total // "?"')
        M1_COUNT=$(echo "$WALLET" | jq -r '.m1.count // 0')
        echo "  $NAME ($IP): M0=${M0}  M1=${M1} ($M1_COUNT receipts)"
    done
    ;;

provision)
    echo "=== Provision M1 to LP nodes ==="
    echo ""

    # Step 1: Check if OP2 needs M0 sent from Seed
    echo "[1/3] Checking if OP2 (dev) needs M0..."
    OP2_BAL=$($SSH ubuntu@$OP2_IP "$CLI getwalletstate true 2>&1" 2>/dev/null)
    OP2_M0=$(echo "$OP2_BAL" | jq -r '.m0.balance // 0')
    OP2_M1=$(echo "$OP2_BAL" | jq -r '.m1.total // 0')
    echo "  OP2 current: M0=${OP2_M0} sats  M1=${OP2_M1} sats"

    if [ "$OP2_M0" -lt 5000 ] 2>/dev/null && [ "$OP2_M1" -lt 5000 ] 2>/dev/null; then
        echo "  OP2 needs M0. Sending from Seed..."

        # Get Seed's available M0
        SEED_BAL=$($SSH ubuntu@$SEED_IP "$CLI getwalletstate true 2>&1" 2>/dev/null)
        SEED_M0=$(echo "$SEED_BAL" | jq -r '.m0.balance // 0')
        echo "  Seed M0: ${SEED_M0} sats"

        # Send 1/4 of Seed's M0 to OP2 (keep most for MN collateral)
        SEND_AMT=$((SEED_M0 / 4))
        if [ "$SEND_AMT" -gt 1000 ] 2>/dev/null; then
            echo "  Sending $SEND_AMT sats to $DEV_ADDR..."
            SEND_RESULT=$($SSH ubuntu@$SEED_IP "$CLI sendmany '' '{\"$DEV_ADDR\":$SEND_AMT}' 2>&1" 2>/dev/null)
            echo "  TX: $SEND_RESULT"

            # Wait for confirmation
            echo "  Waiting for confirmation..."
            for i in $(seq 1 30); do
                sleep 5
                CONFS=$($SSH ubuntu@$OP2_IP "$CLI getrawtransaction $SEND_RESULT true 2>/dev/null | jq -r '.confirmations // 0'" 2>/dev/null)
                if [ "$CONFS" -gt 0 ] 2>/dev/null; then
                    echo "  Confirmed after $((i*5))s"
                    break
                fi
                [ $((i % 6)) -eq 0 ] && echo "  ... waiting ($((i*5))s)"
            done
        else
            echo "  WARNING: Seed has insufficient M0 (${SEED_M0} sats)"
        fi
    else
        echo "  OP2 already has funds, skipping transfer"
    fi
    echo ""

    # Step 2: Lock M0→M1 on both LPs
    echo "[2/3] Locking M0 → M1 on LP nodes..."
    echo ""
    lock_m0_to_m1 "$OP1_IP" "OP1-alice"
    lock_m0_to_m1 "$OP2_IP" "OP2-dev"

    # Step 3: Trigger inventory refresh on LP servers
    echo "[3/3] Triggering LP inventory refresh..."
    for LP in "http://$OP1_IP:8080" "http://$OP2_IP:8080"; do
        RESP=$(curl -s -X POST "$LP/api/lp/inventory/refresh" 2>/dev/null)
        if [ $? -eq 0 ]; then
            M1_INV=$(echo "$RESP" | jq -r '.inventory.m1 // "?"' 2>/dev/null)
            echo "  $LP: M1 inventory = $M1_INV"
        else
            echo "  $LP: unreachable"
        fi
    done

    echo ""
    echo "=== Final Balances (sats) ==="
    for NODE in "$OP1_IP:OP1-alice" "$OP2_IP:OP2-dev"; do
        IP="${NODE%%:*}"
        NAME="${NODE##*:}"
        WALLET=$($SSH ubuntu@$IP "$CLI getwalletstate true 2>&1" 2>/dev/null)
        M0=$(echo "$WALLET" | jq -r '.m0.balance // 0')
        M1=$(echo "$WALLET" | jq -r '.m1.total // 0')
        M1_COUNT=$(echo "$WALLET" | jq -r '.m1.count // 0')
        echo "  $NAME: M0=${M0}  M1=${M1} ($M1_COUNT receipts)"
    done
    ;;

refresh)
    echo "=== Triggering LP Inventory Refresh ==="
    for LP in "http://$OP1_IP:8080:OP1-alice" "http://$OP2_IP:8080:OP2-dev"; do
        URL="${LP%:*}"
        NAME="${LP##*:}"
        RESP=$(curl -s -X POST "$URL/api/lp/inventory/refresh" 2>/dev/null)
        if [ $? -eq 0 ]; then
            BTC=$(echo "$RESP" | jq -r '.inventory.btc // 0' 2>/dev/null)
            M1=$(echo "$RESP" | jq -r '.inventory.m1 // 0' 2>/dev/null)
            USDC=$(echo "$RESP" | jq -r '.inventory.usdc // 0' 2>/dev/null)
            echo "  $NAME: BTC=$BTC  M1=$M1  USDC=$USDC"
        else
            echo "  $NAME: LP server unreachable"
        fi
    done
    ;;

*)
    echo "Usage: $0 [provision|status|refresh]"
    exit 1
    ;;
esac
