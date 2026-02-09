#!/bin/bash
# Check BTC UTXO status on OP3 and OP1

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

FUNDING_TXID="d1c656881e844e6f9ef916ef426abdf451cdd6851cd17dff8d27497c15b44262"

echo "============================================================"
echo "CHECK BTC UTXO STATUS"
echo "============================================================"
echo ""
echo "TXID: $FUNDING_TXID"
echo ""

echo "=== OP3 (Fake User - should be synced) ==="
ssh $SSH_OPTS ubuntu@$OP3_IP "
    CLI='/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet'
    echo 'Block height:' \$(\$CLI getblockcount)
    echo ''
    echo 'UTXO check (gettxout):'
    \$CLI gettxout $FUNDING_TXID 0 2>/dev/null || echo 'UTXO not found or spent'
    echo ''
    echo 'TX lookup:'
    \$CLI getrawtransaction $FUNDING_TXID 1 2>/dev/null | python3 -c 'import sys,json; tx=json.load(sys.stdin); print(f\"Confirmations: {tx.get(\"confirmations\",0)}\"); print(f\"Value: {tx[\"vout\"][0][\"value\"]} BTC\")' 2>/dev/null || echo 'TX not found in local mempool/chain'
"

echo ""
echo "=== OP1 (LP - may not be synced) ==="
ssh $SSH_OPTS ubuntu@$OP1_IP "
    CLI='/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet'
    echo 'Block height:' \$(\$CLI getblockcount)
    echo ''
    echo 'UTXO check (gettxout):'
    \$CLI gettxout $FUNDING_TXID 0 2>/dev/null || echo 'UTXO not found or spent'
"

echo ""
echo "============================================================"
