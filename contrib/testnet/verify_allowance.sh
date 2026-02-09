#!/bin/bash
# Verify USDC allowance

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"

ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && python3 << PYEOF
import json
from web3 import Web3

w3 = Web3(Web3.HTTPProvider('https://sepolia.base.org'))

with open('/home/ubuntu/.BathronKey/evm.json') as f:
    keys = json.load(f)
pk = keys.get('private_key') or keys.get('bob_private_key')
account = w3.eth.account.from_key(pk)

NEW_CONTRACT = '0x2493EaaaBa6B129962c8967AaEE6bF11D0277756'
USDC = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'

usdc_abi = [
    {'name': 'allowance', 'type': 'function', 'stateMutability': 'view',
     'inputs': [{'name': 'owner', 'type': 'address'}, {'name': 'spender', 'type': 'address'}],
     'outputs': [{'name': '', 'type': 'uint256'}]},
    {'name': 'balanceOf', 'type': 'function', 'stateMutability': 'view',
     'inputs': [{'name': 'account', 'type': 'address'}],
     'outputs': [{'name': '', 'type': 'uint256'}]},
]

usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC), abi=usdc_abi)

balance = usdc.functions.balanceOf(account.address).call()
allowance = usdc.functions.allowance(account.address, Web3.to_checksum_address(NEW_CONTRACT)).call()

print(f'Bob address: {account.address}')
print(f'USDC balance: {balance} ({balance/1e6} USDC)')
print(f'Allowance to {NEW_CONTRACT}: {allowance}')
print(f'Allowance sufficient (5 USDC): {allowance >= 5_000_000}')
PYEOF
"
