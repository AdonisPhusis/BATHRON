#!/bin/bash
# Check deployment transaction

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"

TX_HASH="aea3ccce32af2a5563a13408611f36c0e082d1bcd812dce0b2d878510727dbe9"

ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && python3 << PYEOF
from web3 import Web3

w3 = Web3(Web3.HTTPProvider('https://sepolia.base.org'))
receipt = w3.eth.get_transaction_receipt('0x$TX_HASH')

print(f'Status: {receipt.status} ({\"SUCCESS\" if receipt.status == 1 else \"FAILED\"})')
print(f'Gas used: {receipt.gasUsed}')
print(f'Gas limit: {w3.eth.get_transaction(\"0x$TX_HASH\").gas}')
print(f'Contract address: {receipt.contractAddress}')
print(f'Block: {receipt.blockNumber}')
PYEOF
"
