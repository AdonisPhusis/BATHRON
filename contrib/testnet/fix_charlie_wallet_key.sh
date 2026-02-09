#!/bin/bash
# Fix Charlie's wallet by importing the correct private key

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
OP3_IP="51.75.31.44"    # charlie

CHARLIE_ADDR="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"

echo "==== Fix Charlie's Wallet Key ===="
echo ""

echo "=== 1. Check ~/.BathronKey/wallet.json on OP3 ==="
WALLET_JSON=$(ssh -i $SSH_KEY ubuntu@$OP3_IP "cat ~/.BathronKey/wallet.json 2>/dev/null || echo '{}'")
echo "$WALLET_JSON"
echo ""

echo "=== 2. Extract WIF from wallet.json ==="
CHARLIE_WIF=$(echo "$WALLET_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
wif = data.get('wif', '')
addr = data.get('address', '')
print(f'Address from wallet.json: {addr}')
print(f'WIF from wallet.json: {wif}')
if wif:
    print('WIF_VALUE:', wif)
" | grep "^WIF_VALUE:" | cut -d: -f2 | tr -d ' ')

if [ -z "$CHARLIE_WIF" ]; then
    echo "ERROR: No WIF found in wallet.json"
    exit 1
fi

echo ""
echo "=== 3. Import WIF into Charlie's wallet ==="
echo "Importing WIF: $CHARLIE_WIF"
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet importprivkey \"$CHARLIE_WIF\" \"charlie\" false"
echo ""

echo "=== 4. Verify address is now in wallet with private key ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getaddressinfo \"$CHARLIE_ADDR\"" | python3 -c "
import sys, json
data = json.load(sys.stdin)
is_mine = data.get('ismine', False)
print(f\"Is mine: {is_mine}\")
if is_mine:
    print('✓ SUCCESS: Charlie now has the private key!')
else:
    print('✗ FAILED: Still no private key')
"
echo ""

echo "=== 5. Try to claim HTLC again ==="
HTLC_OUTPOINT="31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0"
PREIMAGE="8f894b5829fc8f4096a9f177260e7cb46c175f2961ade379b58cdcdd338c36ef"

echo "Attempting claim..."
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet htlc_claim \"$HTLC_OUTPOINT\" \"$PREIMAGE\"" 2>&1 || echo "Claim failed"
echo ""

echo "=== Fix Complete ==="
