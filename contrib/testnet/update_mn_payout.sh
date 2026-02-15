#!/bin/bash
# Update MN payout address to link a LP as Tier 1 (MN Verified)
#
# Architecture:
#   Cold (owner/collateral) = unique per MN (keys in operators.json on Seed)
#   Hot MN (operator)       = bathrond on Seed (shared operator key)
#   Hot LP (payout)         = alice on OP1 (or dev on OP2)
#
# Uses protx_update_registrar with owner WIF from operators.json.
#
# Usage:
#   ./update_mn_payout.sh              # Set 1 MN payout → alice (LP1)
#   ./update_mn_payout.sh status       # Show current MN payout addresses
#   ./update_mn_payout.sh lp2          # Set 1 MN payout → dev (LP2)
#   ./update_mn_payout.sh both         # Set 1 MN payout → alice, 1 → dev

set -uo pipefail

SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

SEED_IP="57.131.33.151"
SEED_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
DEV_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"

CMD="${1:-apply}"

# Get protx list from Seed
get_protx_list() {
    local LIST=$($SSH ubuntu@$SEED_IP "$SEED_CLI protx_list" 2>&1)
    if [ -z "$LIST" ] || echo "$LIST" | grep -q "error code"; then
        echo "ERROR: Could not get protx list" >&2
        echo "$LIST" >&2
        return 1
    fi
    echo "$LIST"
}

# Get operators.json from Seed (contains owner WIFs per MN)
get_operators_json() {
    $SSH ubuntu@$SEED_IP "cat ~/.BathronKey/operators.json 2>/dev/null" 2>/dev/null
}

# Find owner WIF for a given proTxHash from operators.json
get_owner_wif() {
    local PROTX_HASH="$1"
    local OPS_JSON="$2"
    echo "$OPS_JSON" | jq -r ".masternodes[] | select(.proTxHash == \"$PROTX_HASH\") | .owner_wif // empty" 2>/dev/null
}

# Update payout on one MN
# Args: $1=proTxHash $2=operatorPubKey $3=votingAddr $4=targetAddr $5=targetName $6=ownerWif
update_payout() {
    local PROTX_HASH="$1"
    local OP_PUB="$2"
    local VOTING_ADDR="$3"
    local TARGET_ADDR="$4"
    local TARGET_NAME="$5"
    local OWNER_WIF="$6"

    echo "  Updating MN ${PROTX_HASH:0:16}..."
    echo "    new payout: $TARGET_ADDR ($TARGET_NAME)"

    # protx_update_registrar <proTxHash> <operatorPubKey> <votingAddress> <payoutAddress> <ownerKey>
    RESULT=$($SSH ubuntu@$SEED_IP "$SEED_CLI protx_update_registrar $PROTX_HASH $OP_PUB $VOTING_ADDR $TARGET_ADDR $OWNER_WIF" 2>&1 </dev/null)

    if echo "$RESULT" | grep -qE '^[0-9a-f]{64}$'; then
        echo "    TX: ${RESULT:0:16}..."
        return 0
    else
        echo "    ERROR: $RESULT"
        return 1
    fi
}

case "$CMD" in

status)
    echo "=== MN Payout Addresses ==="
    echo ""
    PROTX_LIST=$(get_protx_list) || exit 1
    echo "$PROTX_LIST" | jq -r '
        .[] |
        "  MN \(.proTxHash[0:16])... | owner: \(.dmnstate.ownerAddress) | payout: \(.dmnstate.payoutAddress) | op: \(.dmnstate.operatorPubKey[0:16])..."
    ' 2>/dev/null
    echo ""
    echo "Alice (LP1): $ALICE_ADDR"
    echo "Dev (LP2):   $DEV_ADDR"
    echo ""
    ALICE_MATCH=$(echo "$PROTX_LIST" | jq -r "[.[] | select(.dmnstate.payoutAddress == \"$ALICE_ADDR\")] | length" 2>/dev/null)
    DEV_MATCH=$(echo "$PROTX_LIST" | jq -r "[.[] | select(.dmnstate.payoutAddress == \"$DEV_ADDR\")] | length" 2>/dev/null)
    TOTAL=$(echo "$PROTX_LIST" | jq 'length' 2>/dev/null)
    echo "Total MNs: $TOTAL"
    echo "  Paying to alice: ${ALICE_MATCH:-0} (Tier 1 LP1)"
    echo "  Paying to dev:   ${DEV_MATCH:-0} (Tier 1 LP2)"

    # Check operators.json has owner keys
    OPS=$(get_operators_json)
    if [ -n "$OPS" ]; then
        MN_KEY_COUNT=$(echo "$OPS" | jq '.masternodes | length' 2>/dev/null || echo "0")
        echo ""
        echo "Owner keys in operators.json: $MN_KEY_COUNT"
        if [ "$MN_KEY_COUNT" -ge "$TOTAL" ]; then
            echo "  [OK] All owner WIFs available — protx_update_registrar will work"
        else
            echo "  [WARN] Only $MN_KEY_COUNT / $TOTAL owner WIFs — some MNs cannot be updated"
        fi
    else
        echo ""
        echo "  [WARN] operators.json not found on Seed"
    fi
    ;;

apply|lp2|both)
    echo "=== Update MN Payout ==="
    echo ""

    PROTX_LIST=$(get_protx_list) || exit 1
    OPS_JSON=$(get_operators_json)
    TOTAL=$(echo "$PROTX_LIST" | jq 'length' 2>/dev/null)
    echo "Total MNs: $TOTAL"

    if [ -z "$OPS_JSON" ]; then
        echo "ERROR: Cannot read operators.json from Seed"
        exit 1
    fi
    MN_KEY_COUNT=$(echo "$OPS_JSON" | jq '.masternodes | length' 2>/dev/null || echo "0")
    echo "Owner keys available: $MN_KEY_COUNT"
    echo ""

    UPDATED=0
    FAILED=0

    if [ "$CMD" = "both" ]; then
        # Set first available MN → alice, second → dev
        for IDX_TARGET in "0:$ALICE_ADDR:alice (LP1)" "1:$DEV_ADDR:dev (LP2)"; do
            IDX="${IDX_TARGET%%:*}"
            REST="${IDX_TARGET#*:}"
            TADDR="${REST%%:*}"
            TNAME="${REST#*:}"

            MN=$(echo "$PROTX_LIST" | jq -r ".[$IDX]" 2>/dev/null)
            MN_HASH=$(echo "$MN" | jq -r '.proTxHash')
            MN_OP=$(echo "$MN" | jq -r '.dmnstate.operatorPubKey')
            MN_VOTING=$(echo "$MN" | jq -r '.dmnstate.votingAddress')
            OWNER_WIF=$(get_owner_wif "$MN_HASH" "$OPS_JSON")

            if [ -z "$OWNER_WIF" ]; then
                echo "  ERROR: No owner WIF for MN ${MN_HASH:0:16}... — skipping"
                FAILED=$((FAILED + 1))
                continue
            fi

            if update_payout "$MN_HASH" "$MN_OP" "$MN_VOTING" "$TADDR" "$TNAME" "$OWNER_WIF"; then
                UPDATED=$((UPDATED + 1))
            else
                FAILED=$((FAILED + 1))
            fi
            echo ""
        done
    else
        if [ "$CMD" = "lp2" ]; then
            TARGET_ADDR="$DEV_ADDR"
            TARGET_NAME="dev (LP2)"
        else
            TARGET_ADDR="$ALICE_ADDR"
            TARGET_NAME="alice (LP1)"
        fi

        # Check if already done
        ALREADY=$(echo "$PROTX_LIST" | jq -r "[.[] | select(.dmnstate.payoutAddress == \"$TARGET_ADDR\")] | length" 2>/dev/null)
        if [ "${ALREADY:-0}" -gt 0 ]; then
            echo "Already have $ALREADY MN(s) paying to $TARGET_NAME — nothing to do"
            exit 0
        fi

        # Pick last MN (least impact)
        MN_DATA=$(echo "$PROTX_LIST" | jq -r '.[-1]' 2>/dev/null)
        MN_HASH=$(echo "$MN_DATA" | jq -r '.proTxHash')
        MN_OP=$(echo "$MN_DATA" | jq -r '.dmnstate.operatorPubKey')
        MN_VOTING=$(echo "$MN_DATA" | jq -r '.dmnstate.votingAddress')
        OWNER_WIF=$(get_owner_wif "$MN_HASH" "$OPS_JSON")

        if [ -z "$OWNER_WIF" ]; then
            echo "ERROR: No owner WIF for MN ${MN_HASH:0:16}..."
            echo "  Check ~/.BathronKey/operators.json on Seed"
            exit 1
        fi

        if update_payout "$MN_HASH" "$MN_OP" "$MN_VOTING" "$TARGET_ADDR" "$TARGET_NAME" "$OWNER_WIF"; then
            UPDATED=$((UPDATED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
    fi

    echo ""
    echo "Updated: $UPDATED, Failed: $FAILED"

    if [ "$UPDATED" -gt 0 ]; then
        echo "Waiting 70s for confirmation..."
        sleep 70

        # Verify
        echo ""
        echo "=== Verification ==="
        NEW_LIST=$($SSH ubuntu@$SEED_IP "$SEED_CLI protx_list" 2>/dev/null)
        ALICE_MATCH=$(echo "$NEW_LIST" | jq -r "[.[] | select(.dmnstate.payoutAddress == \"$ALICE_ADDR\")] | length" 2>/dev/null)
        DEV_MATCH=$(echo "$NEW_LIST" | jq -r "[.[] | select(.dmnstate.payoutAddress == \"$DEV_ADDR\")] | length" 2>/dev/null)
        echo "  MNs paying to alice: ${ALICE_MATCH:-0}"
        echo "  MNs paying to dev:   ${DEV_MATCH:-0}"

        if [ "${ALICE_MATCH:-0}" -gt 0 ] || [ "${DEV_MATCH:-0}" -gt 0 ]; then
            echo ""
            echo "SUCCESS — LP(s) now have MN-backed payout (Tier 1)"
            echo "Registry will detect within 5 minutes."
        fi
    fi
    ;;

*)
    echo "Usage: $0 [apply|lp2|both|status]"
    echo "  apply   Set 1 MN payout → alice (LP1) [default]"
    echo "  lp2     Set 1 MN payout → dev (LP2)"
    echo "  both    Set 1 MN → alice, 1 MN → dev"
    echo "  status  Show current MN payout addresses"
    exit 1
    ;;
esac
