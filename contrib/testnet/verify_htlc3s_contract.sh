#!/bin/bash
# Verify HTLC3S contract deployment

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"
OP1_IP="57.131.33.152"

echo "=== Verifying HTLC3S Contract ==="

# Check if config exists on OP1
echo "Checking HTLC3S config on OP1..."
ssh $SSH_OPTS "ubuntu@$OP1_IP" "cat ~/.BathronKey/htlc3s.json 2>/dev/null || echo 'No config file found'"

echo ""
echo "=== Testing HTLC3S Contract Functions ==="

# Read hashlocks from local state
STATE_DIR="/tmp/flowswap_e2e_state"
H_USER=$(cat "$STATE_DIR/H_user" 2>/dev/null)
H_LP1=$(cat "$STATE_DIR/H_lp1" 2>/dev/null)
H_LP2=$(cat "$STATE_DIR/H_lp2" 2>/dev/null)

ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && H_USER='$H_USER' H_LP1='$H_LP1' H_LP2='$H_LP2' python3 << 'PYEOF'
import json
import os
import time
from web3 import Web3

RPC_URL = 'https://sepolia.base.org'
USDC_ADDRESS = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
HTLC3S_ADDRESS = '0x667E9bDC368F0aC2abff69F5963714e3656d2d9D'

w3 = Web3(Web3.HTTPProvider(RPC_URL))
print(f'Connected: {w3.is_connected()}')
print(f'Block: {w3.eth.block_number}')
print()

# Get HTLC3S bytecode
code = w3.eth.get_code(HTLC3S_ADDRESS)
print(f'HTLC3S bytecode size: {len(code)} bytes')
print(f'First 50 bytes: {code[:50].hex()}')
print()

# Check if the contract has the create function
# We'll try calling a view function to verify the contract
htlc_abi = [
    {'name': 'htlcs', 'type': 'function', 'stateMutability': 'view',
     'inputs': [{'name': '', 'type': 'bytes32'}],
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

# Query a random htlcId to see if the mapping exists
print('Testing htlcs() mapping...')
try:
    result = htlc.functions.htlcs(bytes(32)).call()
    print(f'htlcs(0x0...) returned: {result[0]}')  # Should be 0x0 address
    print('Contract mapping accessible!')
except Exception as e:
    print(f'Error: {e}')

print()

# Now let's try the actual create with raw transaction encoding
print('=== Testing create() with raw encoding ===')

# Load Bob's key
with open('/home/ubuntu/.BathronKey/evm.json') as f:
    key_data = json.load(f)

pk = key_data.get('private_key') or key_data.get('bob_private_key')
account = w3.eth.account.from_key(pk)
bob_addr = account.address
print(f'Bob: {bob_addr}')

H_user = os.environ.get('H_USER', '')
H_lp1 = os.environ.get('H_LP1', '')
H_lp2 = os.environ.get('H_LP2', '')

recipient = '0x9f11B03618DeE8f12E7F90e753093B613CeD51D2'
amount = 5_000_000
timelock = int(time.time()) + 3600

# Check USDC balance at HTLC contract
usdc_abi = [
    {'name': 'balanceOf', 'type': 'function', 'stateMutability': 'view',
     'inputs': [{'name': 'account', 'type': 'address'}],
     'outputs': [{'name': '', 'type': 'uint256'}]},
]
usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_ADDRESS), abi=usdc_abi)
htlc_balance = usdc.functions.balanceOf(HTLC3S_ADDRESS).call()
print(f'HTLC3S USDC balance before: {htlc_balance} ({htlc_balance/1e6} USDC)')

# Manually encode the create function call
from eth_abi import encode

def to_bytes32(hex_str):
    if hex_str.startswith('0x'):
        hex_str = hex_str[2:]
    return bytes.fromhex(hex_str)

# Function selector for create(address,address,uint256,bytes32,bytes32,bytes32,uint256)
# keccak256('create(address,address,uint256,bytes32,bytes32,bytes32,uint256)')[:4]
selector = w3.keccak(text='create(address,address,uint256,bytes32,bytes32,bytes32,uint256)')[:4]
print(f'Function selector: 0x{selector.hex()}')

# Encode parameters
params = encode(
    ['address', 'address', 'uint256', 'bytes32', 'bytes32', 'bytes32', 'uint256'],
    [
        Web3.to_checksum_address(recipient),
        Web3.to_checksum_address(USDC_ADDRESS),
        amount,
        to_bytes32(H_user),
        to_bytes32(H_lp1),
        to_bytes32(H_lp2),
        timelock
    ]
)

calldata = selector + params
print(f'Calldata length: {len(calldata)} bytes')
print(f'Calldata: 0x{calldata[:100].hex()}...')

# Try eth_call first
print()
print('Testing eth_call...')
try:
    result = w3.eth.call({
        'from': bob_addr,
        'to': HTLC3S_ADDRESS,
        'data': '0x' + calldata.hex()
    })
    print(f'eth_call succeeded: 0x{result.hex()}')
except Exception as e:
    print(f'eth_call failed: {e}')

    # Try to get more debug info
    if hasattr(e, 'args') and len(e.args) > 1:
        error_data = e.args[1] if len(e.args) > 1 else ''
        if error_data and error_data != '0x':
            # Try to decode revert reason
            if error_data.startswith('0x08c379a0'):
                # Standard revert with string
                reason_hex = error_data[138:]  # Skip selector and offset
                reason_len = int(reason_hex[:64], 16)
                reason = bytes.fromhex(reason_hex[64:64+reason_len*2]).decode('utf-8', errors='ignore')
                print(f'Revert reason: {reason}')
PYEOF
"
