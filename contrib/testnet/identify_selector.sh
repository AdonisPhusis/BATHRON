#!/bin/bash
# Identify unknown function selectors

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"

echo "=== Identifying Unknown Selectors ==="

ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && python3 << 'PYEOF'
from web3 import Web3

w3 = Web3()

# Target selectors to identify
targets = ['031a27da', '3da0e66e', 'eb84e7f2']

# Possible function names and parameter combos
names = ['create', 'newContract', 'lock', 'deposit', 'open']
param_variants = [
    '(address,address,uint256,bytes32,bytes32,bytes32,uint256)',
    '(address,address,uint256,bytes32,bytes32,bytes32,uint64)',
    '(address,address,uint256,uint256,bytes32,bytes32,bytes32)',
    '(address,uint256,address,bytes32,bytes32,bytes32,uint256)',
]

# View function possibilities
view_names = ['getHTLC', 'getContract', 'contracts', 'htlcs']
view_params = ['(bytes32)']

# Check create variants
print('Checking create function variants...')
for name in names:
    for params in param_variants:
        sig = name + params
        selector = w3.keccak(text=sig)[:4].hex()
        if selector in targets:
            print(f'  MATCH: 0x{selector} = {sig}')

# Check view function variants
print()
print('Checking view function variants...')
for name in view_names:
    for params in view_params:
        sig = name + params
        selector = w3.keccak(text=sig)[:4].hex()
        if selector in targets:
            print(f'  MATCH: 0x{selector} = {sig}')

# Check additional possibilities
print()
print('Checking other common patterns...')
other_sigs = [
    'canClaim(bytes32,bytes32,bytes32,bytes32)',
    'canRefund(bytes32)',
    'withdraw(bytes32,bytes32,bytes32,bytes32)',
    'isRefundable(bytes32)',
    'isClaimed(bytes32)',
]
for sig in other_sigs:
    selector = w3.keccak(text=sig)[:4].hex()
    if selector in targets:
        print(f'  MATCH: 0x{selector} = {sig}')
    else:
        print(f'  0x{selector} = {sig}')

# Try ERC20 selectors (these are in the bytecode as called functions)
print()
print('Standard ERC20 selectors (called by contract):')
erc20_sigs = [
    'transfer(address,uint256)',      # 0xa9059cbb
    'transferFrom(address,address,uint256)',  # 0x23b872dd
    'approve(address,uint256)',
    'balanceOf(address)',
    'allowance(address,address)',
]
for sig in erc20_sigs:
    selector = w3.keccak(text=sig)[:4].hex()
    print(f'  0x{selector} = {sig}')

# Let me try to brute force common variants
print()
print('=== Brute forcing common function signatures ===')

# The 0x031a27da selector must be the create function
# Let's try variations with different orderings

import itertools

base_types = ['address', 'address', 'uint256', 'bytes32', 'bytes32', 'bytes32', 'uint256']

# Try with recipient/token swapped or different order
test_orders = [
    # Original
    ['address', 'address', 'uint256', 'bytes32', 'bytes32', 'bytes32', 'uint256'],
    # recipient,token,timelock,amount,h1,h2,h3
    ['address', 'address', 'uint256', 'uint256', 'bytes32', 'bytes32', 'bytes32'],
]

for name in ['create', 'lock', 'newContract']:
    for order in test_orders:
        sig = name + '(' + ','.join(order) + ')'
        selector = w3.keccak(text=sig)[:4].hex()
        if selector == '031a27da':
            print(f'FOUND: 0x{selector} = {sig}')

# Maybe the original create has a different parameter order
# Let me check what the actual deployed contract looks like
# from the deploy_htlc3s.py script

print()
print('=== Checking deployment script signature ===')

# From the contract source in deploy_htlc3s.py:
# create(address recipient, address token, uint256 amount,
#        bytes32 H_user, bytes32 H_lp1, bytes32 H_lp2, uint256 timelock)
#
# This should be selector d7315df3, but that's not in bytecode

# Wait - maybe the compiler optimized something or the source is different
# Let me try with fewer parameters or different ones

# Check if maybe it uses indexed bytes32 differently
test_sigs = [
    'create(address,address,uint256,bytes32,bytes32,bytes32,uint256)',  # Expected
    'create(address,uint256,address,bytes32,bytes32,bytes32,uint256)',  # Swapped
    'create(address,address,bytes32,bytes32,bytes32,uint256,uint256)',  # Different
]

for sig in test_sigs:
    selector = w3.keccak(text=sig)[:4].hex()
    print(f'  0x{selector} = {sig}')
PYEOF
"
