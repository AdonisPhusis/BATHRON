#!/bin/bash
# Check new HTLC3S contract

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"

NEW_ADDRESS="0x2493EaaaBa6B129962c8967AaEE6bF11D0277756"

ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && python3 << PYEOF
from web3 import Web3

RPC_URL = 'https://sepolia.base.org'

w3 = Web3(Web3.HTTPProvider(RPC_URL))
print(f'Connected: {w3.is_connected()}')

# Get bytecode
code = w3.eth.get_code('$NEW_ADDRESS')
bytecode = code.hex()

print(f'Bytecode size: {len(code)} bytes')

# Calculate expected selectors
functions = [
    'create(address,address,uint256,bytes32,bytes32,bytes32,uint256)',
    'claim(bytes32,bytes32,bytes32,bytes32)',
    'refund(bytes32)',
    'htlcs(bytes32)',
    'getHTLC(bytes32)',
]

print()
print('Expected function selectors:')
for fn in functions:
    selector = w3.keccak(text=fn)[:4].hex()
    found = selector in bytecode
    status = '✓' if found else '✗'
    print(f'  {status} 0x{selector} - {fn[:50]}')

print()
print('Searching for PUSH4 patterns...')

selectors_found = set()
i = 0
while i < len(bytecode) - 8:
    if bytecode[i:i+2] == '63':
        selector = bytecode[i+2:i+10]
        selectors_found.add(selector)
        i += 10
    else:
        i += 2

print(f'Found {len(selectors_found)} potential selectors:')
for sel in sorted(selectors_found):
    print(f'  0x{sel}')

# Try calling create with test parameters
print()
print('Testing create function call...')

import time

htlc_abi = [
    {'name': 'create', 'type': 'function',
     'inputs': [
         {'name': 'recipient', 'type': 'address'},
         {'name': 'token', 'type': 'address'},
         {'name': 'amount', 'type': 'uint256'},
         {'name': 'H_user', 'type': 'bytes32'},
         {'name': 'H_lp1', 'type': 'bytes32'},
         {'name': 'H_lp2', 'type': 'bytes32'},
         {'name': 'timelock', 'type': 'uint256'}
     ],
     'outputs': [{'name': 'htlcId', 'type': 'bytes32'}]},
    {'name': 'getHTLC', 'type': 'function', 'stateMutability': 'view',
     'inputs': [{'name': 'htlcId', 'type': 'bytes32'}],
     'outputs': [
         {'name': 'sender', 'type': 'address'},
         {'name': 'recipient', 'type': 'address'},
         {'name': 'token', 'type': 'address'},
         {'name': 'amount', 'type': 'uint256'},
         {'name': 'H_user', 'type': 'bytes32'},
         {'name': 'H_lp1', 'type': 'bytes32'},
         {'name': 'H_lp2', 'type': 'bytes32'},
         {'name': 'timelock', 'type': 'uint256'},
         {'name': 'claimed', 'type': 'bool'},
         {'name': 'refunded', 'type': 'bool'}
     ]}
]

htlc = w3.eth.contract(address='$NEW_ADDRESS', abi=htlc_abi)

# Test getHTLC first (view function)
print('Testing getHTLC(0x0...)...')
try:
    result = htlc.functions.getHTLC(bytes(32)).call()
    print(f'  SUCCESS: {result[0]}')
except Exception as e:
    print(f'  FAILED: {e}')
PYEOF
"
