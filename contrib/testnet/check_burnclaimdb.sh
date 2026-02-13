#!/bin/bash
# ==============================================================================
# check_burnclaimdb.sh - Check burnclaimdb contents + daemon diagnostics on Seed
# ==============================================================================
# Usage:
#   ./check_burnclaimdb.sh              # List all burns in burnclaimdb
#   ./check_burnclaimdb.sh <txid>       # Search for a specific btc_txid (partial match)
#   ./check_burnclaimdb.sh diagnose     # Full diagnostic: daemon, scan progress, logs

set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
CLI="~/BATHRON-Core/src/bathron-cli -testnet"

CMD="${1:-list}"

ssh_seed() {
    ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "$@" 2>/dev/null
}

cmd_list() {
    echo "=========================================="
    echo "  Burnclaimdb Status (Seed)"
    echo "=========================================="
    echo ""

    local ALL_CLAIMS
    ALL_CLAIMS=$(ssh_seed "$CLI listburnclaims all 1000 0") || {
        echo "ERROR: Cannot reach Seed or RPC failed"
        exit 1
    }

    local TOTAL PENDING FINAL
    TOTAL=$(echo "$ALL_CLAIMS" | jq 'length')
    PENDING=$(echo "$ALL_CLAIMS" | jq '[.[] | select(.db_status == "pending")] | length')
    FINAL=$(echo "$ALL_CLAIMS" | jq '[.[] | select(.db_status == "final")] | length')

    echo "Total burns in burnclaimdb: $TOTAL"
    echo "  Final:   $FINAL"
    echo "  Pending: $PENDING"
    echo ""
    echo "All burns:"
    echo "---"
    echo "$ALL_CLAIMS" | jq -r '.[] | "  \(.btc_txid[0:16])...  \(.burned_sats) sats  height=\(.btc_height)  claim_h=\(.claim_height)  status=\(.db_status)"'
    echo ""

    # Burn stats
    echo "=========================================="
    echo "  Burn Stats (getbtcburnstats)"
    echo "=========================================="
    ssh_seed "$CLI getbtcburnstats" | jq . || echo "RPC unavailable"
}

cmd_search() {
    local SEARCH_TXID="$1"
    echo "=========================================="
    echo "  Burnclaimdb Search (Seed)"
    echo "=========================================="
    echo ""

    local ALL_CLAIMS
    ALL_CLAIMS=$(ssh_seed "$CLI listburnclaims all 1000 0") || {
        echo "ERROR: Cannot reach Seed or RPC failed"
        exit 1
    }

    local TOTAL=$(echo "$ALL_CLAIMS" | jq 'length')
    echo "Total burns in burnclaimdb: $TOTAL"
    echo ""
    echo "Searching for: $SEARCH_TXID"
    echo "---"
    local MATCH
    MATCH=$(echo "$ALL_CLAIMS" | jq -r ".[] | select(.btc_txid | contains(\"$SEARCH_TXID\"))")
    if [ -z "$MATCH" ]; then
        echo "NOT FOUND in burnclaimdb!"
    else
        echo "$MATCH" | jq .
    fi
}

cmd_diagnose() {
    echo "=========================================="
    echo "  Burn Claim Daemon - Full Diagnostic"
    echo "=========================================="
    echo ""

    # 1. Daemon process
    echo "--- Daemon Process ---"
    ssh_seed 'pgrep -af "btc_burn_claim_daemon" || echo "NOT RUNNING"'
    echo ""

    # 2. Scan progress (F3 DB)
    echo "--- Scan Progress (getburnscanstatus) ---"
    ssh_seed "$CLI getburnscanstatus" | jq . 2>/dev/null || echo "RPC not available"
    echo ""

    # 3. BTC SPV tip vs scan progress
    echo "--- SPV Headers Status ---"
    ssh_seed "$CLI getbtcheadersstatus" | jq '{tip_height, headers_ahead, best_chain_tip}' 2>/dev/null || echo "RPC not available"
    echo ""

    # 4. Legacy statefile
    echo "--- Legacy Statefile ---"
    ssh_seed 'if [ -f /tmp/btc_burn_claim_daemon.state ]; then echo "last_scanned=$(cat /tmp/btc_burn_claim_daemon.state)"; else echo "NOT FOUND"; fi'
    echo ""

    # 5. Burnclaimdb summary
    echo "--- Burnclaimdb Summary ---"
    ssh_seed "$CLI getbtcburnstats" | jq '{total_records, total_pending, total_final, total_orphaned}' 2>/dev/null || echo "RPC not available"
    echo ""

    # 6. Max claimed BTC height (to see where daemon stopped)
    echo "--- Max Claimed BTC Height ---"
    ssh_seed "$CLI listburnclaims all 1000 0" | jq '[.[] | .btc_height] | max' 2>/dev/null || echo "Cannot determine"
    echo ""

    # 7. Daemon log (last 30 lines)
    echo "--- Daemon Log (last 30 lines) ---"
    ssh_seed 'if [ -f /tmp/btc_burn_claim_daemon.log ]; then tail -30 /tmp/btc_burn_claim_daemon.log; else echo "NO LOG FILE"; fi'
    echo ""

    # 8. BTC Signet connectivity
    echo "--- BTC Signet Node ---"
    ssh_seed '~/bitcoin-27.0/bin/bitcoin-cli -conf=~/.bitcoin-signet/bitcoin.conf getblockcount' 2>/dev/null || echo "UNREACHABLE"
    echo ""

    # 9. Check if the 2 missing burns are visible to BTC node
    echo "--- BTC Signet: Check for post-genesis burns ---"
    ssh_seed '
        BTC_CMD="~/bitcoin-27.0/bin/bitcoin-cli -conf=~/.bitcoin-signet/bitcoin.conf"
        BTC_TIP=$($BTC_CMD getblockcount 2>/dev/null)
        echo "BTC tip: $BTC_TIP"
        echo ""
        # Check blocks around the 2 known burns (290561, 290668)
        for HEIGHT in 290561 290668; do
            HASH=$($BTC_CMD getblockhash $HEIGHT 2>/dev/null) || { echo "Height $HEIGHT: cannot get hash"; continue; }
            BLOCK=$($BTC_CMD getblock "$HASH" 2 2>/dev/null) || { echo "Height $HEIGHT: cannot get block"; continue; }
            # Look for OP_RETURN with BATHRON magic
            BURNS=$(echo "$BLOCK" | jq -r ".tx[] | select(.vout[]?.scriptPubKey.asm | test(\"OP_RETURN\")) | .txid" 2>/dev/null)
            if [ -n "$BURNS" ]; then
                echo "Height $HEIGHT: Found TXs with OP_RETURN:"
                for TXID in $BURNS; do
                    RAW=$($BTC_CMD getrawtransaction "$TXID" 2>/dev/null)
                    if echo "$RAW" | grep -qi "42415448524f4e"; then
                        echo "  BATHRON BURN: $TXID"
                    else
                        echo "  (not BATHRON): $TXID"
                    fi
                done
            else
                echo "Height $HEIGHT: No OP_RETURN TXs found"
            fi
        done
    '
}

# Route command
case "$CMD" in
    diagnose|diag)
        cmd_diagnose
        ;;
    list)
        cmd_list
        ;;
    *)
        # Treat as txid search
        cmd_search "$CMD"
        ;;
esac
