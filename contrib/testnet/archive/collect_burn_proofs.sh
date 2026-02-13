#!/bin/bash
# ==============================================================================
# DEPRECATED: collect_burn_proofs.sh
# Burns are now auto-discovered from BTC Signet by genesis_bootstrap_seed.sh.
# This script is no longer needed for genesis. Kept for reference only.
# ==============================================================================
# collect_burn_proofs.sh - Collect burn proofs from a synced BTC Signet node
# ==============================================================================
#
# Runs from DEV machine. SSHes to a VPS with synced BTC Signet (OP1 by default),
# scans for BATHRON burns, collects raw TX + merkle proofs, saves to file.
# Then copies the proofs file to Seed for genesis_claim_burns_simple.sh to use.
#
# Usage:
#   ./collect_burn_proofs.sh              # Scan from OP1, copy to Seed
#   ./collect_burn_proofs.sh status       # Check which VPS has synced BTC Signet
#
# Called by deploy_to_vps.sh --genesis (step 1b)
# ==============================================================================

set +e

SSH="ssh -i ~/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCP="scp -i ~/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

SEED_IP="57.131.33.151"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"

# BTC CLI paths per VPS (absolute paths — all users are ubuntu)
SEED_BTC="/home/ubuntu/bitcoin-27.0/bin/bitcoin-cli -conf=/home/ubuntu/.bitcoin-signet/bitcoin.conf"
OP1_BTC="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"
OP2_BTC="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

SCAN_START=286300
K_CONFIRMATIONS=6
BATHRON_MAGIC="42415448524f4e"
PROOFS_FILE="/tmp/burn_proofs.json"

CMD="${1:-collect}"

# --- Find a synced BTC Signet ---
find_synced_btc() {
    local MIN_TIP=$((SCAN_START + K_CONFIRMATIONS + 100))  # Need at least scan range

    for NODE_INFO in "$OP1_IP|$OP1_BTC|OP1" "$OP2_IP|$OP2_BTC|OP2" "$SEED_IP|$SEED_BTC|Seed"; do
        local IP=$(echo "$NODE_INFO" | cut -d'|' -f1)
        local BTC=$(echo "$NODE_INFO" | cut -d'|' -f2)
        local NAME=$(echo "$NODE_INFO" | cut -d'|' -f3)

        local TIP=$($SSH ubuntu@$IP "$BTC getblockcount 2>/dev/null" 2>/dev/null)
        if [ -n "$TIP" ] && [ "$TIP" -ge "$MIN_TIP" ]; then
            echo "$IP|$BTC|$NAME|$TIP"
            return 0
        fi
        echo "  $NAME ($IP): tip=${TIP:-UNREACHABLE}" >&2
    done
    return 1
}

case "$CMD" in
status)
    echo "=== BTC Signet Status (all VPS) ==="
    for NODE_INFO in "$OP1_IP|$OP1_BTC|OP1" "$OP2_IP|$OP2_BTC|OP2" "$SEED_IP|$SEED_BTC|Seed"; do
        IP=$(echo "$NODE_INFO" | cut -d'|' -f1)
        BTC=$(echo "$NODE_INFO" | cut -d'|' -f2)
        NAME=$(echo "$NODE_INFO" | cut -d'|' -f3)
        TIP=$($SSH ubuntu@$IP "$BTC getblockcount 2>/dev/null" 2>/dev/null)
        echo "  $NAME ($IP): tip=${TIP:-UNREACHABLE}"
    done
    ;;

collect)
    echo "════════════════════════════════════════════════════"
    echo "  Collect Burn Proofs"
    echo "════════════════════════════════════════════════════"
    echo ""

    # Find synced node
    echo "[1/3] Finding synced BTC Signet..."
    SYNCED=$(find_synced_btc)
    if [ -z "$SYNCED" ]; then
        echo "[FATAL] No synced BTC Signet found on any VPS."
        exit 1
    fi

    BTC_IP=$(echo "$SYNCED" | cut -d'|' -f1)
    BTC_CLI_REMOTE=$(echo "$SYNCED" | cut -d'|' -f2)
    BTC_NAME=$(echo "$SYNCED" | cut -d'|' -f3)
    BTC_TIP=$(echo "$SYNCED" | cut -d'|' -f4)
    SCAN_END=$((BTC_TIP - K_CONFIRMATIONS))

    echo "  Using: $BTC_NAME ($BTC_IP) tip=$BTC_TIP"
    echo "  Scan:  $SCAN_START → $SCAN_END ($((SCAN_END - SCAN_START)) blocks)"
    echo ""

    # Create remote scan script
    echo "[2/3] Running burn scan on $BTC_NAME..."

    cat > /tmp/scan_burns_remote.sh << 'REMOTESCRIPT'
#!/bin/bash
# Runs on a VPS with synced BTC Signet
# Outputs JSON burn proofs to stdout

BTC_CMD="__BTC_CMD__"
SCAN_START="__SCAN_START__"
SCAN_END="__SCAN_END__"
MAGIC="42415448524f4e"

# Start JSON
echo '{"btc_tip": __BTC_TIP__, "scan_start": '$SCAN_START', "scan_end": '$SCAN_END', "burns": ['

FIRST=true
FOUND=0

for HEIGHT in $(seq $SCAN_START $SCAN_END); do
    # Progress every 500 blocks
    if [ $((HEIGHT % 500)) -eq 0 ]; then
        echo "  scanning block $HEIGHT / $SCAN_END (found $FOUND)" >&2
    fi

    BLOCK_HASH=$($BTC_CMD getblockhash "$HEIGHT" 2>/dev/null)
    [ -z "$BLOCK_HASH" ] && continue

    # Find TXs with OP_RETURN
    TXIDS=$($BTC_CMD getblock "$BLOCK_HASH" 2 2>/dev/null | \
        jq -r '.tx[] | select(.vout[]?.scriptPubKey.asm | startswith("OP_RETURN")) | .txid' 2>/dev/null)

    for TXID in $TXIDS; do
        [ -z "$TXID" ] && continue

        RAW_TX=$($BTC_CMD getrawtransaction "$TXID" 2>/dev/null)
        [ -z "$RAW_TX" ] && continue

        # Check for BATHRON magic
        if ! echo "$RAW_TX" | grep -qi "6a.*$MAGIC"; then
            continue
        fi

        # Get merkle proof
        MERKLE=$($BTC_CMD gettxoutproof "[\"$TXID\"]" 2>/dev/null)
        [ -z "$MERKLE" ] && { echo "  WARN: no merkle for $TXID" >&2; continue; }

        FOUND=$((FOUND + 1))
        echo "  [BURN] $TXID height=$HEIGHT" >&2

        if [ "$FIRST" = true ]; then
            FIRST=false
        else
            echo ","
        fi

        # Output JSON entry (raw_tx and merkle on single lines)
        printf '{"txid":"%s","height":%d,"raw_tx":"%s","merkleblock":"%s"}' \
            "$TXID" "$HEIGHT" "$RAW_TX" "$MERKLE"
    done
done

echo ""
echo "]}"
echo "Total burns found: $FOUND" >&2
REMOTESCRIPT

    # Substitute variables
    sed -i "s|__BTC_CMD__|$BTC_CLI_REMOTE|g" /tmp/scan_burns_remote.sh
    sed -i "s|__SCAN_START__|$SCAN_START|g" /tmp/scan_burns_remote.sh
    sed -i "s|__SCAN_END__|$SCAN_END|g" /tmp/scan_burns_remote.sh
    sed -i "s|__BTC_TIP__|$BTC_TIP|g" /tmp/scan_burns_remote.sh

    # Copy and run on remote
    $SCP /tmp/scan_burns_remote.sh ubuntu@$BTC_IP:/tmp/ 2>/dev/null
    $SSH ubuntu@$BTC_IP "chmod +x /tmp/scan_burns_remote.sh" 2>/dev/null

    # Run scan — stdout=JSON, stderr=progress (separate streams)
    $SSH ubuntu@$BTC_IP "bash /tmp/scan_burns_remote.sh 2>/tmp/burn_scan_progress.log" > "$PROOFS_FILE"
    # Show progress from remote log
    echo "  Remote scan progress:"
    $SSH ubuntu@$BTC_IP "cat /tmp/burn_scan_progress.log" 2>/dev/null | tail -10

    # Validate JSON
    BURN_COUNT=$(jq '.burns | length' "$PROOFS_FILE" 2>/dev/null)
    if [ -z "$BURN_COUNT" ] || [ "$BURN_COUNT" -eq 0 ]; then
        echo "[FATAL] No burns found or invalid JSON output."
        echo "Raw output (first 500 chars):"
        head -c 500 "$PROOFS_FILE"
        exit 1
    fi

    SCAN_END_ACTUAL=$(jq '.scan_end' "$PROOFS_FILE")

    echo ""
    echo "  Burns found: $BURN_COUNT"
    echo "  Scan range:  $SCAN_START → $SCAN_END_ACTUAL"
    echo "  Proofs file: $PROOFS_FILE"
    echo ""

    # Copy to Seed
    echo "[3/3] Copying proofs to Seed..."
    $SCP "$PROOFS_FILE" ubuntu@$SEED_IP:~/burn_proofs.json 2>/dev/null
    echo "  Done."

    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  $BURN_COUNT burn proofs collected → Seed"
    echo "  Ready for genesis_claim_burns_simple.sh"
    echo "════════════════════════════════════════════════════"
    ;;

*)
    echo "Usage: $0 [collect|status]"
    exit 1
    ;;
esac
