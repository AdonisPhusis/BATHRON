#!/bin/bash
#
# fund_lp_large.sh - Fund LP with large M1 amounts via BTC burn + lock
#
# Usage:
#   ./fund_lp_large.sh status       # Show all balances (BATHRON + BTC)
#   ./fund_lp_large.sh burn <sats>  # Burn BTC on Seed → M0BTC for alice
#   ./fund_lp_large.sh lock         # Lock all free M0 → M1 on alice
#   ./fund_lp_large.sh monitor      # Monitor pending burns + M0BTC arrival
#
# Flow:
#   1. BTC Signet burn (Seed node) → claim detected by burn_claim_daemon
#   2. After K=6 BATHRON blocks → TX_MINT_M0BTC → M0 in alice wallet
#   3. Lock M0 → M1 on alice
#
# Requirements:
#   - burn_claim_daemon running on Seed
#   - BTC Signet funded on Seed (wallet: bathronburn)
#

set -uo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
SCP="scp -i $SSH_KEY $SSH_OPTS"

# VPS IPs
SEED_IP="57.131.33.151"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"
OP3_IP="51.75.31.44"
CORESDK_IP="162.19.251.75"

# CLIs
SEED_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
OP1_CLI="/home/ubuntu/bathron-cli -testnet"
OP2_CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet"

# Addresses
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cmd_status() {
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       LP FUNDING STATUS                      ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    # BATHRON balances
    echo -e "${BLUE}=== BATHRON Balances ===${NC}"
    echo ""

    _show_bal() {
        local LABEL="$1" IP="$2" CLI="$3"
        printf "  %-18s " "$LABEL"
        local BAL
        BAL=$($SSH ubuntu@"$IP" "$CLI getbalance" 2>/dev/null) || { echo "(ssh error)"; return; }
        python3 << PYEOF
import json, sys
try:
    d = json.loads("""$BAL""")
    m0 = d.get('m0', 0)
    locked = d.get('locked', 0)
    m1 = d.get('m1', 0)
    free = m0 - locked
    print(f'M0={m0:,}  locked={locked:,}  free={free:,}  M1={m1:,}')
except Exception as e:
    print(f'(parse error: {e})')
PYEOF
    }

    _show_bal "Seed (pilpous)" "$SEED_IP" "$SEED_CLI"
    _show_bal "alice (LP1/OP1)" "$OP1_IP" "$OP1_CLI"
    _show_bal "dev (LP2/OP2)" "$OP2_IP" "$OP2_CLI"
    _show_bal "bob (CoreSDK)" "$CORESDK_IP" "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

    echo ""

    # BTC Signet balances
    echo -e "${BLUE}=== BTC Signet Balances (burn sources) ===${NC}"
    echo ""

    echo -n "  Seed (bathronburn): "
    $SSH ubuntu@$SEED_IP '
        BTCCLI="/home/ubuntu/bitcoin-27.0/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet"
        BAL=$($BTCCLI -rpcwallet=bathronburn getbalance 2>/dev/null || echo "?")
        echo "$BAL BTC"
    ' 2>/dev/null || echo "(error)"

    echo -n "  OP3 (fake_user):    "
    $SSH ubuntu@$OP3_IP '
        BTCCLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
        BAL=$($BTCCLI -rpcwallet=fake_user getbalance 2>/dev/null || echo "?")
        echo "$BAL BTC"
    ' 2>/dev/null || echo "(error)"

    echo ""

    # Burn claim daemon status
    echo -e "${BLUE}=== Burn Claim Daemon (Seed) ===${NC}"
    echo ""
    $SSH ubuntu@$SEED_IP '
        if pgrep -f "btc_burn_claim_daemon" > /dev/null 2>&1; then
            echo "  Status: RUNNING"
        else
            echo "  Status: NOT RUNNING (burns wont be auto-detected!)"
        fi
    ' 2>/dev/null || echo "  (error)"

    echo ""

    # Global state
    echo -e "${BLUE}=== BATHRON Global State ===${NC}"
    echo ""
    STATE=$($SSH ubuntu@$SEED_IP "$SEED_CLI getstate" 2>/dev/null) || { echo "  (ssh error)"; }
    if [ -n "${STATE:-}" ]; then
        python3 << PYEOF
import json
try:
    d = json.loads("""$STATE""")
    s = d.get('settlement', {})
    print(f'  Block height:  {d.get("height", "?")}')
    print(f'  M0 total:      {s.get("m0_total", "?")} sats')
    print(f'  M0 vaulted:    {s.get("m0_vaulted", "?")} sats')
    print(f'  M1 supply:     {s.get("m1_supply", "?")} sats')
    print(f'  Burns claimed: {s.get("burns_claimed", "?")} sats')
except Exception as e:
    print(f'  (parse error: {e})')
PYEOF
    fi

    echo ""
}

cmd_burn() {
    local BURN_SATS="${1:-}"
    if [ -z "$BURN_SATS" ]; then
        echo -e "${RED}Usage: $0 burn <amount_sats>${NC}"
        echo ""
        echo "Examples:"
        echo "  $0 burn 50000     # Burn 50k sats → 50k M0BTC for alice"
        echo "  $0 burn 500000    # Burn 500k sats → 500k M0BTC for alice"
        echo "  $0 burn 5000000   # Burn 5M sats → 5M M0BTC for alice"
        exit 1
    fi

    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       BTC BURN → M0BTC for alice             ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Target:${NC} $ALICE_ADDR (alice, LP1)"
    echo -e "${YELLOW}Amount:${NC} $BURN_SATS sats"
    echo ""

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Step 1: Copy burn_signet.sh to OP3 (where the BTC is)
    echo -e "${YELLOW}[1/4] Copying burn script to OP3 ($OP3_IP)...${NC}"
    $SCP "$SCRIPT_DIR/burn_signet.sh" ubuntu@$OP3_IP:/tmp/burn_signet.sh 2>/dev/null
    $SSH ubuntu@$OP3_IP "chmod +x /tmp/burn_signet.sh" 2>/dev/null
    echo "  Done."

    # Step 2: Check OP3 BTC balance
    echo ""
    echo -e "${YELLOW}[2/4] Checking BTC Signet on OP3...${NC}"
    BTC_STATUS=$($SSH ubuntu@$OP3_IP '
        BTCCLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
        HEIGHT=$($BTCCLI getblockcount 2>/dev/null || echo "ERROR")
        if [ "$HEIGHT" = "ERROR" ]; then
            echo "OFFLINE"
        else
            BALANCE=$($BTCCLI -rpcwallet=fake_user getbalance 2>/dev/null || echo "0")
            echo "OK:$HEIGHT:$BALANCE"
        fi
    ' 2>/dev/null)

    if [[ "$BTC_STATUS" == "OFFLINE" ]] || [[ -z "$BTC_STATUS" ]]; then
        echo -e "${RED}Error: Bitcoin Signet not running on OP3${NC}"
        exit 1
    fi

    IFS=':' read -r STATUS HEIGHT BALANCE <<< "$BTC_STATUS"
    BALANCE_SATS=$(echo "$BALANCE * 100000000" | bc 2>/dev/null | cut -d. -f1 || echo "0")
    echo "  Signet height: $HEIGHT"
    echo "  fake_user balance: $BALANCE BTC ($BALANCE_SATS sats)"

    if [ "$BALANCE_SATS" -lt "$((BURN_SATS + 2000))" ]; then
        echo -e "${RED}Error: Insufficient BTC ($BALANCE_SATS < $BURN_SATS + fees)${NC}"
        echo ""
        echo "Get signet coins from: https://signetfaucet.com/"
        exit 1
    fi

    # Step 3: Execute burn on OP3
    echo ""
    echo -e "${YELLOW}[3/4] Executing burn on OP3...${NC}"
    echo ""

    # burn_signet.sh auto-detects wallets. On OP3 the wallet is 'fake_user'.
    # We need to ensure it finds it. Let's run directly:
    RESULT=$($SSH ubuntu@$OP3_IP "/tmp/burn_signet.sh '$ALICE_ADDR' $BURN_SATS --yes" 2>&1)
    echo "$RESULT"

    # Extract TXID
    TXID=$(echo "$RESULT" | grep -oP 'TXID: \K[a-f0-9]{64}' | head -1 || true)

    if [ -n "$TXID" ]; then
        echo ""
        echo -e "${GREEN}[4/4] BURN SUBMITTED${NC}"
        echo ""
        echo "  TXID: $TXID"
        echo "  https://mempool.space/signet/tx/$TXID"
    else
        echo ""
        echo -e "${RED}Could not extract TXID. Check output above.${NC}"
        echo ""
        echo "The OP3 wallet might use a different name than expected."
        echo "Try burning from Seed instead: ./remote_burn.sh $ALICE_ADDR $BURN_SATS"
        return 1
    fi

    echo ""
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  WHAT HAPPENS NEXT (automatic)                           ║${NC}"
    echo -e "${YELLOW}╠═══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║  1. BTC Signet: ~10 min for 6 confirmations              ║${NC}"
    echo -e "${YELLOW}║  2. burn_claim_daemon (Seed) detects → TX_BURN_CLAIM     ║${NC}"
    echo -e "${YELLOW}║  3. K=6 BATHRON blocks (~6 min) → TX_MINT_M0BTC         ║${NC}"
    echo -e "${YELLOW}║  4. M0BTC arrives in alice wallet on OP1                 ║${NC}"
    echo -e "${YELLOW}║  5. Run: $0 lock  (to convert M0 → M1)                  ║${NC}"
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Monitor progress: $0 monitor"
}

cmd_lock() {
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       LOCK ALL FREE M0 → M1 on alice        ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    # Get alice's balance
    ALICE_BAL=$($SSH ubuntu@$OP1_IP "$OP1_CLI getbalance" 2>/dev/null)
    ALICE_FREE=$(python3 << PYEOF
import json
d = json.loads("""$ALICE_BAL""")
print(d.get('m0', 0) - d.get('locked', 0))
PYEOF
)

    echo "  alice free M0: $ALICE_FREE sats"

    if [ "${ALICE_FREE:-0}" -le 50 ] 2>/dev/null; then
        echo -e "${YELLOW}  Not enough free M0 to lock (need >50, have ${ALICE_FREE:-0})${NC}"
        echo ""
        echo "  If you're waiting for M0BTC from a burn:"
        echo "    $0 monitor"
        return
    fi

    # Keep 50 for fees, lock the rest
    LOCK_AMT=$((ALICE_FREE - 50))
    echo "  Locking $LOCK_AMT M0 → M1 (keeping 50 for fees)..."
    echo ""

    RESULT=$($SSH ubuntu@$OP1_IP "$OP1_CLI lock $LOCK_AMT" 2>/dev/null)
    echo "  Result: $RESULT"
    echo ""

    # Wait a block
    echo "  Waiting 70s for confirmation..."
    for i in $(seq 1 14); do sleep 5; printf "."; done
    echo ""
    echo ""

    # Verify
    echo -e "${BLUE}=== alice balance after lock ===${NC}"
    FINAL_BAL=$($SSH ubuntu@$OP1_IP "$OP1_CLI getbalance" 2>/dev/null)
    python3 << PYEOF
import json
d = json.loads("""$FINAL_BAL""")
free = d.get('m0', 0) - d.get('locked', 0)
print(f'  M0: {d["m0"]:,}  locked: {d["locked"]:,}  free: {free:,}')
print(f'  M1: {d["m1"]:,}')
PYEOF
    echo ""
}

cmd_monitor() {
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       MONITOR PENDING BURNS                  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""

    # Check burn daemon status
    echo -e "${BLUE}=== Burn Claim Daemon ===${NC}"
    $SSH ubuntu@$SEED_IP '
        if pgrep -f "btc_burn_claim_daemon" > /dev/null 2>&1; then
            echo "  Status: RUNNING"
            # Show last 5 lines of log
            LOG="$HOME/.bathron/testnet5/burn_claim_daemon.log"
            if [ -f "$LOG" ]; then
                echo "  Last activity:"
                tail -5 "$LOG" | while read line; do echo "    $line"; done
            fi
        else
            echo "  Status: NOT RUNNING"
            echo "  Start: ./contrib/testnet/start_burn_daemon.sh"
        fi
    ' 2>/dev/null || echo "  (error)"
    echo ""

    # Check recent burns in saved files (check both Seed and OP3)
    echo -e "${BLUE}=== Recent Burns ===${NC}"
    for BURN_HOST_LABEL in "Seed:$SEED_IP" "OP3:$OP3_IP"; do
        BLABEL=$(echo "$BURN_HOST_LABEL" | cut -d: -f1)
        BIP=$(echo "$BURN_HOST_LABEL" | cut -d: -f2)
        $SSH ubuntu@$BIP '
            for DIR in /home/ubuntu/.bitcoin-signet/burns /home/ubuntu/burns; do
                if [ -d "$DIR" ]; then
                    for f in $(ls -t "$DIR"/*.json 2>/dev/null | head -5); do
                        python3 -c "
import json
d = json.load(open(\"$f\"))
txid = d[\"txid\"]
print(f\"  {txid[:16]}... -> {d[\"bathron_address\"]}  {d[\"burn_sats\"]} sats\")
" 2>/dev/null
                    done
                fi
            done
        ' 2>/dev/null
    done
    # If nothing was printed
    echo "  (check OP3 burn records on mempool.space)"
    echo ""

    # Alice current state
    echo -e "${BLUE}=== alice (LP1) current balance ===${NC}"
    ALICE_BAL=$($SSH ubuntu@$OP1_IP "$OP1_CLI getbalance" 2>/dev/null)
    if [ -n "${ALICE_BAL:-}" ]; then
        python3 << PYEOF
import json
d = json.loads("""$ALICE_BAL""")
m0 = d.get('m0', 0)
locked = d.get('locked', 0)
m1 = d.get('m1', 0)
free = m0 - locked
print(f'  M0: {m0:,}  free: {free:,}  M1: {m1:,}')
if free > 50:
    print(f'  -> Ready to lock! Run: fund_lp_large.sh lock')
else:
    print(f'  -> Waiting for M0BTC...')
PYEOF
    else
        echo "  (ssh error)"
    fi
    echo ""
}

# Main
case "${1:-status}" in
    status)
        cmd_status
        ;;
    burn)
        cmd_burn "${2:-}"
        ;;
    lock)
        cmd_lock
        ;;
    monitor)
        cmd_monitor
        ;;
    *)
        echo "Usage: $0 {status|burn <sats>|lock|monitor}"
        echo ""
        echo "Commands:"
        echo "  status       Show all balances (BATHRON + BTC Signet)"
        echo "  burn <sats>  Burn BTC on Seed → M0BTC for alice"
        echo "  lock         Lock all free M0 → M1 on alice"
        echo "  monitor      Monitor pending burns + M0BTC arrival"
        echo ""
        echo "Full flow:"
        echo "  1. $0 status              # Check available BTC"
        echo "  2. $0 burn 500000         # Burn 500k sats"
        echo "  3. (wait ~15 min)         # Auto: claim + mint"
        echo "  4. $0 lock                # Lock M0 → M1"
        echo "  5. $0 status              # Verify M1 balance"
        ;;
esac
