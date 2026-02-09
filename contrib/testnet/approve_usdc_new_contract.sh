#!/bin/bash
# Approve USDC for new HTLC3S contract

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"

NEW_ADDRESS="0x2493EaaaBa6B129962c8967AaEE6bF11D0277756"
USDC_ADDRESS="0x036CbD53842c5426634e7929541eC2318f3dCF7e"

echo "=== Approving USDC for new HTLC3S contract ==="

ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && python3 << PYEOF
import json
from web3 import Web3

RPC_URL = 'https://sepolia.base.org'
CHAIN_ID = 84532

w3 = Web3(Web3.HTTPProvider(RPC_URL))
print(f'Connected: {w3.is_connected()}')

# Load Bob's key
with open('/home/ubuntu/.BathronKey/evm.json') as f:
    keys = json.load(f)

pk = keys.get('private_key') or keys.get('bob_private_key')
account = w3.eth.account.from_key(pk)
print(f'Bob: {account.address}')

# Check current allowance
usdc_abi = [
    {'name': 'approve', 'type': 'function',
     'inputs': [{'name': 'spender', 'type': 'address'}, {'name': 'amount', 'type': 'uint256'}],
     'outputs': [{'name': '', 'type': 'bool'}]},
    {'name': 'allowance', 'type': 'function', 'stateMutability': 'view',
     'inputs': [{'name': 'owner', 'type': 'address'}, {'name': 'spender', 'type': 'address'}],
     'outputs': [{'name': '', 'type': 'uint256'}]},
]

usdc = w3.eth.contract(address=Web3.to_checksum_address('$USDC_ADDRESS'), abi=usdc_abi)

allowance = usdc.functions.allowance(account.address, '$NEW_ADDRESS').call()
print(f'Current allowance: {allowance} ({allowance/1e6} USDC)')

if allowance < 2**128:
    print('Approving max USDC...')
    nonce = w3.eth.get_transaction_count(account.address, 'pending')
    gas_price = int(w3.eth.gas_price * 1.2)

    tx = usdc.functions.approve(
        Web3.to_checksum_address('$NEW_ADDRESS'),
        2**256 - 1
    ).build_transaction({
        'from': account.address,
        'nonce': nonce,
        'gas': 100000,
        'gasPrice': gas_price,
        'chainId': CHAIN_ID
    })

    signed = w3.eth.account.sign_transaction(tx, pk)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f'TX: {tx_hash.hex()}')

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    print(f'Status: {receipt.status} ({\"SUCCESS\" if receipt.status == 1 else \"FAILED\"})')

    # Verify
    new_allowance = usdc.functions.allowance(account.address, '$NEW_ADDRESS').call()
    print(f'New allowance: {new_allowance}')
else:
    print('Already approved!')
PYEOF
"
