#!/bin/bash
# Check if USDC is a proxy and test direct transferFrom

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"

echo "=== Checking USDC Proxy Status ==="

ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && python3 << 'PYEOF'
import json
from web3 import Web3

RPC_URL = 'https://sepolia.base.org'
USDC_ADDRESS = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
HTLC3S_ADDRESS = '0x667E9bDC368F0aC2abff69F5963714e3656d2d9D'

w3 = Web3(Web3.HTTPProvider(RPC_URL))
print(f'Connected: {w3.is_connected()}')
print()

# Check storage slot for proxy implementation (EIP-1967)
# Implementation slot: 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
impl_slot = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
impl_value = w3.eth.get_storage_at(USDC_ADDRESS, impl_slot)
print(f'EIP-1967 implementation slot: 0x{impl_value.hex()}')

# Check admin slot
admin_slot = '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103'
admin_value = w3.eth.get_storage_at(USDC_ADDRESS, admin_slot)
print(f'EIP-1967 admin slot: 0x{admin_value.hex()}')
print()

# Load Bob's key
with open('/home/ubuntu/.BathronKey/evm.json') as f:
    key_data = json.load(f)

pk = key_data.get('private_key') or key_data.get('bob_private_key')
account = w3.eth.account.from_key(pk)
bob_addr = account.address

# Test a simple transfer (not to contract)
print('Testing direct USDC transfer (Bob to Charlie)...')
charlie = '0x9f11B03618DeE8f12E7F90e753093B613CeD51D2'

usdc_abi = [
    {'name': 'transfer', 'type': 'function',
     'inputs': [{'name': 'to', 'type': 'address'}, {'name': 'amount', 'type': 'uint256'}],
     'outputs': [{'name': '', 'type': 'bool'}]},
    {'name': 'transferFrom', 'type': 'function',
     'inputs': [
         {'name': 'from', 'type': 'address'},
         {'name': 'to', 'type': 'address'},
         {'name': 'amount', 'type': 'uint256'}
     ],
     'outputs': [{'name': '', 'type': 'bool'}]},
]

usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_ADDRESS), abi=usdc_abi)

# Test 1: Can we estimate gas for a simple transfer?
print('1. Testing transfer() estimate_gas...')
try:
    gas = usdc.functions.transfer(charlie, 1000000).estimate_gas({'from': bob_addr})
    print(f'   SUCCESS: Gas estimate = {gas}')
except Exception as e:
    print(f'   FAILED: {e}')

# Test 2: Can we estimate gas for transferFrom (Bob approving himself)?
print('2. Testing transferFrom() estimate_gas (self-transfer)...')
try:
    gas = usdc.functions.transferFrom(bob_addr, charlie, 1000000).estimate_gas({'from': bob_addr})
    print(f'   SUCCESS: Gas estimate = {gas}')
except Exception as e:
    print(f'   FAILED: {e}')

# Test 3: Can HTLC3S contract call transferFrom?
print('3. Testing transferFrom() with HTLC3S as destination...')
try:
    gas = usdc.functions.transferFrom(bob_addr, HTLC3S_ADDRESS, 1000000).estimate_gas({'from': bob_addr})
    print(f'   SUCCESS: Gas estimate = {gas}')
except Exception as e:
    print(f'   FAILED: {e}')

# Test 4: Actually execute a small transfer to HTLC contract
print()
print('4. Executing actual 1 USDC transfer to HTLC contract...')
try:
    nonce = w3.eth.get_transaction_count(bob_addr, 'pending')
    gas_price = int(w3.eth.gas_price * 1.2)

    tx = usdc.functions.transfer(
        HTLC3S_ADDRESS,
        1_000_000  # 1 USDC
    ).build_transaction({
        'from': bob_addr,
        'nonce': nonce,
        'gas': 100000,
        'gasPrice': gas_price,
        'chainId': 84532
    })

    signed = w3.eth.account.sign_transaction(tx, pk)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f'   TX sent: {tx_hash.hex()}')

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
    print(f'   Status: {receipt.status} ({\"SUCCESS\" if receipt.status == 1 else \"FAILED\"})')
    print(f'   Gas used: {receipt.gasUsed}')
except Exception as e:
    print(f'   FAILED: {e}')
PYEOF
"
