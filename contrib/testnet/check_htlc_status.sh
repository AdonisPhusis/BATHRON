#!/bin/bash
# Check HTLC status on all nodes

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # LP
OP3_IP="51.75.31.44"     # User

M1_CLI="\$HOME/bathron-cli -testnet"

HTLC_OUTPOINT="33c1f8cf27a38c85dab6e1462fb1a12f17509fc3dbb76f671514d7e88309d753:0"
HTLC_TXID="33c1f8cf27a38c85dab6e1462fb1a12f17509fc3dbb76f671514d7e88309d753"

echo "=== HTLC STATUS CHECK ==="
echo ""

# Check TX on OP3 (creator)
echo "1. TX status on OP3 (creator):"
ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI gettransaction '$HTLC_TXID'" 2>&1 | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(f'   Confirmations: {d.get(\"confirmations\", 0)}')
    print(f'   Block: {d.get(\"blockhash\", \"mempool\")[:16] if d.get(\"blockhash\") else \"mempool\"}...')
except Exception as e:
    print(f'   Error: {e}')
"

# Check HTLC list on OP3
echo ""
echo "2. HTLC list on OP3:"
ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_list" 2>&1 | python3 -c "
import json, sys
try:
    htlcs = json.load(sys.stdin)
    print(f'   Total HTLCs: {len(htlcs)}')
    for h in htlcs[:5]:
        print(f'   - {h.get(\"outpoint\")}: {h.get(\"amount\")} sats, status={h.get(\"status\")}')
except Exception as e:
    print(f'   {sys.stdin.read()}')
"

# Check HTLC on OP3 directly
echo ""
echo "3. HTLC get on OP3:"
ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_get '$HTLC_OUTPOINT'" 2>&1

# Check block count on both nodes
echo ""
echo "4. Block counts:"
echo "   OP1: $(ssh $SSH_OPTS ubuntu@$OP1_IP '$M1_CLI getblockcount' 2>&1)"
echo "   OP3: $(ssh $SSH_OPTS ubuntu@$OP3_IP '$M1_CLI getblockcount' 2>&1)"

# Check TX in mempool or raw
echo ""
echo "5. Raw TX check on OP1:"
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getrawtransaction '$HTLC_TXID' true" 2>&1 | head -20

echo ""
echo "=== END CHECK ==="
