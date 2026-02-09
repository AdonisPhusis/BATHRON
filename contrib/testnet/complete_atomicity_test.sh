#!/bin/bash
# Complete the atomicity test:
# 1. Extract secrets from BTC claim witness
# 2. Claim USDC using extracted secrets

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

BTC_CLAIM_TXID="699e3747c563d184c77750a6d5fbadbb384bc150087769a73d1ba7a8b123bed9"

echo "============================================================"
echo "COMPLETE ATOMICITY TEST - EXTRACT FROM BTC, CLAIM USDC"
echo "============================================================"
echo ""
echo "BTC Claim TXID: $BTC_CLAIM_TXID"
echo ""

# Step 1: Extract secrets from BTC witness
echo "=== STEP 1: Extract secrets from BTC witness ==="
echo ""

EXTRACT_RESULT=$(ssh $SSH_OPTS ubuntu@$OP3_IP "
CLI='/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet'

python3 << 'PYEOF'
import subprocess
import json

CLI = '/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet'

def run_cli(cmd):
    result = subprocess.run(f\"{CLI} {cmd}\", shell=True, capture_output=True, text=True)
    return result.stdout.strip()

# Get raw tx
txid = '$BTC_CLAIM_TXID'
raw_tx = run_cli(f'getrawtransaction {txid} 1')

if not raw_tx:
    print('ERROR: TX not found (may not be in mempool yet)')
    exit(1)

tx = json.loads(raw_tx)
print(f'TX found. Confirmations: {tx.get(\"confirmations\", 0)}')

# Extract witness from first input
witness = tx['vin'][0].get('txinwitness', [])
print(f'Witness items: {len(witness)}')

# Witness structure for 3-secret HTLC:
# [0] signature
# [1] S_lp2
# [2] S_lp1
# [3] S_user
# [4] TRUE (0x01)
# [5] HTLC script

if len(witness) < 5:
    print(f'ERROR: Expected 6 witness items, got {len(witness)}')
    exit(1)

# Extract secrets
s_lp2 = witness[1]
s_lp1 = witness[2]
s_user = witness[3]

print()
print('SECRETS EXTRACTED FROM BTC WITNESS:')
print(f'S_user: {s_user}')
print(f'S_lp1:  {s_lp1}')
print(f'S_lp2:  {s_lp2}')

# Output for shell
print()
print(f'EXTRACTED_S_USER={s_user}')
print(f'EXTRACTED_S_LP1={s_lp1}')
print(f'EXTRACTED_S_LP2={s_lp2}')
PYEOF
")

echo "$EXTRACT_RESULT"

# Parse extracted secrets
EXTRACTED_S_USER=$(echo "$EXTRACT_RESULT" | grep "EXTRACTED_S_USER=" | cut -d= -f2)
EXTRACTED_S_LP1=$(echo "$EXTRACT_RESULT" | grep "EXTRACTED_S_LP1=" | cut -d= -f2)
EXTRACTED_S_LP2=$(echo "$EXTRACT_RESULT" | grep "EXTRACTED_S_LP2=" | cut -d= -f2)

if [ -z "$EXTRACTED_S_USER" ] || [ -z "$EXTRACTED_S_LP1" ] || [ -z "$EXTRACTED_S_LP2" ]; then
    echo ""
    echo "ERROR: Could not extract secrets from BTC witness"
    exit 1
fi

echo ""
echo "=== STEP 2: Claim USDC using extracted secrets ==="
echo ""

# Now claim USDC on EVM using these extracted secrets
ssh $SSH_OPTS ubuntu@$OP1_IP "
cd /home/ubuntu/pna-lp
source /home/ubuntu/pna-lp-venv/bin/activate

python3 << PYEOF
import os
import sys
import hashlib
from web3 import Web3
from eth_account import Account

# EVM Setup
w3 = Web3(Web3.HTTPProvider('https://sepolia.base.org'))
print(f'Connected to Base Sepolia: {w3.is_connected()}')

# Contract
CONTRACT_ADDR = '0x667E9bDC368F0aC2abff69F5963714e3656d2d9D'
ABI = [
    {
        'inputs': [
            {'name': '_htlcId', 'type': 'bytes32'},
            {'name': '_s_user', 'type': 'bytes32'},
            {'name': '_s_lp1', 'type': 'bytes32'},
            {'name': '_s_lp2', 'type': 'bytes32'}
        ],
        'name': 'claim',
        'outputs': [],
        'stateMutability': 'nonpayable',
        'type': 'function'
    },
    {
        'inputs': [{'name': '', 'type': 'bytes32'}],
        'name': 'htlcs',
        'outputs': [
            {'name': 'sender', 'type': 'address'},
            {'name': 'recipient', 'type': 'address'},
            {'name': 'token', 'type': 'address'},
            {'name': 'amount', 'type': 'uint256'},
            {'name': 'h_user', 'type': 'bytes32'},
            {'name': 'h_lp1', 'type': 'bytes32'},
            {'name': 'h_lp2', 'type': 'bytes32'},
            {'name': 'timelock', 'type': 'uint256'},
            {'name': 'claimed', 'type': 'bool'},
            {'name': 'refunded', 'type': 'bool'}
        ],
        'stateMutability': 'view',
        'type': 'function'
    }
]
contract = w3.eth.contract(address=CONTRACT_ADDR, abi=ABI)

# Secrets EXTRACTED FROM BTC WITNESS (not from file!)
s_user_hex = '$EXTRACTED_S_USER'
s_lp1_hex = '$EXTRACTED_S_LP1'
s_lp2_hex = '$EXTRACTED_S_LP2'

print()
print('Secrets from BTC witness:')
print(f'  S_user: {s_user_hex[:32]}...')
print(f'  S_lp1:  {s_lp1_hex[:32]}...')
print(f'  S_lp2:  {s_lp2_hex[:32]}...')

# Calculate HTLC ID
s_user = bytes.fromhex(s_user_hex)
s_lp1 = bytes.fromhex(s_lp1_hex)
s_lp2 = bytes.fromhex(s_lp2_hex)

h_user = hashlib.sha256(s_user).digest()
h_lp1 = hashlib.sha256(s_lp1).digest()
h_lp2 = hashlib.sha256(s_lp2).digest()

htlc_id = hashlib.sha256(h_user + h_lp1 + h_lp2).digest()
print(f'  HTLC ID: {htlc_id.hex()[:32]}...')

# Check HTLC status
htlc = contract.functions.htlcs(htlc_id).call()
print()
print('HTLC Status:')
print(f'  Amount: {htlc[3] / 10**6} USDC')
print(f'  Recipient: {htlc[1]}')
print(f'  Claimed: {htlc[8]}')
print(f'  Refunded: {htlc[9]}')

if htlc[8]:
    print()
    print('HTLC already claimed!')
    sys.exit(0)

if htlc[9]:
    print()
    print('HTLC was refunded!')
    sys.exit(1)

# Load LP wallet for gas
with open('/home/ubuntu/.BathronKey/evm.json') as f:
    import json as j
    evm_key = j.load(f)['private_key']

account = Account.from_key(evm_key)
print()
print(f'Claiming from: {account.address}')

# Build claim TX
nonce = w3.eth.get_transaction_count(account.address)
gas_price = w3.eth.gas_price

tx = contract.functions.claim(
    htlc_id,
    s_user,
    s_lp1,
    s_lp2
).build_transaction({
    'from': account.address,
    'nonce': nonce,
    'gas': 200000,
    'gasPrice': int(gas_price * 1.2)
})

signed = account.sign_transaction(tx)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
print(f'Claim TX sent: {tx_hash.hex()}')

# Wait for receipt
print('Waiting for confirmation...')
receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

if receipt['status'] == 1:
    print()
    print('=' * 60)
    print('SUCCESS! USDC CLAIMED USING BTC WITNESS SECRETS')
    print('=' * 60)
    print(f'TX: https://sepolia.basescan.org/tx/{tx_hash.hex()}')
    print()
    print('ATOMICITY PROVEN:')
    print('  1. BTC HTLC claimed, revealing secrets in witness')
    print('  2. Secrets extracted from BTC mempool/chain')
    print('  3. USDC claimed using extracted secrets')
    print()
    print('The ONLY way secrets appeared was through BTC claim!')
else:
    print(f'Claim failed! Status: {receipt[\"status\"]}')
PYEOF
"

echo ""
echo "============================================================"
echo "ATOMICITY TEST COMPLETE"
echo "============================================================"
