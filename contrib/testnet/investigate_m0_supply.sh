#!/bin/bash
set -euo pipefail

SEED_IP="57.131.33.151"
SEED_USER="ubuntu"
BATHRON_CLI="~/bathron-cli -testnet"
BTC_CLI="~/bitcoin-27.0/bin/bitcoin-cli -datadir=~/.bitcoin-signet"

echo "==================================================================================="
echo "M0 SUPPLY INVESTIGATION - Consensus Invariant A5 Verification"
echo "==================================================================================="
echo ""

echo "[1] BATHRON Chain State"
echo "----------------------------"
ssh ${SEED_USER}@${SEED_IP} "${BATHRON_CLI} getstate" | tee /tmp/bathron_state.json
echo ""

echo "[2] All Burn Claims on BATHRON"
echo "----------------------------"
ssh ${SEED_USER}@${SEED_IP} "${BATHRON_CLI} listburnclaims all 100" | tee /tmp/burn_claims.json
echo ""

echo "[3] Check for Coinbase Rewards (should be 0)"
echo "----------------------------"
for height in {0..10}; do
    echo -n "Block $height: "
    ssh ${SEED_USER}@${SEED_IP} "${BATHRON_CLI} getblock \$(${BATHRON_CLI} getblockhash $height)" | grep -E '"coinbase":|"reward":' || echo "N/A"
done
echo ""

echo "[4] All TX_MINT_M0BTC Transactions"
echo "----------------------------"
ssh ${SEED_USER}@${SEED_IP} "${BATHRON_CLI} getblockcount" > /tmp/tip_height.txt
TIP_HEIGHT=$(cat /tmp/tip_height.txt)
echo "Scanning blocks 0 to $TIP_HEIGHT for TX_MINT_M0BTC..."

for height in $(seq 0 $TIP_HEIGHT); do
    BLOCK_HASH=$(ssh ${SEED_USER}@${SEED_IP} "${BATHRON_CLI} getblockhash $height")
    BLOCK=$(ssh ${SEED_USER}@${SEED_IP} "${BATHRON_CLI} getblock $BLOCK_HASH 2")
    
    # Check for TX_MINT_M0BTC (type 32)
    MINT_TXS=$(echo "$BLOCK" | jq -r '.tx[] | select(.type == 32) | "\(.txid) - \(.vout[].value) sats"')
    
    if [ -n "$MINT_TXS" ]; then
        echo "Block $height:"
        echo "$MINT_TXS"
    fi
done
echo ""

echo "[5] BTC Signet Burn Scan"
echo "----------------------------"
echo "Scanning BTC Signet from height 286000 to current tip..."

# Get BTC tip
BTC_TIP=$(ssh ${SEED_USER}@${SEED_IP} "${BTC_CLI} getblockcount")
echo "BTC Signet tip: $BTC_TIP"
echo ""

# BATHRON magic in hex: BATHRON (42415448524f4e)
MAGIC="42415448524f4e"

echo "Searching for OP_RETURN with BATHRON magic..."
TOTAL_BURNS=0

for height in $(seq 286000 $BTC_TIP); do
    BLOCK_HASH=$(ssh ${SEED_USER}@${SEED_IP} "${BTC_CLI} getblockhash $height")
    BLOCK=$(ssh ${SEED_USER}@${SEED_IP} "${BTC_CLI} getblock $BLOCK_HASH 2")
    
    # Check each transaction for OP_RETURN with BATHRON magic
    echo "$BLOCK" | jq -r --arg magic "$MAGIC" '
        .tx[] | 
        select(.vout[].scriptPubKey.asm | strings | contains("OP_RETURN")) |
        select(.vout[].scriptPubKey.hex | strings | contains($magic)) |
        {
            txid: .txid,
            height: .height // '$height',
            vout: [.vout[] | select(.scriptPubKey.asm | strings | contains("OP_RETURN"))]
        }
    ' 2>/dev/null || true
    
    if [ $((height % 1000)) -eq 0 ]; then
        echo "  ... scanned up to height $height"
    fi
done

echo ""
echo "[6] Summary Analysis"
echo "----------------------------"

# Parse getstate output
M0_TOTAL=$(jq -r '.m0_total // 0' /tmp/bathron_state.json)
M0_VAULTED=$(jq -r '.m0_vaulted // 0' /tmp/bathron_state.json)
M1_SUPPLY=$(jq -r '.m1_supply // 0' /tmp/bathron_state.json)

echo "M0 Total Supply: $M0_TOTAL sats"
echo "M0 Vaulted: $M0_VAULTED sats"
echo "M1 Supply: $M1_SUPPLY sats"
echo ""

# Count burn claims
BURN_CLAIM_COUNT=$(jq -r 'length' /tmp/burn_claims.json 2>/dev/null || echo 0)
echo "Total Burn Claims: $BURN_CLAIM_COUNT"

if [ -f /tmp/burn_claims.json ]; then
    TOTAL_CLAIMED=$(jq -r '[.[].amount] | add // 0' /tmp/burn_claims.json)
    echo "Total M0 from Burns: $TOTAL_CLAIMED sats"
    echo ""
    
    DISCREPANCY=$((M0_TOTAL - TOTAL_CLAIMED))
    echo "DISCREPANCY: $DISCREPANCY sats"
    
    if [ $DISCREPANCY -ne 0 ]; then
        echo ""
        echo "⚠️  CONSENSUS VIOLATION DETECTED ⚠️"
        echo "A5 violated: M0_total should equal sum of burn claims only"
        echo "Extra M0 created: $DISCREPANCY sats"
    else
        echo "✓ A5 satisfied: M0_total = BurnClaims"
    fi
fi

echo ""
echo "Investigation complete. Check output above for source of discrepancy."
