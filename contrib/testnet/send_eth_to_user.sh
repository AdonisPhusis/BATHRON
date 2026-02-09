#!/bin/bash
# Send ETH from LP wallet to fake user wallet
# Usage: ./send_eth_to_user.sh [amount_eth]

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

AMOUNT_ETH=${1:-0.05}
USER_ADDRESS="0x4928542712Ab06c6C1963c42091827Cb2D70d265"

echo "=== Sending $AMOUNT_ETH ETH to Fake User ==="
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

# Load LP wallet
with open('/home/ubuntu/.keys/lp_evm.json') as f:
    lp = json.load(f)

LP_ADDRESS = lp['address']
LP_PRIVKEY = lp['private_key']
if not LP_PRIVKEY.startswith('0x'):
    LP_PRIVKEY = '0x' + LP_PRIVKEY

USER_ADDRESS = '$USER_ADDRESS'
AMOUNT_ETH = $AMOUNT_ETH

# Connect
w3 = Web3(Web3.HTTPProvider(RPC_URL))
print(f'Connected: {w3.is_connected()}')

# Check balance
balance = w3.eth.get_balance(LP_ADDRESS)
print(f'LP Balance: {balance / 1e18:.6f} ETH')

amount_wei = int(AMOUNT_ETH * 1e18)
print(f'Sending: {AMOUNT_ETH} ETH ({amount_wei} wei)')

if balance < amount_wei + 21000 * w3.eth.gas_price:
    print('ERROR: Insufficient balance')
    exit(1)

# Build transaction
account = Account.from_key(LP_PRIVKEY)
nonce = w3.eth.get_transaction_count(LP_ADDRESS, 'pending')
gas_price = int(w3.eth.gas_price * 1.1)

tx = {
    'nonce': nonce,
    'to': Web3.to_checksum_address(USER_ADDRESS),
    'value': amount_wei,
    'gas': 21000,
    'gasPrice': gas_price,
    'chainId': CHAIN_ID
}

# Sign and send
signed = account.sign_transaction(tx)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
print(f'TX Hash: {tx_hash.hex()}')

# Wait for confirmation
print('Waiting for confirmation...')
receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
print(f'Status: {\"SUCCESS\" if receipt[\"status\"] == 1 else \"FAILED\"}')
print(f'Gas used: {receipt[\"gasUsed\"]}')

# Check new balances
lp_new = w3.eth.get_balance(LP_ADDRESS) / 1e18
user_new = w3.eth.get_balance(USER_ADDRESS) / 1e18
print(f'')
print(f'New LP Balance: {lp_new:.6f} ETH')
print(f'User Balance: {user_new:.6f} ETH')
print(f'')
print(f'Explorer: https://sepolia.basescan.org/tx/{tx_hash.hex()}')
PYEOF
"
