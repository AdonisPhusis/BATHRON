#!/bin/bash
# ==============================================================================
# scan_btc_burns.sh - Scan BTC Signet for ALL BATHRON burns
# ==============================================================================

set -euo pipefail

# SSH config
SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# BTC CLI path on Seed
BTC_CLI="~/bitcoin-27.0/bin/bitcoin-cli -datadir=~/.bitcoin-signet"

# BATHRON OP_RETURN marker (hex for "BATHRON|01|")
BATHRON_HEX_PREFIX="42415448524f4e7c3031"

# Scan range
START_HEIGHT=${1:-286000}
END_HEIGHT=${2:-289000}

echo "=========================================="
echo "Scanning BTC Signet for BATHRON Burns"
echo "=========================================="
echo "Block range: $START_HEIGHT to $END_HEIGHT"
echo "Looking for OP_RETURN with prefix: $BATHRON_HEX_PREFIX"
echo ""

# Check BTC connectivity
echo "Checking BTC Signet connectivity..."
BTC_TIP=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "$BTC_CLI getblockchaininfo 2>&1" | jq -r '.blocks // empty')

if [ -z "$BTC_TIP" ]; then
    echo "ERROR: Cannot connect to BTC Signet on Seed node"
    exit 1
fi

echo "BTC Signet tip: $BTC_TIP"
echo ""

# Output file
OUTPUT_FILE="/tmp/bathron_burns_scan_$(date +%Y%m%d_%H%M%S).txt"
echo "Results will be saved to: $OUTPUT_FILE"
echo ""

# Scan
TOTAL_BURNS=0
TOTAL_SATS=0

{
    echo "# BATHRON Burn Scan Results"
    echo "# Scan range: $START_HEIGHT to $END_HEIGHT"
    echo "# Generated: $(date)"
    echo ""
    echo "TXID|Height|Burn_Sats|Dest_Hash160"
    echo "----"
} > "$OUTPUT_FILE"

echo "Scanning..."

for ((height=START_HEIGHT; height<=END_HEIGHT; height++)); do
    # Progress every 100 blocks
    if [ $((height % 100)) -eq 0 ]; then
        echo "  Progress: $height / $END_HEIGHT (found $TOTAL_BURNS burns, $TOTAL_SATS sats)"
    fi
    
    # Get block hash
    BLOCK_HASH=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "$BTC_CLI getblockhash $height 2>/dev/null" || echo "")
    
    if [ -z "$BLOCK_HASH" ]; then
        continue
    fi
    
    # Get block with TX details (verbosity 2)
    BLOCK_DATA=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "$BTC_CLI getblock '$BLOCK_HASH' 2 2>/dev/null" || echo "{}")
    
    # Extract TXs that might have BATHRON burns
    TXIDS=$(echo "$BLOCK_DATA" | jq -r '.tx[]? | select(.vout[]? | .scriptPubKey.type == "nulldata") | .txid' 2>/dev/null || echo "")
    
    for txid in $TXIDS; do
        # Get full TX
        TX_JSON=$(echo "$BLOCK_DATA" | jq ".tx[] | select(.txid == \"$txid\")")
        
        # Check for BATHRON OP_RETURN
        OP_RETURN_HEX=$(echo "$TX_JSON" | jq -r '.vout[]? | select(.scriptPubKey.type == "nulldata") | .scriptPubKey.hex' 2>/dev/null || echo "")
        
        if echo "$OP_RETURN_HEX" | grep -qi "^6a.*$BATHRON_HEX_PREFIX"; then
            # Extract burn amount (P2WSH unspendable)
            BURN_AMOUNT=$(echo "$TX_JSON" | jq '[.vout[]? | select(.scriptPubKey.type == "witness_v0_scripthash" and .scriptPubKey.hex == "00206e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d") | .value] | add // 0')
            
            BURN_SATS=$(printf "%.0f" $(echo "$BURN_AMOUNT * 100000000" | bc -l))
            
            # Extract dest_hash160 from OP_RETURN
            # Format: 6a [len] 42415448524f4e7c30317c5349474e45547c [hash160]
            DEST_HASH160=$(echo "$OP_RETURN_HEX" | grep -oP "$BATHRON_HEX_PREFIX.{40}" | tail -c 41 || echo "unknown")
            
            echo "$txid|$height|$BURN_SATS|$DEST_HASH160" >> "$OUTPUT_FILE"
            
            TOTAL_BURNS=$((TOTAL_BURNS + 1))
            TOTAL_SATS=$((TOTAL_SATS + BURN_SATS))
            
            echo "  Found: $txid ($BURN_SATS sats)"
        fi
    done
done

echo ""
echo "=========================================="
echo "Scan Complete"
echo "=========================================="
echo "Total burns found: $TOTAL_BURNS"
echo "Total burned: $TOTAL_SATS sats"
echo "Results saved to: $OUTPUT_FILE"
echo ""

{
    echo ""
    echo "# SUMMARY"
    echo "Total burns: $TOTAL_BURNS"
    echo "Total sats: $TOTAL_SATS"
} >> "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
