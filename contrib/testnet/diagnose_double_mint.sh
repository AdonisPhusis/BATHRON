#!/bin/bash
set -e

SEED_IP="57.131.33.151"
KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== TX_MINT_M0BTC DOUBLE-MINT DIAGNOSTIC ==="
echo

# Find all blocks with TX_MINT_M0BTC
echo "Scanning blocks 1-149 for TX_MINT_M0BTC..."
echo

ssh -i "$KEY" ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
TOTAL_MINTED=0
declare -A MINT_TXS

for i in $(seq 1 149); do
  BLOCK=$(/home/ubuntu/bathron-cli -testnet getblockhash $i)
  BLOCK_DATA=$(/home/ubuntu/bathron-cli -testnet getblock "$BLOCK" 2)
  
  # Count TX_MINT_M0BTC in this block
  MINT_COUNT=$(echo "$BLOCK_DATA" | jq '[.tx[] | select(.type == 32)] | length')
  
  if [ "$MINT_COUNT" != "0" ]; then
    echo "Block $i: $MINT_COUNT TX_MINT_M0BTC"
    
    # Extract txids and amounts
    TXIDS=$(echo "$BLOCK_DATA" | jq -r '.tx[] | select(.type == 32) | .txid')
    
    for TXID in $TXIDS; do
      # Get total minted amount
      AMOUNT=$(/home/ubuntu/bathron-cli -testnet getrawtransaction "$TXID" true | jq '[.vout[].value] | add')
      echo "  TXID: $TXID"
      echo "  Amount: $AMOUNT"
      
      # Accumulate total
      TOTAL_MINTED=$(echo "$TOTAL_MINTED + $AMOUNT" | bc)
      
      # Store for duplicate detection
      MINT_TXS["$TXID"]=1
    done
    echo
  fi
done

echo "=== SUMMARY ==="
echo "Total minted across all TX_MINT_M0BTC: $TOTAL_MINTED"
echo "Expected (from burns): 14505000"
echo "Difference: $(echo "$TOTAL_MINTED - 14505000" | bc)"
echo
echo "Unique TX_MINT_M0BTC transactions: ${#MINT_TXS[@]}"
REMOTE

echo
echo "=== ANALYSIS ==="
echo "If Total Minted > 14,505,000 → DOUBLE-MINT BUG CONFIRMED"
echo "If Difference = 14,505,000 → Burns minted twice (2x)"
