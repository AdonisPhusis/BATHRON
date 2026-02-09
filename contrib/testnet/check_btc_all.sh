#!/bin/bash
# Check BTC balances on both nodes with correct CLI

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Correct CLI paths
BTC_CLI_OP1="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet"
BTC_CLI_OP3="/home/ubuntu/bitcoin/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet"

echo "=== BTC SIGNET BALANCES ==="
echo ""

echo "OP1 (LP - alice):"
echo "  Blocks: $(ssh $SSH_OPTS ubuntu@57.131.33.152 "$BTC_CLI_OP1 getblockcount" 2>&1)"
echo "  Balance: $(ssh $SSH_OPTS ubuntu@57.131.33.152 "$BTC_CLI_OP1 getbalance" 2>&1) BTC"
ssh $SSH_OPTS ubuntu@57.131.33.152 "$BTC_CLI_OP1 listunspent 1 9999999 '[]' true" 2>&1 | python3 -c "
import json, sys
try:
    utxos = json.load(sys.stdin)
    total = sum(u['amount'] for u in utxos)
    print(f'  UTXOs: {len(utxos)}, Total: {total:.8f} BTC ({int(total*1e8)} sats)')
except Exception as e:
    print(f'  Error: {e}')
"

echo ""
echo "OP3 (User - charlie):"
echo "  Blocks: $(ssh $SSH_OPTS ubuntu@51.75.31.44 "$BTC_CLI_OP3 getblockcount" 2>&1)"
echo "  Balance: $(ssh $SSH_OPTS ubuntu@51.75.31.44 "$BTC_CLI_OP3 getbalance" 2>&1) BTC"
ssh $SSH_OPTS ubuntu@51.75.31.44 "$BTC_CLI_OP3 listunspent 1 9999999 '[]' true" 2>&1 | python3 -c "
import json, sys
try:
    utxos = json.load(sys.stdin)
    total = sum(u['amount'] for u in utxos)
    print(f'  UTXOs: {len(utxos)}, Total: {total:.8f} BTC ({int(total*1e8)} sats)')
except Exception as e:
    print(f'  Error: {e}')
"
