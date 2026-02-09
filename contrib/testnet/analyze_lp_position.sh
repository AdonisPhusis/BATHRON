#!/bin/bash
# Detailed LP position analysis with HTLC expiry tracking

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"

echo "=========================================="
echo "   LP POSITION ANALYSIS"
echo "=========================================="
echo ""

# Get current block height
CURRENT_HEIGHT=$(ssh $SSH_OPTS ubuntu@$OP1_IP '/home/ubuntu/bathron-cli -testnet getblockcount' 2>&1)
echo "Current Block Height: $CURRENT_HEIGHT"
echo ""

# Get detailed HTLC info
echo "=== HTLC STATUS BREAKDOWN ==="
HTLC_JSON=$(ssh $SSH_OPTS ubuntu@$OP1_IP '/home/ubuntu/bathron-cli -testnet htlc_list active' 2>&1)

if echo "$HTLC_JSON" | grep -q "outpoint"; then
    echo "$HTLC_JSON" | jq -r --arg height "$CURRENT_HEIGHT" '
        def blocks_left: (.expiry_height - ($height | tonumber));
        
        group_by(.status) |
        map({
            status: .[0].status,
            count: length,
            total: (map(.amount) | add),
            htlcs: map({
                amount: .amount,
                expiry: .expiry_height,
                blocks_left: blocks_left,
                hashlock: .hashlock[0:16]
            })
        }) |
        .[] |
        "  Status: \(.status)",
        "  Count: \(.count)",
        "  Total: \(.total) sats",
        "  HTLCs:",
        (.htlcs[] | "    - \(.amount) sats (expires block \(.expiry), \(.blocks_left) blocks left, hash: \(.hashlock)...)"),
        ""
    ' 2>/dev/null || {
        echo "$HTLC_JSON" | grep -A 6 '"outpoint"' | while read -r line; do
            if echo "$line" | grep -q '"amount"'; then
                AMT=$(echo "$line" | awk '{print $2}' | tr -d ',')
                echo "    Amount: $AMT sats"
            elif echo "$line" | grep -q '"expiry_height"'; then
                EXP=$(echo "$line" | awk '{print $2}' | tr -d ',')
                BLOCKS_LEFT=$((EXP - CURRENT_HEIGHT))
                echo "    Expiry: $EXP (${BLOCKS_LEFT} blocks left)"
            fi
        done
    }
else
    echo "  No active HTLCs"
fi

echo ""
echo "=== RISK ASSESSMENT ==="

# Check for soon-to-expire HTLCs
EXPIRING_SOON=$(echo "$HTLC_JSON" | jq --arg height "$CURRENT_HEIGHT" '[.[] | select((.expiry_height - ($height | tonumber)) < 50)] | length' 2>/dev/null || echo "0")

if [ "$EXPIRING_SOON" -gt 0 ]; then
    echo "  ⚠️  WARNING: $EXPIRING_SOON HTLC(s) expiring in < 50 blocks"
    echo "     These should be claimed or will refund"
else
    echo "  ✓ No HTLCs expiring soon (< 50 blocks)"
fi

echo ""
echo "=========================================="
