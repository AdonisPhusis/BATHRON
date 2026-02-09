#!/bin/bash
# fix_lp_address.sh - Sync LP server with alice's actual wallet address

set -e

KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"

# Alice's canonical address (from CLAUDE.md)
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"

echo "=== Fixing LP Address Mismatch ==="
echo

echo "Step 1: Alice's canonical M1 address: $ALICE_ADDR"
echo

echo "Step 2: Check current .lp_addresses.json..."
ssh $SSH_OPTS ubuntu@$OP1_IP 'cat ~/pna-sdk/.lp_addresses.json 2>/dev/null || echo "File not found"'
echo

echo "Step 3: Update M1 address in .lp_addresses.json..."
ssh $SSH_OPTS ubuntu@$OP1_IP "cat > ~/pna-sdk/.lp_addresses.json << EOF
{
  \"btc\": \"tb1qxuljrzqckwyzzmh5l7kq4zslcr6zvahzqfahre\",
  \"m1\": \"$ALICE_ADDR\",
  \"usdc\": \"0xB6bc96842f6085a949b8433dc6316844c32Cba63\"
}
EOF"
echo "Updated!"
echo

echo "Step 4: Verify update..."
ssh $SSH_OPTS ubuntu@$OP1_IP 'cat ~/pna-sdk/.lp_addresses.json'
echo

echo "Step 5: Verify alice owns this address in bathrond..."
ssh $SSH_OPTS ubuntu@$OP1_IP "/home/ubuntu/bathron-cli -testnet getaddressinfo '$ALICE_ADDR'" | grep -E '(address|ismine)'
echo

echo "Step 6: Restart pna-lp server..."
ssh $SSH_OPTS ubuntu@$OP1_IP 'pkill -f "uvicorn.*server:app" 2>/dev/null || true'
sleep 2
ssh $SSH_OPTS ubuntu@$OP1_IP 'cd ~/pna-sdk && nohup ./venv/bin/python -m uvicorn server:app --host 0.0.0.0 --port 8080 >> /tmp/pna-sdk.log 2>&1 &'
sleep 3
echo "Server restarted"
echo

echo "Step 7: Check server logs..."
ssh $SSH_OPTS ubuntu@$OP1_IP 'tail -20 /tmp/pna-sdk.log | grep -E "(Loaded LP addresses|M1=)"'
echo

echo "Step 8: Verify server wallet API..."
curl -s http://57.131.33.152:8080/api/wallet 2>/dev/null | python3 -m json.tool | grep -A 5 '"m1"' || echo "API not ready yet"
echo

echo "=== LP Address Fix Complete ==="
echo "Server should now use alice's address: $ALICE_ADDR"
