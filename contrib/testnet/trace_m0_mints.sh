#!/usr/bin/env bash
# trace_m0_mints.sh - Trace all M0 minting transactions in early blocks
# Shows where M0BTC was created and where it went (output addresses)
set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_vps}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

# Range of blocks to scan (default 1-10, override with args)
START_BLOCK=${1:-1}
END_BLOCK=${2:-10}

echo "══════════════════════════════════════════════════════════════"
echo "  TRACE M0 MINTS - Blocks $START_BLOCK to $END_BLOCK"
echo "══════════════════════════════════════════════════════════════"
echo ""

# Get current height first
CURRENT_HEIGHT=$($SSH ubuntu@$SEED_IP "$CLI getblockcount 2>/dev/null" || echo "?")
echo "Current chain height: $CURRENT_HEIGHT"
echo ""

# Clamp END_BLOCK to current height
if [ "$CURRENT_HEIGHT" != "?" ] && [ "$END_BLOCK" -gt "$CURRENT_HEIGHT" ]; then
    END_BLOCK=$CURRENT_HEIGHT
    echo "(Clamped end block to chain tip: $END_BLOCK)"
    echo ""
fi

TOTAL_MINTED=0
TOTAL_FEES=0

for HEIGHT in $(seq "$START_BLOCK" "$END_BLOCK"); do
    HASH=$($SSH ubuntu@$SEED_IP "$CLI getblockhash $HEIGHT 2>/dev/null" || echo "")
    if [ -z "$HASH" ]; then
        echo "Block $HEIGHT: [ERROR] Could not get block hash"
        continue
    fi

    # Get block with verbosity 2 (full tx decode)
    BLOCK=$($SSH ubuntu@$SEED_IP "$CLI getblock $HASH 2 2>/dev/null" || echo "{}")

    TX_COUNT=$(echo "$BLOCK" | jq '.tx | length' 2>/dev/null || echo "0")
    BLOCK_TIME=$(echo "$BLOCK" | jq -r '.time // "?"' 2>/dev/null)
    BLOCK_TIME_HR=$(date -d "@$BLOCK_TIME" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$BLOCK_TIME")

    echo "──────────────────────────────────────────────────────────────"
    echo "BLOCK $HEIGHT  |  hash: ${HASH:0:16}...  |  txs: $TX_COUNT  |  time: $BLOCK_TIME_HR"
    echo "──────────────────────────────────────────────────────────────"

    # Process each transaction
    echo "$BLOCK" | jq -c '.tx[]?' 2>/dev/null | while IFS= read -r TX; do
        TXID=$(echo "$TX" | jq -r '.txid // "?"')
        TX_TYPE=$(echo "$TX" | jq -r '.type // 0')
        TX_VERSION=$(echo "$TX" | jq -r '.version // "?"')

        # Map type number to name
        case "$TX_TYPE" in
            0)  TYPE_NAME="NORMAL" ;;
            1)  TYPE_NAME="PROREG" ;;
            20) TYPE_NAME="TX_LOCK" ;;
            21) TYPE_NAME="TX_UNLOCK" ;;
            22) TYPE_NAME="TX_TRANSFER_M1" ;;
            31) TYPE_NAME="TX_BURN_CLAIM" ;;
            32) TYPE_NAME="TX_MINT_M0BTC" ;;
            33) TYPE_NAME="TX_BTC_HEADERS" ;;
            *)  TYPE_NAME="UNKNOWN($TX_TYPE)" ;;
        esac

        # Check for coinbase
        IS_COINBASE=$(echo "$TX" | jq '[.vin[]? | select(.coinbase != null)] | length' 2>/dev/null || echo "0")
        if [ "$IS_COINBASE" -gt 0 ]; then
            TYPE_NAME="$TYPE_NAME [COINBASE]"
        fi

        echo ""
        echo "  TX: ${TXID:0:16}...  |  type: $TX_TYPE ($TYPE_NAME)  |  ver: $TX_VERSION"

        # Show m0_fee_info if present
        FEE_INFO=$(echo "$TX" | jq '.m0_fee_info // empty' 2>/dev/null || true)
        if [ -n "$FEE_INFO" ]; then
            M0_IN=$(echo "$FEE_INFO" | jq -r '.m0_in // 0')
            M0_OUT=$(echo "$FEE_INFO" | jq -r '.m0_out // 0')
            M0_FEE=$(echo "$FEE_INFO" | jq -r '.m0_fee // 0')
            VAULT_IN=$(echo "$FEE_INFO" | jq -r '.vault_in // 0')
            VAULT_OUT=$(echo "$FEE_INFO" | jq -r '.vault_out // 0')
            echo "  m0_fee_info: m0_in=$M0_IN m0_out=$M0_OUT vault_in=$VAULT_IN vault_out=$VAULT_OUT fee=$M0_FEE"
        fi

        # Show extra_payload if present (for special TXs)
        EXTRA=$(echo "$TX" | jq '.extra_payload // empty' 2>/dev/null || true)
        if [ -n "$EXTRA" ]; then
            echo "  extra_payload: $(echo "$EXTRA" | jq -c '.' 2>/dev/null || echo "$EXTRA")"
        fi

        # Show vin summary
        VIN_COUNT=$(echo "$TX" | jq '.vin | length' 2>/dev/null || echo "0")
        echo "  vin: $VIN_COUNT inputs"
        echo "$TX" | jq -r '.vin[]? | if .coinbase then "    [coinbase] \(.coinbase[:40])..." else "    \(.txid[:16])...:vout=\(.vout)" end' 2>/dev/null || true

        # Show vout details (this is what we really want)
        VOUT_COUNT=$(echo "$TX" | jq '.vout | length' 2>/dev/null || echo "0")
        echo "  vout: $VOUT_COUNT outputs"

        echo "$TX" | jq -r '
            .vout[]? |
            "    [\(.n)] " +
            (.value | tostring) + " M0  →  " +
            (
                if .scriptPubKey.addresses then
                    (.scriptPubKey.addresses | join(", "))
                elif .scriptPubKey.address then
                    .scriptPubKey.address
                elif .scriptPubKey.type == "nulldata" then
                    "OP_RETURN"
                else
                    .scriptPubKey.type // "unknown"
                end
            )
        ' 2>/dev/null || true

        # Calculate total output for this TX
        TX_TOTAL=$(echo "$TX" | jq '[.vout[]?.value // 0] | add // 0' 2>/dev/null || echo "0")
        echo "  total output: $TX_TOTAL M0"
    done

    echo ""
done

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  SUMMARY"
echo "══════════════════════════════════════════════════════════════"

# Second pass for summary (can't easily accumulate in subshell above)
echo ""
echo "Mint transactions found:"
for HEIGHT in $(seq "$START_BLOCK" "$END_BLOCK"); do
    HASH=$($SSH ubuntu@$SEED_IP "$CLI getblockhash $HEIGHT 2>/dev/null" || echo "")
    [ -z "$HASH" ] && continue

    BLOCK=$($SSH ubuntu@$SEED_IP "$CLI getblock $HASH 2 2>/dev/null" || echo "{}")

    # Find TX_MINT_M0BTC (type 32)
    MINTS=$(echo "$BLOCK" | jq -c '[.tx[]? | select(.type == 32)]' 2>/dev/null || echo "[]")
    MINT_COUNT=$(echo "$MINTS" | jq 'length' 2>/dev/null || echo "0")

    if [ "$MINT_COUNT" -gt 0 ]; then
        MINT_TOTAL=$(echo "$MINTS" | jq '[.[]?.vout[]?.value // 0] | add // 0' 2>/dev/null || echo "0")
        echo "  Block $HEIGHT: $MINT_COUNT TX_MINT_M0BTC(s), total value: $MINT_TOTAL M0"

        # Show destination addresses
        echo "$MINTS" | jq -r '
            .[]? | .vout[]? |
            select(.value > 0) |
            "    → " + (.value | tostring) + " M0 to " +
            (
                if .scriptPubKey.addresses then
                    (.scriptPubKey.addresses | join(", "))
                elif .scriptPubKey.address then
                    .scriptPubKey.address
                else
                    "unknown"
                end
            )
        ' 2>/dev/null || true
    fi

    # Also show TX_BURN_CLAIM (type 31) 
    BURNS=$(echo "$BLOCK" | jq -c '[.tx[]? | select(.type == 31)]' 2>/dev/null || echo "[]")
    BURN_COUNT=$(echo "$BURNS" | jq 'length' 2>/dev/null || echo "0")
    if [ "$BURN_COUNT" -gt 0 ]; then
        echo "  Block $HEIGHT: $BURN_COUNT TX_BURN_CLAIM(s)"
    fi

    # Also show PROREG (type 1)
    PROREGS=$(echo "$BLOCK" | jq -c '[.tx[]? | select(.type == 1)]' 2>/dev/null || echo "[]")
    PROREG_COUNT=$(echo "$PROREGS" | jq 'length' 2>/dev/null || echo "0")
    if [ "$PROREG_COUNT" -gt 0 ]; then
        echo "  Block $HEIGHT: $PROREG_COUNT PROREG(s)"
    fi
done

echo ""
echo "Current chain state:"
$SSH ubuntu@$SEED_IP "$CLI getstate 2>/dev/null" | jq '{height, supply, settlement_state: .settlement_state}' 2>/dev/null || echo "[Could not fetch state]"

echo ""
echo "Done."
