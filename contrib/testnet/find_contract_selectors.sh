#!/bin/bash
# Find actual function selectors in HTLC3S contract bytecode

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"

echo "=== Finding Actual Selectors in Contract ==="

ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && python3 << 'PYEOF'
from web3 import Web3

RPC_URL = 'https://sepolia.base.org'
HTLC3S_ADDRESS = '0x667E9bDC368F0aC2abff69F5963714e3656d2d9D'

w3 = Web3(Web3.HTTPProvider(RPC_URL))

# Get bytecode
code = w3.eth.get_code(HTLC3S_ADDRESS)
bytecode = code.hex()

print(f'Bytecode length: {len(code)} bytes')
print()

# Common function signatures to check
signatures = {
    # Different create variants
    'create(address,address,uint256,bytes32,bytes32,bytes32,uint256)': 'd7315df3',
    'newContract(address,address,uint256,bytes32,bytes32,bytes32,uint256)': None,
    'lock(address,address,uint256,bytes32,bytes32,bytes32,uint256)': None,

    # HTLC functions
    'claim(bytes32,bytes32,bytes32,bytes32)': 'fcdc372b',
    'refund(bytes32)': '7249fbb6',

    # View functions
    'getHTLC(bytes32)': '90c26838',
    'htlcs(bytes32)': '91edd8f2',
    'getContract(bytes32)': None,
    'contracts(bytes32)': None,
}

# Calculate any missing selectors
for sig, expected in list(signatures.items()):
    if expected is None:
        selector = w3.keccak(text=sig)[:4].hex()
        signatures[sig] = selector

print('Checking known signatures:')
for sig, selector in signatures.items():
    found = selector in bytecode
    status = '✓' if found else '✗'
    print(f'  {status} {selector} - {sig[:60]}')

print()

# Search for dispatch pattern in bytecode
# Solidity typically uses PUSH4 (0x63) followed by selector, then EQ
# Let's find all PUSH4 operations
print('Searching for PUSH4 patterns in bytecode...')

selectors_found = set()
i = 0
while i < len(bytecode) - 8:
    # PUSH4 is 0x63
    if bytecode[i:i+2] == '63':
        selector = bytecode[i+2:i+10]
        selectors_found.add(selector)
        i += 10
    else:
        i += 2

print(f'Found {len(selectors_found)} potential selectors:')
for sel in sorted(selectors_found):
    # Try to identify known selectors
    identified = None
    for sig, known_sel in signatures.items():
        if sel == known_sel:
            identified = sig
            break

    if identified:
        print(f'  0x{sel} = {identified}')
    else:
        print(f'  0x{sel} = (unknown)')

print()
print('=== Let''s try different create signatures ===')

# Try different possible create function signatures
create_variants = [
    'create(address,address,uint256,bytes32,bytes32,bytes32,uint256)',
    'newHTLC(address,address,uint256,bytes32,bytes32,bytes32,uint256)',
    'lock(address,address,uint256,bytes32,bytes32,bytes32,uint256)',
    'deposit(address,address,uint256,bytes32,bytes32,bytes32,uint256)',
    'createHTLC(address,address,uint256,bytes32,bytes32,bytes32,uint256)',
]

print('Checking create variants:')
for variant in create_variants:
    selector = w3.keccak(text=variant)[:4].hex()
    found = selector in bytecode
    status = '✓' if found else '✗'
    print(f'  {status} 0x{selector} - {variant[:60]}')

# Check if maybe the selector is the public mapping vs a function
# The mapping htlcs would have selector based on struct accessors
print()
print('=== Raw dispatcher analysis ===')

# Look at the beginning of the runtime bytecode for dispatcher patterns
# First ~200 bytes usually contain the function dispatcher
dispatcher = bytecode[:400]  # First 200 bytes
print('First 200 bytes (hex):')
for i in range(0, len(dispatcher), 64):
    print(f'  {dispatcher[i:i+64]}')
PYEOF
"
