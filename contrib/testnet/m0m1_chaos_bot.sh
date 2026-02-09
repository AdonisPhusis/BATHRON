#!/bin/bash
# ============================================================================
# M0/M1 Chaos Bot - Random settlement transactions
# ============================================================================
# Stress tests the settlement layer with random:
# - Lock (M0 → M1)
# - Unlock (M1 → M0)
# - Transfer M1
# - Send M0
#
# Usage: ./m0m1_chaos_bot.sh [start|stop|status|run]
# ============================================================================

PID_FILE="/tmp/m0m1_chaos_bot.pid"
LOG_FILE="/tmp/m0m1_chaos_bot.log"

# SSH Configuration
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
TARGET_IP="57.131.33.151"

# Test addresses
ADDR_PILPOUS="xyszqryssGaNw13qpjbxB4PVoRqGat7RPd"
ADDR_ALICE="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

# Run CLI command on target
run_cli() {
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
        ubuntu@$TARGET_IP "~/BATHRON-Core/src/bathron-cli -testnet $*" 2>/dev/null
}

# Random number between min and max
rand_range() {
    echo $(( RANDOM % ($2 - $1 + 1) + $1 ))
}

# Pick random address
rand_addr() {
    if [ $((RANDOM % 2)) -eq 0 ]; then
        echo "$ADDR_PILPOUS"
    else
        echo "$ADDR_ALICE"
    fi
}

# Get M1 receipt
get_receipt() {
    run_cli listreceipts | jq -r '.[0].outpoint // empty' 2>/dev/null
}

get_receipt_amount() {
    run_cli listreceipts | jq -r '.[0].amount // 0' 2>/dev/null
}

# Log function
log() {
    echo "[$(date '+%H:%M:%S')] $1"
}

# Print state
print_state() {
    local bal=$(run_cli getbalance)
    local m0=$(echo "$bal" | jq -r '.m0 // 0')
    local m1=$(echo "$bal" | jq -r '.m1 // 0')
    local h=$(run_cli getblockcount)
    local state=$(run_cli getstate | jq -r '.supply | "vaulted=\(.m0_vaulted) m1=\(.m1_supply)"')
    log "STATE h=$h | M0=$m0 | M1=$m1 | $state"
}

# ACTION: Lock
do_lock() {
    local amount=$(rand_range 100 2000)
    log "LOCK $amount M0..."
    local result=$(run_cli lock $amount)
    if echo "$result" | grep -q '"txid"'; then
        local txid=$(echo "$result" | jq -r '.txid')
        log "  OK: ${txid:0:20}..."
        return 0
    else
        log "  FAIL: $(echo "$result" | head -1)"
        return 1
    fi
}

# ACTION: Unlock (partial)
do_unlock() {
    local receipt_amt=$(get_receipt_amount)
    local max=$(echo "$receipt_amt" | awk '{printf "%.0f", $1}')

    if [ -z "$max" ] || [ "$max" -lt 50 ]; then
        log "UNLOCK skip: no/small receipt ($max)"
        return 1
    fi

    local pct=$(rand_range 20 80)
    local amount=$(( max * pct / 100 ))
    [ "$amount" -lt 10 ] && amount=10

    log "UNLOCK $amount M0 (${pct}% of $max)..."
    local result=$(run_cli unlock $amount)
    if echo "$result" | grep -q '"txid"'; then
        local txid=$(echo "$result" | jq -r '.txid')
        local change=$(echo "$result" | jq -r '.m1_change // 0')
        log "  OK: ${txid:0:20}... | change=$change M1"
        return 0
    else
        log "  FAIL: $(echo "$result" | head -1)"
        return 1
    fi
}

# ACTION: Transfer M1
do_transfer() {
    local receipt=$(get_receipt)
    if [ -z "$receipt" ]; then
        log "TRANSFER skip: no receipt"
        return 1
    fi

    local dest=$(rand_addr)
    log "TRANSFER M1 to ${dest:0:12}..."
    local result=$(run_cli transfer_m1 "$receipt" "$dest")
    if echo "$result" | grep -q '"txid"'; then
        local txid=$(echo "$result" | jq -r '.txid')
        local amt=$(echo "$result" | jq -r '.amount // "?"')
        log "  OK: $amt M1 | ${txid:0:20}..."
        return 0
    else
        log "  FAIL: $(echo "$result" | head -1)"
        return 1
    fi
}

# ACTION: Send M0
do_send() {
    local amount=$(rand_range 50 500)
    local dest=$(rand_addr)
    log "SEND $amount M0 to ${dest:0:12}..."
    local result=$(run_cli sendtoaddress "$dest" $amount)
    if echo "$result" | grep -qE "^[a-f0-9]{64}$"; then
        log "  OK: ${result:0:20}..."
        return 0
    else
        log "  FAIL: $(echo "$result" | head -1)"
        return 1
    fi
}

# Main loop
chaos_loop() {
    local count=0
    local ok=0
    local fail=0

    log "=========================================="
    log "M0/M1 Chaos Bot Started"
    log "Target: $TARGET_IP"
    log "=========================================="

    print_state

    while true; do
        local roll=$(rand_range 1 100)
        local result=1

        # 35% lock, 35% unlock, 15% transfer, 15% send
        if [ $roll -le 35 ]; then
            do_lock && result=0
        elif [ $roll -le 70 ]; then
            do_unlock && result=0
        elif [ $roll -le 85 ]; then
            do_transfer && result=0
        else
            do_send && result=0
        fi

        count=$((count + 1))
        [ $result -eq 0 ] && ok=$((ok + 1)) || fail=$((fail + 1))

        # State every 5 TXs
        if [ $((count % 5)) -eq 0 ]; then
            print_state
            log "STATS: $count total | $ok ok | $fail fail"
        fi

        # Random sleep 5-20s
        sleep $(rand_range 5 20)
    done
}

# Commands
case "${1:-help}" in
    run)
        # Direct run (foreground)
        chaos_loop
        ;;
    start)
        if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
            echo "Already running (PID $(cat $PID_FILE))"
            exit 1
        fi

        echo "Testing connection..."
        if ! run_cli getblockcount >/dev/null; then
            echo "ERROR: Cannot connect to $TARGET_IP"
            exit 1
        fi

        echo "Starting bot..."
        nohup "$0" run > "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
        echo "Started (PID $(cat $PID_FILE))"
        echo "Log: tail -f $LOG_FILE"
        ;;
    stop)
        if [ -f "$PID_FILE" ]; then
            kill $(cat "$PID_FILE") 2>/dev/null
            rm -f "$PID_FILE"
            echo "Stopped"
        else
            echo "Not running"
        fi
        ;;
    status)
        if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
            echo "RUNNING (PID $(cat $PID_FILE))"
            echo ""
            tail -25 "$LOG_FILE"
        else
            echo "STOPPED"
            [ -f "$LOG_FILE" ] && echo "" && tail -10 "$LOG_FILE"
        fi
        ;;
    logs)
        tail -f "$LOG_FILE"
        ;;
    *)
        echo "M0/M1 Chaos Bot"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  start   - Start in background"
        echo "  stop    - Stop"
        echo "  status  - Show status + recent logs"
        echo "  logs    - Follow logs (tail -f)"
        echo "  run     - Run in foreground"
        echo ""
        echo "Actions:"
        echo "  LOCK     35% - M0 → M1 (100-2000)"
        echo "  UNLOCK   35% - M1 → M0 (20-80%)"
        echo "  TRANSFER 15% - M1 transfer"
        echo "  SEND     15% - M0 send"
        ;;
esac
