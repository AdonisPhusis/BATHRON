#!/bin/bash
# Send USDC from LP wallet to fake user wallet
# Usage: ./send_usdc_to_user.sh [amount_usdc]

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

AMOUNT_USDC=${1:-15}
USER_ADDRESS="0x4928542712Ab06c6C1963c42091827Cb2D70d265"

echo "=== Sending $AMOUNT_USDC USDC to Fake User ==="
echo "From: LP Wallet (OP1)"
echo "To:   $USER_ADDRESS"
echo ""

ssh -i $SSH_KEY ubuntu@$OP1_IP "
cd ~/pna-sdk && ./venv/bin/python3 << PYEOF
from web3 import Web3
from eth_account import Account
import json

# Config
RPC_URL = 'https://sepolia.base.org'
CHAIN_ID = 84532
USDC_CONTRACT = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'

# Load LP wallet
with open('/home/ubuntu/.keys/lp_evm.json') as f:
    lp = json.load(f)

LP_ADDRESS = lp['address']
LP_PRIVKEY = lp['private_key']
if not LP_PRIVKEY.startswith('0x'):
    LP_PRIVKEY = '0x' + LP_PRIVKEY

USER_ADDRESS = '$USER_ADDRESS'
AMOUNT_USDC = $AMOUNT_USDC

# Connect
w3 = Web3(Web3.HTTPProvider(RPC_URL))
print(f'Connected: {w3.is_connected()}')

# ERC20 ABI for transfer
usdc_abi = [
    {'name': 'transfer', 'type': 'function', 'inputs': [{'name': 'to', 'type': 'address'}, {'name': 'amount', 'type': 'uint256'}], 'outputs': [{'name': '', 'type': 'bool'}]},
    {'name': 'balanceOf', 'type': 'function', 'stateMutability': 'view', 'inputs': [{'name': 'account', 'type': 'address'}], 'outputs': [{'name': '', 'type': 'uint256'}]}
]

usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_CONTRACT), abi=usdc_abi)

# Check balance
balance = usdc.functions.balanceOf(LP_ADDRESS).call()
print(f'LP USDC Balance: {balance / 1e6:.2f} USDC')

amount_wei = int(AMOUNT_USDC * 1e6)
print(f'Sending: {AMOUNT_USDC} USDC ({amount_wei} wei)')

if balance < amount_wei:
    print('ERROR: Insufficient USDC balance')
    exit(1)

# Build transaction
account = Account.from_key(LP_PRIVKEY)
nonce = w3.eth.get_transaction_count(LP_ADDRESS, 'pending')
gas_price = int(w3.eth.gas_price * 1.1)

tx = usdc.functions.transfer(
    Web3.to_checksum_address(USER_ADDRESS),
    amount_wei
).build_transaction({
    'from': LP_ADDRESS,
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
print(f'Status: {\"SUCCESS\" if receipt[\"status\"] == 1 else \"FAILED\"}')

# Check new balances
lp_new = usdc.functions.balanceOf(LP_ADDRESS).call() / 1e6
user_new = usdc.functions.balanceOf(USER_ADDRESS).call() / 1e6
print(f'')
print(f'New LP USDC Balance: {lp_new:.2f} USDC')
print(f'User USDC Balance: {user_new:.2f} USDC')
print(f'')
print(f'Explorer: https://sepolia.basescan.org/tx/{tx_hash.hex()}')
PYEOF
"
