#!/bin/bash
# Decode the HTLC creation transaction to see the recipient

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # Alice (LP)
M1_CLI="\$HOME/bathron-cli -testnet"

HTLC_TXID="31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063"

echo "=== DECODING HTLC CREATION TRANSACTION ==="
echo ""
echo "TXID: $HTLC_TXID"
echo ""

echo "Getting raw transaction..."
ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getrawtransaction '$HTLC_TXID' 1" 2>&1 | python3 -c "
import json, sys
try:
    tx = json.load(sys.stdin)
    print('Transaction Type:', tx.get('type', 'unknown'))
    print('Version:', tx.get('version', '?'))
    print('')
    
    # Look for extraPayload (HTLC data)
    if 'extraPayload' in tx:
        print('Extra Payload (raw):', tx['extraPayload'][:100], '...')
    
    # Look for vout with scriptPubKey containing HTLC
    print('')
    print('Outputs:')
    for i, vout in enumerate(tx.get('vout', [])):
        print(f'  Output {i}:')
        print(f'    Value: {vout.get(\"value\", 0)}')
        spk = vout.get('scriptPubKey', {})
        print(f'    Type: {spk.get(\"type\", \"unknown\")}')
        if 'addresses' in spk:
            print(f'    Addresses: {spk[\"addresses\"]}')
        print('')
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
"
