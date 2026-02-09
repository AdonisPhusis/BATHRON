#!/bin/bash
# Verify USDC contract and test transferFrom on CoreSDK

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"

# Read hashlocks from local state
STATE_DIR="/tmp/flowswap_e2e_state"
H_USER=$(cat "$STATE_DIR/H_user" 2>/dev/null)
H_LP1=$(cat "$STATE_DIR/H_lp1" 2>/dev/null)
H_LP2=$(cat "$STATE_DIR/H_lp2" 2>/dev/null)

if [[ -z "$H_USER" ]] || [[ -z "$H_LP1" ]] || [[ -z "$H_LP2" ]]; then
    echo "ERROR: Missing hashlocks in $STATE_DIR"
    exit 1
fi

echo "=== Verifying USDC Contract on Base Sepolia ==="
echo "Hashlocks (from local state):"
echo "  H_user: $H_USER"
echo "  H_lp1: $H_LP1"
echo "  H_lp2: $H_LP2"
echo ""

ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && H_USER='$H_USER' H_LP1='$H_LP1' H_LP2='$H_LP2' python3 << 'PYEOF'
import json
from web3 import Web3
import time

RPC_URL = 'https://sepolia.base.org'
USDC_ADDRESS = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
HTLC3S_ADDRESS = '0x667E9bDC368F0aC2abff69F5963714e3656d2d9D'

w3 = Web3(Web3.HTTPProvider(RPC_URL))
print(f'Connected: {w3.is_connected()}')
print(f'Block: {w3.eth.block_number}')
print()

# Check USDC contract
usdc_code = w3.eth.get_code(Web3.to_checksum_address(USDC_ADDRESS))
print(f'USDC contract code size: {len(usdc_code)} bytes')

htlc_code = w3.eth.get_code(Web3.to_checksum_address(HTLC3S_ADDRESS))
print(f'HTLC3S contract code size: {len(htlc_code)} bytes')
print()

# Extended USDC ABI
usdc_abi = [
    {'name': 'name', 'type': 'function', 'stateMutability': 'view',
     'inputs': [], 'outputs': [{'name': '', 'type': 'string'}]},
    {'name': 'symbol', 'type': 'function', 'stateMutability': 'view',
     'inputs': [], 'outputs': [{'name': '', 'type': 'string'}]},
    {'name': 'decimals', 'type': 'function', 'stateMutability': 'view',
     'inputs': [], 'outputs': [{'name': '', 'type': 'uint8'}]},
    {'name': 'balanceOf', 'type': 'function', 'stateMutability': 'view',
     'inputs': [{'name': 'account', 'type': 'address'}],
     'outputs': [{'name': '', 'type': 'uint256'}]},
    {'name': 'allowance', 'type': 'function', 'stateMutability': 'view',
     'inputs': [{'name': 'owner', 'type': 'address'}, {'name': 'spender', 'type': 'address'}],
     'outputs': [{'name': '', 'type': 'uint256'}]},
]

usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_ADDRESS), abi=usdc_abi)

try:
    name = usdc.functions.name().call()
    symbol = usdc.functions.symbol().call()
    decimals = usdc.functions.decimals().call()
    print(f'USDC Token: {name} ({symbol})')
    print(f'Decimals: {decimals}')
except Exception as e:
    print(f'Error getting USDC info: {e}')

print()

# Load Bob's key
with open('/home/ubuntu/.BathronKey/evm.json') as f:
    key_data = json.load(f)

pk = key_data.get('private_key') or key_data.get('bob_private_key')
account = w3.eth.account.from_key(pk)
bob_addr = account.address
print(f'Bob address: {bob_addr}')

balance = usdc.functions.balanceOf(bob_addr).call()
allowance = usdc.functions.allowance(bob_addr, Web3.to_checksum_address(HTLC3S_ADDRESS)).call()

print(f'Bob USDC balance: {balance} ({balance/10**decimals} USDC)')
print(f'Bob allowance to HTLC3S: {allowance}')
print()

# Read hashlocks from environment
import os
print('Reading hashlocks from environment...')
H_user = os.environ.get('H_USER', '')
H_lp1 = os.environ.get('H_LP1', '')
H_lp2 = os.environ.get('H_LP2', '')

if not H_user or not H_lp1 or not H_lp2:
    print('ERROR: Missing hashlock environment variables')
    exit(1)

print(f'H_user: {H_user}')
print(f'H_lp1: {H_lp1}')
print(f'H_lp2: {H_lp2}')
print()

# Build create call
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
     'outputs': [{'name': 'htlcId', 'type': 'bytes32'}]}
]

htlc = w3.eth.contract(address=HTLC3S_ADDRESS, abi=htlc_abi)

recipient = '0x9f11B03618DeE8f12E7F90e753093B613CeD51D2'  # Charlie
amount = 5_000_000  # 5 USDC
timelock = int(time.time()) + 3600  # 1 hour

print(f'Recipient: {recipient}')
print(f'Token: {USDC_ADDRESS}')
print(f'Amount: {amount} ({amount/1e6} USDC)')
print(f'Timelock: {timelock}')
print(f'Current time: {int(time.time())}')
print()

# Convert hashlocks
def to_bytes32(hex_str):
    if hex_str.startswith('0x'):
        hex_str = hex_str[2:]
    return bytes.fromhex(hex_str)

# Check if hashlocks are valid bytes32
print('Validating hashlocks...')
for name, val in [('H_user', H_user), ('H_lp1', H_lp1), ('H_lp2', H_lp2)]:
    b = to_bytes32(val)
    print(f'  {name}: len={len(b)}, zero={b == bytes(32)}')

h_user = to_bytes32(H_user)
h_lp1 = to_bytes32(H_lp1)
h_lp2 = to_bytes32(H_lp2)
print()

# Try gas estimation
print('Attempting gas estimation...')
try:
    gas = htlc.functions.create(
        Web3.to_checksum_address(recipient),
        Web3.to_checksum_address(USDC_ADDRESS),
        amount,
        h_user,
        h_lp1,
        h_lp2,
        timelock
    ).estimate_gas({'from': bob_addr})
    print(f'SUCCESS! Gas estimate: {gas}')
except Exception as e:
    print(f'FAILED: {e}')
    print(f'Error type: {type(e).__name__}')

    # Try with call to get more info
    print()
    print('Trying static call...')
    try:
        result = htlc.functions.create(
            Web3.to_checksum_address(recipient),
            Web3.to_checksum_address(USDC_ADDRESS),
            amount,
            h_user,
            h_lp1,
            h_lp2,
            timelock
        ).call({'from': bob_addr})
        print(f'Static call result: 0x{result.hex()}')
    except Exception as e2:
        print(f'Static call failed: {e2}')

        # Try with different error decoding
        if hasattr(e2, 'data'):
            print(f'Error data: {e2.data}')
        if hasattr(e2, 'message'):
            print(f'Error message: {e2.message}')
PYEOF
"
