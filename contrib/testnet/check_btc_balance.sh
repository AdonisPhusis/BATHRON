#!/bin/bash
# Check BTC balances on OP1 and OP3

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

BTC_CLI_OP1="/home/ubuntu/bitcoin/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet"
BTC_CLI_OP3="/home/ubuntu/bitcoin/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet"

echo "=== BTC SIGNET BALANCES ==="
echo ""

echo "OP1 (LP - alice):"
echo "  Blockchain info:"
ssh $SSH_OPTS ubuntu@57.131.33.152 "$BTC_CLI_OP1 getblockchaininfo 2>&1" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(f\"    Chain: {d.get('chain', 'unknown')}\")
    print(f\"    Blocks: {d.get('blocks', 0)}\")
    print(f\"    Headers: {d.get('headers', 0)}\")
except Exception as e:
    print(f'    Error: {e}')
"

echo "  Wallet balance:"
ssh $SSH_OPTS ubuntu@57.131.33.152 "$BTC_CLI_OP1 getbalance 2>&1 || echo 'N/A'"

echo "  Wallet addresses:"
ssh $SSH_OPTS ubuntu@57.131.33.152 "$BTC_CLI_OP1 getaddressesbylabel '' 2>&1" | head -5

echo ""
echo "OP3 (User - charlie):"
echo "  Blockchain info:"
ssh $SSH_OPTS ubuntu@51.75.31.44 "$BTC_CLI_OP3 getblockchaininfo 2>&1" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(f\"    Chain: {d.get('chain', 'unknown')}\")
    print(f\"    Blocks: {d.get('blocks', 0)}\")
    print(f\"    Headers: {d.get('headers', 0)}\")
except Exception as e:
    print(f'    Error: {e}')
"

echo "  Wallet balance:"
ssh $SSH_OPTS ubuntu@51.75.31.44 "$BTC_CLI_OP3 getbalance 2>&1 || echo 'N/A'"

echo "  Wallet addresses:"
ssh $SSH_OPTS ubuntu@51.75.31.44 "$BTC_CLI_OP3 getaddressesbylabel '' 2>&1" | head -5

echo ""
echo "=== BTC FAUCETS ==="
echo "Get testnet BTC: https://signetfaucet.com or https://alt.signetfaucet.com"
