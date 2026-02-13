#!/bin/bash
# Quick burn minting status check (no block iteration)

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
CLI="~/BATHRON-Core/src/bathron-cli -testnet"

echo "=========================================="
echo "BURN MINTING STATUS (QUICK CHECK)"
echo "=========================================="
echo ""

# Get current block height
BLOCK_HEIGHT=$($SSH ubuntu@$SEED_IP "$CLI getblockcount 2>/dev/null" || echo "0")
echo "Current block height: $BLOCK_HEIGHT"
echo ""

# Get burn stats
echo "=== Burn Statistics ==="
BURN_STATS=$($SSH ubuntu@$SEED_IP "$CLI getbtcburnstats 2>/dev/null" || echo "{}")
echo "$BURN_STATS" | jq .
echo ""

# Get wallet state to see actual M0 balance
echo "=== Wallet State (M0 balance) ==="
WALLET_STATE=$($SSH ubuntu@$SEED_IP "$CLI getwalletstate 2>/dev/null" || echo "{}")
M0_BALANCE=$(echo "$WALLET_STATE" | jq -r '.m0_balance // 0')
echo "M0 balance in wallet: $M0_BALANCE"
echo ""

# Get global state
echo "=== Global State ==="
GLOBAL_STATE=$($SSH ubuntu@$SEED_IP "$CLI getstate 2>/dev/null" || echo "{}")
M0_TOTAL=$(echo "$GLOBAL_STATE" | jq -r '.m0_total // 0')
echo "M0 total supply: $M0_TOTAL"
echo ""

# Check genesis burns total
GENESIS_BURNS="/home/ubuntu/BATHRON/contrib/testnet/genesis_burns.json"
EXPECTED_TOTAL=$(jq '[.burns[].amount] | add' "$GENESIS_BURNS")

# Parse burn stats
M0BTC_SUPPLY=$(echo "$BURN_STATS" | jq -r '.m0btc_supply // 0')
M0BTC_PENDING=$(echo "$BURN_STATS" | jq -r '.m0btc_pending // 0')
TOTAL_PENDING=$(echo "$BURN_STATS" | jq -r '.total_pending // 0')
K_CONFIRMATIONS=$(echo "$BURN_STATS" | jq -r '.k_confirmations // 6')

echo "=== Summary ==="
echo "Expected from genesis_burns.json: $EXPECTED_TOTAL sats"
echo "M0BTC supply (minted): $M0BTC_SUPPLY sats"
echo "M0BTC pending: $M0BTC_PENDING sats"
echo "Total accounted: $((M0BTC_SUPPLY + M0BTC_PENDING)) sats"
echo ""
echo "M0 total (global state): $M0_TOTAL sats"
echo "M0 in wallet: $M0_BALANCE sats"
echo ""

MISSING=$((EXPECTED_TOTAL - M0BTC_SUPPLY - M0BTC_PENDING))
echo "Unaccounted: $MISSING sats"
echo ""

if [ "$TOTAL_PENDING" -gt 0 ]; then
    echo "Note: $TOTAL_PENDING burn claims are pending"
    echo "      Waiting for K=$K_CONFIRMATIONS confirmations"
    echo "      Current height: $BLOCK_HEIGHT"
    echo ""
    echo "Action: Mine at least $K_CONFIRMATIONS more blocks to finalize pending burns"
fi

# Check debug log for minting events
echo "=== Recent Minting Events (debug.log) ==="
$SSH ubuntu@$SEED_IP "grep -i 'TX_MINT_M0BTC\|CreateMintM0BTC' ~/.bathron/testnet5/debug.log 2>/dev/null | tail -10" || echo "No minting events found"

echo ""
echo "=========================================="
