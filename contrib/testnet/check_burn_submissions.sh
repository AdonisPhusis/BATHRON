#!/bin/bash
# ==============================================================================
# check_burn_submissions.sh - Check burn claim submission status from genesis
# ==============================================================================

set -e

# SSH config
SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

CLI="~/BATHRON-Core/src/bathron-cli -testnet"

echo "=========================================="
echo "Burn Claim Submission Analysis"
echo "=========================================="
echo ""

# 1. Check bootstrap log for burn submissions
echo "=== Genesis Bootstrap Log (Burn Section) ==="
$SSH ubuntu@$SEED_IP "grep -E 'Genesis Burn Claims|Submitting burn|submitburnclaim|BURN|FAILED|skip|Done:|ERROR' /tmp/genesis_bootstrap.log 2>/dev/null | head -100" || echo "Log not found or no matches"
echo ""

# 2. Get burn claim DB stats
echo "=== Burn Claim DB Stats ==="
BURN_STATS=$($SSH ubuntu@$SEED_IP "$CLI getbtcburnstats 2>/dev/null" || echo "{}")
echo "$BURN_STATS" | jq . 2>/dev/null || echo "$BURN_STATS"
echo ""

# 3. Get burn scan status
echo "=== Burn Scan Status ==="
SCAN_STATUS=$($SSH ubuntu@$SEED_IP "$CLI getburnscanstatus 2>/dev/null" || echo "{}")
echo "$SCAN_STATUS" | jq . 2>/dev/null || echo "$SCAN_STATUS"
echo ""

# 4. Count submitted vs expected
GENESIS_BURNS="$HOME/BATHRON/contrib/testnet/genesis_burns.json"
if [ -f "$GENESIS_BURNS" ]; then
    EXPECTED_COUNT=$(jq '.burns | length' "$GENESIS_BURNS")
    CLAIMED_COUNT=$(echo "$BURN_STATS" | jq -r '.total_claimed // 0' 2>/dev/null)
    
    echo "=== Summary ==="
    echo "Expected burns (genesis_burns.json): $EXPECTED_COUNT"
    echo "Claimed burns (burnclaimdb): $CLAIMED_COUNT"
    
    if [ "$CLAIMED_COUNT" -lt "$EXPECTED_COUNT" ]; then
        MISSING=$((EXPECTED_COUNT - CLAIMED_COUNT))
        echo "MISSING: $MISSING burns not submitted!"
    elif [ "$CLAIMED_COUNT" -eq "$EXPECTED_COUNT" ]; then
        echo "OK: All burns submitted"
    else
        echo "WARNING: More claims than expected ($CLAIMED_COUNT > $EXPECTED_COUNT)"
    fi
    echo ""
fi

# 5. Check specific high-value burns mentioned
echo "=== Checking Specific Burns ==="
echo "Burn at height 290561 (edec642c...):"
$SSH ubuntu@$SEED_IP "$CLI checkburnclaim edec642c5a7e76133c882fe0c89d3c042a7caf149d21fe5f33d5411f3dd57b52 2>/dev/null" | jq . 2>/dev/null || echo "Not found or error"
echo ""

echo "Burn at height 290668 (0673350f...):"
$SSH ubuntu@$SEED_IP "$CLI checkburnclaim 0673350ffc686c21635cec1475b595e4ac1f477fa8317c2ff1d38003246bfa51 2>/dev/null" | jq . 2>/dev/null || echo "Not found or error"
echo ""

# 6. Check if any burns failed
echo "=== Failed Submissions (from log) ==="
$SSH ubuntu@$SEED_IP "grep -i 'failed\|error\|reject' /tmp/genesis_bootstrap.log 2>/dev/null | grep -i burn | head -20" || echo "No failures found in log"
echo ""

echo "=========================================="
echo "Analysis complete"
echo "=========================================="
