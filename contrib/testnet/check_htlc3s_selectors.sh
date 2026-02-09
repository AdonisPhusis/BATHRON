#!/bin/bash
# Check HTLC3S contract function selectors

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"

echo "=== Checking HTLC3S Contract Selectors ==="

ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && python3 << 'PYEOF'
from web3 import Web3

RPC_URL = 'https://sepolia.base.org'
HTLC3S_ADDRESS = '0x667E9bDC368F0aC2abff69F5963714e3656d2d9D'

w3 = Web3(Web3.HTTPProvider(RPC_URL))

# Get bytecode
code = w3.eth.get_code(HTLC3S_ADDRESS)
print(f'Contract bytecode size: {len(code)} bytes')
print()

# Calculate expected selectors
functions = [
    'create(address,address,uint256,bytes32,bytes32,bytes32,uint256)',
    'claim(bytes32,bytes32,bytes32,bytes32)',
    'refund(bytes32)',
    'htlcs(bytes32)',
    'getHTLC(bytes32)',
]

print('Expected function selectors:')
for fn in functions:
    selector = w3.keccak(text=fn)[:4].hex()
    print(f'  {fn[:50]:50} -> 0x{selector}')

print()
print('Searching for selectors in bytecode...')
bytecode_hex = code.hex()
for fn in functions:
    selector = w3.keccak(text=fn)[:4].hex()
    if selector in bytecode_hex:
        print(f'  ✓ 0x{selector} FOUND in bytecode')
    else:
        print(f'  ✗ 0x{selector} NOT found in bytecode')

# Try calling with different ABIs
print()
print('=== Testing getHTLC() ===')

htlc_abi = [
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

htlc = w3.eth.contract(address=HTLC3S_ADDRESS, abi=htlc_abi)

try:
    result = htlc.functions.getHTLC(bytes(32)).call()
    print(f'getHTLC(0x0...) = {result}')
except Exception as e:
    print(f'getHTLC failed: {e}')

# Try raw call to getHTLC
print()
print('=== Raw call to getHTLC ===')
selector = w3.keccak(text='getHTLC(bytes32)')[:4]
calldata = selector + bytes(32)  # bytes32(0)

try:
    result = w3.eth.call({
        'to': HTLC3S_ADDRESS,
        'data': '0x' + calldata.hex()
    })
    print(f'Raw call succeeded: 0x{result.hex()[:100]}...')
except Exception as e:
    print(f'Raw call failed: {e}')

# Check if maybe the contract is a proxy
print()
print('=== Checking proxy patterns ===')

# Check storage slots
impl_slot = bytes.fromhex('360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc')
admin_slot = bytes.fromhex('b53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103')

impl = w3.eth.get_storage_at(HTLC3S_ADDRESS, impl_slot)
admin = w3.eth.get_storage_at(HTLC3S_ADDRESS, admin_slot)

print(f'Implementation slot: 0x{impl.hex()}')
print(f'Admin slot: 0x{admin.hex()}')

# Check if first storage slot has data (could indicate initialized state)
slot0 = w3.eth.get_storage_at(HTLC3S_ADDRESS, 0)
print(f'Storage slot 0: 0x{slot0.hex()}')
PYEOF
"
