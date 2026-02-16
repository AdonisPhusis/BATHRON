#!/bin/bash
# Send USDC from any VPS wallet to a destination address
# Usage: ./send_usdc_to_user.sh <amount_usdc> <dest_address> [source: op1|op3|coresdk|op2]
#
# Examples:
#   ./send_usdc_to_user.sh 20 0xF127...252C op3     # from charlie
#   ./send_usdc_to_user.sh 10 0xF127...252C          # from OP1 (default)

SSH_KEY=~/.ssh/id_ed25519_vps

# VPS mapping
declare -A VPS_IPS=(
    [op1]="57.131.33.152"
    [op2]="57.131.33.214"
    [op3]="51.75.31.44"
    [coresdk]="162.19.251.75"
)
declare -A VPS_NAMES=(
    [op1]="LP1 (alice)"
    [op2]="LP2 (dev)"
    [op3]="Fake User (charlie)"
    [coresdk]="CoreSDK (bob)"
)
declare -A VPS_KEY_PATHS=(
    [op1]="/home/ubuntu/.BathronKey/evm.json"
    [op2]="/home/ubuntu/.BathronKey/evm.json"
    [op3]="/home/ubuntu/.BathronKey/evm.json"
    [coresdk]="/home/ubuntu/.BathronKey/evm.json"
)

AMOUNT_USDC=${1:-15}
DEST_ADDRESS=${2:-"0xF1276960727A9573D3aeff587e03974241b5252C"}
SOURCE=${3:-op1}

TARGET_IP=${VPS_IPS[$SOURCE]}
SOURCE_NAME=${VPS_NAMES[$SOURCE]}
KEY_PATH=${VPS_KEY_PATHS[$SOURCE]}

if [ -z "$TARGET_IP" ]; then
    echo "ERROR: Unknown source '$SOURCE'. Use: op1, op2, op3, coresdk"
    exit 1
fi

SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== Sending $AMOUNT_USDC USDC ==="
echo "From: $SOURCE_NAME ($TARGET_IP)"
echo "To:   $DEST_ADDRESS"
echo ""

$SSH ubuntu@$TARGET_IP "
cd ~/pna-sdk 2>/dev/null || cd ~
VENV=\$(find . -path '*/venv/bin/python3' -type f 2>/dev/null | head -1)
if [ -z \"\$VENV\" ]; then
    PYTHON=python3
else
    PYTHON=\$VENV
fi
\$PYTHON << PYEOF
from web3 import Web3
from eth_account import Account
import json

# Config
RPC_URL = 'https://sepolia.base.org'
CHAIN_ID = 84532
USDC_CONTRACT = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'

# Load wallet
key_path = '$KEY_PATH'
# Try both key formats
try:
    with open(key_path) as f:
        wallet = json.load(f)
    if 'address' in wallet:
        SENDER_ADDRESS = wallet['address']
        PRIVKEY = wallet.get('private_key', wallet.get('privateKey', ''))
    elif 'evm' in wallet:
        SENDER_ADDRESS = wallet['evm']['address']
        PRIVKEY = wallet['evm'].get('private_key', wallet['evm'].get('privateKey', ''))
    else:
        # Try first key in dict
        first = list(wallet.values())[0]
        if isinstance(first, dict):
            SENDER_ADDRESS = first['address']
            PRIVKEY = first.get('private_key', first.get('privateKey', ''))
        else:
            raise ValueError('Unknown key format')
except FileNotFoundError:
    # Fallback to old path
    with open('/home/ubuntu/.keys/lp_evm.json') as f:
        wallet = json.load(f)
    SENDER_ADDRESS = wallet['address']
    PRIVKEY = wallet.get('private_key', wallet.get('privateKey', ''))

if not PRIVKEY.startswith('0x'):
    PRIVKEY = '0x' + PRIVKEY

DEST_ADDRESS = '$DEST_ADDRESS'
AMOUNT_USDC = $AMOUNT_USDC

# Connect
w3 = Web3(Web3.HTTPProvider(RPC_URL))
print(f'Connected: {w3.is_connected()}')
print(f'Sender: {SENDER_ADDRESS}')

# ERC20 ABI for transfer
usdc_abi = [
    {'name': 'transfer', 'type': 'function', 'inputs': [{'name': 'to', 'type': 'address'}, {'name': 'amount', 'type': 'uint256'}], 'outputs': [{'name': '', 'type': 'bool'}]},
    {'name': 'balanceOf', 'type': 'function', 'stateMutability': 'view', 'inputs': [{'name': 'account', 'type': 'address'}], 'outputs': [{'name': '', 'type': 'uint256'}]}
]

usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_CONTRACT), abi=usdc_abi)

# Check balance
balance = usdc.functions.balanceOf(Web3.to_checksum_address(SENDER_ADDRESS)).call()
print(f'Sender USDC Balance: {balance / 1e6:.2f} USDC')

amount_wei = int(AMOUNT_USDC * 1e6)
print(f'Sending: {AMOUNT_USDC} USDC ({amount_wei} raw)')

if balance < amount_wei:
    print('ERROR: Insufficient USDC balance')
    exit(1)

# Check ETH for gas
eth_bal = w3.eth.get_balance(Web3.to_checksum_address(SENDER_ADDRESS))
print(f'ETH for gas: {eth_bal / 1e18:.6f} ETH')
if eth_bal < 50000 * 1000000000:  # ~50k gas * 1 gwei
    print('WARNING: Low ETH for gas!')

# Build transaction
account = Account.from_key(PRIVKEY)
nonce = w3.eth.get_transaction_count(Web3.to_checksum_address(SENDER_ADDRESS), 'pending')
gas_price = int(w3.eth.gas_price * 1.1)

tx = usdc.functions.transfer(
    Web3.to_checksum_address(DEST_ADDRESS),
    amount_wei
).build_transaction({
    'from': Web3.to_checksum_address(SENDER_ADDRESS),
    'nonce': nonce,
    'gas': 100000,
    'gasPrice': gas_price,
    'chainId': CHAIN_ID
})

# Sign and send
signed = account.sign_transaction(tx)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
print(f'TX Hash: {tx_hash.hex()}')

# Wait for confirmation
print('Waiting for confirmation...')
receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
st = 'SUCCESS' if receipt['status'] == 1 else 'FAILED'
print(f'Status: {st}')

# Check new balances
sender_new = usdc.functions.balanceOf(Web3.to_checksum_address(SENDER_ADDRESS)).call() / 1e6
dest_new = usdc.functions.balanceOf(Web3.to_checksum_address(DEST_ADDRESS)).call() / 1e6
print(f'')
print(f'Sender USDC: {sender_new:.2f} USDC')
print(f'Dest USDC:   {dest_new:.2f} USDC')
print(f'')
print(f'Explorer: https://sepolia.basescan.org/tx/{tx_hash.hex()}')
PYEOF
"
