#!/bin/bash
# ==============================================================================
# find_missing_burn.sh - Scan BTC Signet for missing BATHRON burn
# ==============================================================================
#
# Searches block range 286000-289000 for BATHRON OP_RETURN burns
# that are NOT in genesis_burns.json
#
# Usage: ./find_missing_burn.sh
# ==============================================================================

set -e

# SSH config
SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# BTC CLI path on Seed
BTC_CLI="~/bitcoin-27.0/bin/bitcoin-cli -datadir=~/.bitcoin-signet"

# Known 10,000 sat burns (from genesis_burns.json)
KNOWN_10K_TXIDS=(
    "089706dba86ef5e99a0303a7db57a65f7c2c5175fdbba176eb241466a73d97a8"
    "13594dd766257cc674e8143cabcdb8093e3a9ecb13ca5f8dae6bff7fe19c5033"
    "e6d16a4bbc45703dba5aafb569370cc9e86c8014fa2230299c1363a50e8847c9"
    "e807051674f4f45ff9c29b617faccff6066b8f5ae39f20e5af493b081c39220f"
    "dbe9ae88b1f546e21492327ca28414040ec5b97d142b81348c60776e481135bc"
)

# BATHRON OP_RETURN marker (hex for "BATHRON|01|SIGNET|")
BATHRON_HEX_PREFIX="42415448524f4e7c30317c5349474e45547c"

echo "=========================================="
echo "Scanning BTC Signet for Missing BATHRON Burn"
echo "=========================================="
echo ""
echo "Block range: 286000-289000"
echo "Looking for: ~10,000 sat burns NOT in genesis_burns.json"
echo ""

# Get current BTC tip
echo "Checking BTC Signet status..."
BTC_TIP=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "$BTC_CLI getblockchaininfo | jq -r '.blocks'")
echo "BTC Signet tip: $BTC_TIP"
echo ""

# Scan block range
START_HEIGHT=286000
END_HEIGHT=289000

echo "Scanning blocks $START_HEIGHT to $END_HEIGHT..."
echo ""

FOUND_BURNS=0
MISSING_BURNS=0

for ((height=START_HEIGHT; height<=END_HEIGHT; height++)); do
    # Progress indicator every 100 blocks
    if [ $((height % 100)) -eq 0 ]; then
        echo "Progress: $height / $END_HEIGHT"
    fi
    
    # Get block hash
    BLOCK_HASH=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "$BTC_CLI getblockhash $height 2>/dev/null" || echo "")
    
    if [ -z "$BLOCK_HASH" ]; then
        continue
    fi
    
    # Get block with full TX details
    BLOCK_JSON=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "$BTC_CLI getblock $BLOCK_HASH 2 2>/dev/null" || echo "{}")
    
    # Extract all TXIDs
    TXIDS=$(echo "$BLOCK_JSON" | jq -r '.tx[]? | .txid' 2>/dev/null || echo "")
    
    for txid in $TXIDS; do
        # Get raw TX
        TX_JSON=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$SEED_IP "$BTC_CLI getrawtransaction $txid true 2>/dev/null" || echo "{}")
        
        # Check for BATHRON OP_RETURN in vout
        HAS_BATHRON=$(echo "$TX_JSON" | jq -r '.vout[]? | select(.scriptPubKey.type == "nulldata") | .scriptPubKey.hex' 2>/dev/null | grep -i "$BATHRON_HEX_PREFIX" || echo "")
        
        if [ -n "$HAS_BATHRON" ]; then
            FOUND_BURNS=$((FOUND_BURNS + 1))
            
            # Check if this txid is in known list
            IS_KNOWN=0
            for known_txid in "${KNOWN_10K_TXIDS[@]}"; do
                if [ "$txid" == "$known_txid" ]; then
                    IS_KNOWN=1
                    break
                fi
            done
            
            # Extract burn amount (sum of P2WSH unspendable outputs)
            BURN_AMOUNT=$(echo "$TX_JSON" | jq '[.vout[]? | select(.scriptPubKey.type == "witness_v0_scripthash" and .scriptPubKey.hex == "00206e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d") | .value] | add // 0' 2>/dev/null)
            
            # Convert to sats
            BURN_SATS=$(echo "$BURN_AMOUNT * 100000000" | bc | cut -d'.' -f1)
            
            if [ $IS_KNOWN -eq 0 ]; then
                MISSING_BURNS=$((MISSING_BURNS + 1))
                echo ""
                echo "=========================================="
                echo "MISSING BURN FOUND!"
                echo "=========================================="
                echo "TXID:   $txid"
                echo "Height: $height"
                echo "Amount: $BURN_SATS sats"
                echo "OP_RETURN: $(echo "$TX_JSON" | jq -r '.vout[]? | select(.scriptPubKey.type == "nulldata") | .scriptPubKey.hex')"
                echo ""
            fi
        fi
    done
done

echo ""
echo "=========================================="
echo "Scan Complete"
echo "=========================================="
echo "Total BATHRON burns found: $FOUND_BURNS"
echo "Missing from genesis_burns.json: $MISSING_BURNS"
echo ""

if [ $MISSING_BURNS -eq 0 ]; then
    echo "No missing burns detected. The discrepancy may be due to:"
    echo "1. Rounding errors in genesis_burns.json"
    echo "2. Burns outside the scanned range"
    echo "3. Different burn amount calculation method"
fi
