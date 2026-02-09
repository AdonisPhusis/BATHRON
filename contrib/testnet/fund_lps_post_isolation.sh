#!/bin/bash
# =============================================================================
# fund_lps_post_isolation.sh — Fund LPs after wallet isolation
# =============================================================================
# After isolation, nobody has enough free M0 to pay fees.
# ~3M M0 is in MN operator addresses (coinbase fee rewards).
#
# Strategy:
#   1. Import MN operator WIFs on Seed → access fee M0
#   2. Send M0 from Seed to bob, alice, dev
#   3. bob transfers M1 receipts to alice and dev
#   4. alice/dev lock M0→M1 if needed
# =============================================================================

set -uo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o ServerAliveInterval=30"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

SEED_IP="57.131.33.151"
SEED_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

CORESDK_IP="162.19.251.75"
CORESDK_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

OP1_IP="57.131.33.152"
OP1_CLI="/home/ubuntu/bathron-cli -testnet"

OP2_IP="57.131.33.214"
OP2_CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet"

ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
BOB_ADDR="y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk"
DEV_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"

log_info() { echo "[INFO] $*"; }
log_ok()   { echo "[OK]   $*"; }
log_warn() { echo "[WARN] $*"; }
log_err()  { echo "[ERR]  $*"; }

wait_blocks() {
    local secs=${1:-75}
    echo -n "  Waiting ${secs}s for confirmation "
    for i in $(seq 1 $((secs/5))); do sleep 5; printf "."; done
    echo ""
}

echo "============================================================"
echo "  FUND LPs POST ISOLATION"
echo "============================================================"
echo ""

# =================================================================
# Step 1: Import MN operator keys on Seed to access fee M0
# =================================================================
echo "=== Step 1: Import MN operator keys on Seed ==="
log_info "Reading operator WIFs from Seed's ~/.BathronKey/operators.json..."

# Get operator count and import
IMPORT_RESULT=$($SSH ubuntu@$SEED_IP "
    CLI='$SEED_CLI'

    # Check current balance before import
    echo \"Before import:\"
    \$CLI getbalance

    # Read operator keys and import
    if [ -f ~/.BathronKey/operators.json ]; then
        # Extract WIFs with python3
        python3 -c '
import json
with open(\"/home/ubuntu/.BathronKey/operators.json\") as f:
    ops = json.load(f)
for name, data in ops.items():
    wif = data.get(\"wif\", \"\")
    if wif:
        print(f\"{name}:{wif}\")
' | while IFS=: read name wif; do
            echo \"Importing \$name...\"
            \$CLI importprivkey \"\$wif\" \"op_\$name\" false 2>&1 || echo \"  (already imported or error)\"
        done

        # Rescan once after all imports
        echo \"Rescanning blockchain (may take 1-2 min)...\"
        \$CLI rescanblockchain 2>&1 | tail -1

        echo \"After import:\"
        \$CLI getbalance
    else
        echo 'operators.json not found!'
    fi
" 2>/dev/null)
echo "$IMPORT_RESULT"
echo ""

# Extract available M0 from result
SEED_BAL=$($SSH ubuntu@$SEED_IP "$SEED_CLI getbalance" 2>/dev/null)
SEED_M0=$(echo "$SEED_BAL" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("m0",0) - d.get("locked",0))' 2>/dev/null)
log_info "Seed available M0 (after operator import): $SEED_M0 sats"

if [ "${SEED_M0:-0}" -lt 100000 ] 2>/dev/null; then
    log_err "Not enough free M0 on Seed ($SEED_M0). Need at least 100k."
    log_info "May need to do a BTC burn to get more M0."
    exit 1
fi
echo ""

# =================================================================
# Step 2: Send M0 from Seed to bob, alice, dev
# =================================================================
echo "=== Step 2: Send M0 to bob, alice, dev ==="

# Send 50k to each
FUND_AMOUNT=50000
log_info "Sending $FUND_AMOUNT M0 to bob (for transfer fees)..."
TX_BOB=$($SSH ubuntu@$SEED_IP "$SEED_CLI sendtoaddress $BOB_ADDR $FUND_AMOUNT" 2>/dev/null)
echo "  TX: $TX_BOB"

log_info "Sending $FUND_AMOUNT M0 to alice..."
TX_ALICE=$($SSH ubuntu@$SEED_IP "$SEED_CLI sendtoaddress $ALICE_ADDR $FUND_AMOUNT" 2>/dev/null)
echo "  TX: $TX_ALICE"

log_info "Sending $FUND_AMOUNT M0 to dev..."
TX_DEV=$($SSH ubuntu@$SEED_IP "$SEED_CLI sendtoaddress $DEV_ADDR $FUND_AMOUNT" 2>/dev/null)
echo "  TX: $TX_DEV"
echo ""

wait_blocks 75

# Verify M0 received
echo "=== Step 3: Verify M0 received ==="
echo "  bob:"
$SSH ubuntu@$CORESDK_IP "$CORESDK_CLI getbalance" 2>/dev/null
echo ""
echo "  alice:"
$SSH ubuntu@$OP1_IP "$OP1_CLI getbalance" 2>/dev/null
echo ""
echo "  dev:"
$SSH ubuntu@$OP2_IP "$OP2_CLI getbalance" 2>/dev/null
echo ""

# =================================================================
# Step 4: Transfer M1 from bob → alice (500k receipt)
# =================================================================
echo "=== Step 4: Transfer M1 bob → alice ==="

# Get bob's M1 receipts (fresh)
BOB_RECEIPTS=$($SSH ubuntu@$CORESDK_IP "$CORESDK_CLI getwalletstate true" 2>/dev/null)
echo "  bob M1 receipts:"
echo "$BOB_RECEIPTS" | python3 -c '
import sys,json
d = json.load(sys.stdin)
m1 = d.get("m1", {})
for r in m1.get("receipts", []):
    print(f"    {r[\"outpoint\"]}: {r[\"amount\"]} sats")
' 2>/dev/null

# Transfer big receipt to alice
BIG_OUTPOINT=$(echo "$BOB_RECEIPTS" | python3 -c '
import sys,json
d = json.load(sys.stdin)
receipts = d.get("m1",{}).get("receipts",[])
# Find largest receipt
if receipts:
    biggest = max(receipts, key=lambda r: r["amount"])
    print(biggest["outpoint"])
' 2>/dev/null)

if [ -n "$BIG_OUTPOINT" ]; then
    log_info "Transferring $BIG_OUTPOINT → alice..."
    TRANSFER=$($SSH ubuntu@$CORESDK_IP "$CORESDK_CLI transfer_m1 \"$BIG_OUTPOINT\" \"$ALICE_ADDR\" 2>&1" 2>/dev/null)
    echo "  $TRANSFER"
else
    log_warn "No M1 receipts found on bob"
fi

# Transfer small receipt to dev (if exists)
SMALL_OUTPOINT=$(echo "$BOB_RECEIPTS" | python3 -c '
import sys,json
d = json.load(sys.stdin)
receipts = d.get("m1",{}).get("receipts",[])
if len(receipts) > 1:
    smallest = min(receipts, key=lambda r: r["amount"])
    print(smallest["outpoint"])
' 2>/dev/null)

if [ -n "$SMALL_OUTPOINT" ]; then
    log_info "Transferring $SMALL_OUTPOINT → dev..."
    TRANSFER2=$($SSH ubuntu@$CORESDK_IP "$CORESDK_CLI transfer_m1 \"$SMALL_OUTPOINT\" \"$DEV_ADDR\" 2>&1" 2>/dev/null)
    echo "  $TRANSFER2"
fi
echo ""

wait_blocks 75

# =================================================================
# Step 5: Lock M0 → M1 on alice and dev (additional liquidity)
# =================================================================
echo "=== Step 5: Lock extra M0 → M1 on LPs ==="

# Alice: lock most of her M0 (keep 5k for fees)
ALICE_BAL=$($SSH ubuntu@$OP1_IP "$OP1_CLI getbalance" 2>/dev/null)
ALICE_M0=$(echo "$ALICE_BAL" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("m0",0))' 2>/dev/null)
if [ "${ALICE_M0:-0}" -gt 10000 ] 2>/dev/null; then
    LOCK_AMT=$((ALICE_M0 - 5000))
    log_info "alice: locking $LOCK_AMT M0 → M1..."
    $SSH ubuntu@$OP1_IP "$OP1_CLI lock $LOCK_AMT" 2>/dev/null
else
    log_warn "alice M0=$ALICE_M0 — not enough to lock (need >10k)"
fi

# Dev: same
DEV_BAL=$($SSH ubuntu@$OP2_IP "$OP2_CLI getbalance" 2>/dev/null)
DEV_M0=$(echo "$DEV_BAL" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("m0",0))' 2>/dev/null)
if [ "${DEV_M0:-0}" -gt 10000 ] 2>/dev/null; then
    LOCK_AMT=$((DEV_M0 - 5000))
    log_info "dev: locking $LOCK_AMT M0 → M1..."
    $SSH ubuntu@$OP2_IP "$OP2_CLI lock $LOCK_AMT" 2>/dev/null
else
    log_warn "dev M0=$DEV_M0 — not enough to lock (need >10k)"
fi
echo ""

wait_blocks 75

# =================================================================
# Final: Verify all balances
# =================================================================
echo "============================================================"
echo "  FINAL BALANCES"
echo "============================================================"
echo ""

for label_ip_cli in \
    "Seed:$SEED_IP:$SEED_CLI" \
    "bob (CoreSDK):$CORESDK_IP:$CORESDK_CLI" \
    "alice (LP1):$OP1_IP:$OP1_CLI" \
    "dev (LP2):$OP2_IP:$OP2_CLI"; do

    IFS=: read label ip cli <<< "$label_ip_cli"
    echo "  $label:"
    $SSH ubuntu@$ip "$cli getbalance" 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(f"    M0={d.get(\"m0\",0)} (locked={d.get(\"locked\",0)}) M1={d.get(\"m1\",0)}")
' 2>/dev/null || echo "    (error)"
done
echo ""
echo "============================================================"
echo "  DONE"
echo "============================================================"
