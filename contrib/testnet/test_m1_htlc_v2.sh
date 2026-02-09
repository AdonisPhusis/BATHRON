#!/bin/bash
#
# M1 HTLC test - fixed integer parameter
#

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # LP (alice)
OP3_IP="51.75.31.44"     # User (charlie)

M1_CLI="\$HOME/bathron-cli -testnet"

echo "=== M1 HTLC TEST (v2) ==="
echo ""

# Step 1: Generate secret
echo "1. Generating secret..."
SECRET=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_generate" 2>&1 | python3 -c "import json,sys; print(json.load(sys.stdin).get('secret',''))")
HASHLOCK=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_generate" 2>&1 | python3 -c "import json,sys; print(json.load(sys.stdin).get('hashlock',''))")

# Generate fresh secret locally to ensure consistency
SECRET=$(openssl rand -hex 32)
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | sha256sum | cut -d' ' -f1)

echo "   Secret: $SECRET"
echo "   Hashlock: $HASHLOCK"
echo ""

# Step 2: Get user's receipt
echo "2. Getting user's M1 receipt..."
USER_RECEIPT=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI getwalletstate true" 2>&1 | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('m1', {}).get('receipts', []):
    if r.get('amount', 0) >= 50000 and r.get('unlockable', False):
        print(r.get('outpoint', ''))
        break
")
echo "   Receipt: $USER_RECEIPT"
echo ""

# Step 3: Get LP address
echo "3. Getting LP claim address..."
LP_ADDR=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getnewaddress 'htlc_test'" 2>&1)
echo "   LP address: $LP_ADDR"
echo ""

# Step 4: Create HTLC (try different formats)
echo "4. Creating M1 HTLC..."

# Try with explicit RPC call format
echo "   Attempting with different parameter formats..."

# Format 1: All in one command line (no JSON-RPC named params)
HTLC_RESULT=$(ssh $SSH_OPTS ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet htlc_create_m1 '$USER_RECEIPT' '$HASHLOCK' '$LP_ADDR' 30" 2>&1)
echo "   Format 1 result: $HTLC_RESULT"

if echo "$HTLC_RESULT" | grep -q "txid"; then
    echo "   SUCCESS!"
    HTLC_TXID=$(echo "$HTLC_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('txid',''))")
    HTLC_OUTPOINT="${HTLC_TXID}:0"
    echo "   HTLC outpoint: $HTLC_OUTPOINT"

    # Wait for confirmation
    echo ""
    echo "5. Waiting for confirmation..."
    sleep 10

    # Check status
    echo "6. Checking HTLC status..."
    HTLC_STATUS=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_get '$HTLC_OUTPOINT'" 2>&1)
    echo "   Status: $HTLC_STATUS"

    # LP claims
    echo ""
    echo "7. LP claiming with secret..."
    CLAIM_RESULT=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_claim '$HTLC_OUTPOINT' '$SECRET'" 2>&1)
    echo "   Claim result: $CLAIM_RESULT"
else
    echo "   HTLC creation failed. Trying alternative..."

    # Try with explicit typing via Python
    HTLC_RESULT2=$(ssh $SSH_OPTS ubuntu@$OP3_IP "python3 << 'EOF'
import subprocess
import json

cmd = [
    '/home/ubuntu/bathron-cli',
    '-testnet',
    'htlc_create_m1',
    '$USER_RECEIPT',
    '$HASHLOCK',
    '$LP_ADDR',
    '30'
]

result = subprocess.run(cmd, capture_output=True, text=True)
print(result.stdout)
print(result.stderr)
EOF
" 2>&1)
    echo "   Python format result: $HTLC_RESULT2"
fi

echo ""
echo "=== TEST COMPLETE ==="
