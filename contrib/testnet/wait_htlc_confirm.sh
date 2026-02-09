#!/bin/bash
# Wait for HTLC confirmation and then claim

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # LP
OP3_IP="51.75.31.44"     # User

M1_CLI_OP1="/home/ubuntu/bathron-cli -testnet"
M1_CLI_OP3="/home/ubuntu/bathron-cli -testnet"

HTLC_OUTPOINT="33c1f8cf27a38c85dab6e1462fb1a12f17509fc3dbb76f671514d7e88309d753:0"
HTLC_TXID="33c1f8cf27a38c85dab6e1462fb1a12f17509fc3dbb76f671514d7e88309d753"
SECRET="1158b4b41ace764f1974ffd253fd6705d1d3439bfcbe24329598cb82519586be"

echo "=== WAITING FOR HTLC CONFIRMATION ==="
echo ""

# Get current block count
echo "Current block counts:"
OP1_BLOCK=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI_OP1 getblockcount" 2>&1)
OP3_BLOCK=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI_OP3 getblockcount" 2>&1)
echo "  OP1: $OP1_BLOCK"
echo "  OP3: $OP3_BLOCK"
echo ""

# Wait for TX confirmation
echo "Waiting for HTLC TX to confirm..."
for i in {1..30}; do
    CONFS=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI_OP3 gettransaction '$HTLC_TXID'" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('confirmations', 0))" 2>/dev/null || echo "0")

    if [ "$CONFS" -ge 1 ]; then
        echo "  TX confirmed! ($CONFS confirmations)"
        break
    fi

    echo "  Waiting... ($i/30) - $CONFS confirmations"
    sleep 10
done

# Now check HTLC
echo ""
echo "Checking HTLC after confirmation..."

# Check on OP1 (where LP will claim)
echo "1. HTLC status on OP1:"
HTLC_STATUS=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI_OP1 htlc_get '$HTLC_OUTPOINT'" 2>&1)
echo "   $HTLC_STATUS"

# Check HTLC list on OP1
echo ""
echo "2. Active HTLCs on OP1:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI_OP1 htlc_list active" 2>&1 | python3 -c "
import json, sys
try:
    htlcs = json.load(sys.stdin)
    for h in htlcs:
        if '$HTLC_TXID' in h.get('outpoint', ''):
            print(f'   FOUND: {h}')
            break
    else:
        print(f'   HTLC not in list (total: {len(htlcs)} active HTLCs)')
except Exception as e:
    print(f'   Error: {e}')
"

# Try to claim
echo ""
echo "3. Attempting LP claim..."
CLAIM_RESULT=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI_OP1 htlc_claim '$HTLC_OUTPOINT' '$SECRET'" 2>&1)
echo "   Result: $CLAIM_RESULT"

if echo "$CLAIM_RESULT" | grep -q "txid"; then
    echo ""
    echo "4. SUCCESS! HTLC Claimed!"
    CLAIM_TXID=$(echo "$CLAIM_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('txid',''))")
    echo "   Claim TX: $CLAIM_TXID"
fi

echo ""
echo "=== DONE ==="
