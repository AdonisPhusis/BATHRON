#!/bin/bash
# Test HTLC creation directly via script on VPS

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP3_IP="51.75.31.44"

# Create test script on remote VPS
ssh $SSH_OPTS ubuntu@$OP3_IP 'cat > /tmp/test_htlc.sh << "REMOTE_SCRIPT"
#!/bin/bash

CLI=/home/ubuntu/bathron-cli

echo "=== HTLC TEST ON OP3 ==="

# Generate secret
echo "1. Generating secret..."
GEN_RESULT=$($CLI -testnet htlc_generate)
echo "$GEN_RESULT"

SECRET=$(echo "$GEN_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get(\"secret\",\"\"))")
HASHLOCK=$(echo "$GEN_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get(\"hashlock\",\"\"))")

echo "Secret: $SECRET"
echo "Hashlock: $HASHLOCK"

# Get receipt
echo ""
echo "2. Getting M1 receipt..."
WALLET=$($CLI -testnet getwalletstate true)
RECEIPT=$(echo "$WALLET" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get(\"m1\", {}).get(\"receipts\", []):
    if r.get(\"amount\", 0) >= 50000 and r.get(\"unlockable\", False):
        print(r.get(\"outpoint\", \"\"))
        break
")
echo "Receipt: $RECEIPT"

# Claim address (hardcoded LP address for test)
LP_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

# Create HTLC - try with explicit integer
echo ""
echo "3. Creating HTLC..."
echo "Command: $CLI -testnet htlc_create_m1 \"$RECEIPT\" \"$HASHLOCK\" \"$LP_ADDR\" 30"

# Method 1: Direct command line
echo "Method 1 (direct):"
$CLI -testnet htlc_create_m1 "$RECEIPT" "$HASHLOCK" "$LP_ADDR" 30

# Method 2: Without 4th param (use default)
echo ""
echo "Method 2 (default expiry):"
$CLI -testnet htlc_create_m1 "$RECEIPT" "$HASHLOCK" "$LP_ADDR"

REMOTE_SCRIPT
chmod +x /tmp/test_htlc.sh
/tmp/test_htlc.sh
'
