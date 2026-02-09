#!/bin/bash
set -e

# Script: Create USDC HTLC for 4-HTLC atomic swap
# VPS: OP3 (51.75.31.44) - charlie (fake user)

OP3_IP="51.75.31.44"
SWAP_DETAILS="/tmp/4htlc_swap_details.json"

echo "=== Creating USDC HTLC on Base Sepolia ==="

# Read swap details
if [[ ! -f "$SWAP_DETAILS" ]]; then
    echo "ERROR: Swap details not found at $SWAP_DETAILS"
    exit 1
fi

SWAP_ID=$(jq -r '.swap_id' "$SWAP_DETAILS")
SECRET=$(jq -r '.secret' "$SWAP_DETAILS")
HASHLOCK=$(jq -r '.hashlock' "$SWAP_DETAILS")
HTLC_CONTRACT=$(jq -r '.htlc_contract' "$SWAP_DETAILS")
RECEIVER=$(jq -r '.receiver' "$SWAP_DETAILS")
TOKEN=$(jq -r '.token' "$SWAP_DETAILS")
AMOUNT_WEI=$(jq -r '.amount_wei' "$SWAP_DETAILS")
TIMELOCK=$(jq -r '.timelock_seconds' "$SWAP_DETAILS")

echo "Swap ID: $SWAP_ID"
echo "HTLC Contract: $HTLC_CONTRACT"
echo "Receiver (LP): $RECEIVER"
echo "Token (USDC): $TOKEN"
echo "Amount: $AMOUNT_WEI wei (2 USDC)"
echo "Timelock: $TIMELOCK seconds"

# Copy swap details to OP3
echo ""
echo "Copying swap details to OP3..."
scp -i ~/.ssh/id_ed25519_vps "$SWAP_DETAILS" ubuntu@$OP3_IP:/tmp/4htlc_swap_details.json

# Create Python script on OP3
ssh -i ~/.ssh/id_ed25519_vps ubuntu@$OP3_IP 'cat > /tmp/create_usdc_htlc.py' << 'PYTHON_EOF'
#!/usr/bin/env python3
import json
import sys
from web3 import Web3
from eth_account import Account

# Configuration
RPC_URL = "https://sepolia.base.org"
CHAIN_ID = 84532

# Load swap details
with open('/tmp/4htlc_swap_details.json', 'r') as f:
    swap = json.load(f)

# Load EVM private key
with open('/home/ubuntu/.keys/user_evm.json', 'r') as f:
    keys = json.load(f)
    PRIVATE_KEY = keys['private_key']

# Connect to Base Sepolia
w3 = Web3(Web3.HTTPProvider(RPC_URL))
if not w3.is_connected():
    print("ERROR: Cannot connect to Base Sepolia")
    sys.exit(1)

print(f"Connected to Base Sepolia (Chain ID: {w3.eth.chain_id})")

# Account
account = Account.from_key(PRIVATE_KEY)
print(f"User address: {account.address}")

# Contract ABIs
ERC20_ABI = [
    {
        "inputs": [{"name": "spender", "type": "address"}, {"name": "amount", "type": "uint256"}],
        "name": "approve",
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}],
        "name": "allowance",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    },
    {
        "inputs": [{"name": "account", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"name": "", "type": "uint256"}],
        "stateMutability": "view",
        "type": "function"
    }
]

HTLC_ABI = [
    {
        "inputs": [
            {"name": "receiver", "type": "address"},
            {"name": "hashlock", "type": "bytes32"},
            {"name": "timelock", "type": "uint256"},
            {"name": "token", "type": "address"},
            {"name": "amount", "type": "uint256"}
        ],
        "name": "newContract",
        "outputs": [{"name": "contractId", "type": "bytes32"}],
        "stateMutability": "nonpayable",
        "type": "function"
    }
]

# Contracts
usdc = w3.eth.contract(address=Web3.to_checksum_address(swap['token']), abi=ERC20_ABI)
htlc = w3.eth.contract(address=Web3.to_checksum_address(swap['htlc_contract']), abi=HTLC_ABI)

# Check balance
balance = usdc.functions.balanceOf(account.address).call()
print(f"USDC balance: {balance} wei ({balance/1e6} USDC)")

if balance < swap['amount_wei']:
    print(f"ERROR: Insufficient balance. Need {swap['amount_wei']} wei, have {balance} wei")
    sys.exit(1)

# Check allowance
allowance = usdc.functions.allowance(account.address, swap['htlc_contract']).call()
print(f"Current allowance: {allowance} wei")

# Approve if needed
if allowance < swap['amount_wei']:
    print(f"Approving HTLC contract to spend {swap['amount_wei']} USDC...")
    
    approve_tx = usdc.functions.approve(
        Web3.to_checksum_address(swap['htlc_contract']),
        swap['amount_wei']
    ).build_transaction({
        'from': account.address,
        'nonce': w3.eth.get_transaction_count(account.address),
        'gas': 100000,
        'gasPrice': w3.eth.gas_price,
        'chainId': CHAIN_ID
    })
    
    signed_approve = account.sign_transaction(approve_tx)
    approve_hash = w3.eth.send_raw_transaction(signed_approve.raw_transaction)
    print(f"Approval TX: {approve_hash.hex()}")
    
    approve_receipt = w3.eth.wait_for_transaction_receipt(approve_hash, timeout=120)
    if approve_receipt['status'] != 1:
        print("ERROR: Approval transaction failed")
        sys.exit(1)
    print("Approval confirmed")

# Create HTLC
print(f"\nCreating HTLC...")
print(f"  Receiver: {swap['receiver']}")
print(f"  Hashlock: {swap['hashlock']}")
print(f"  Timelock: {swap['timelock_seconds']} seconds")
print(f"  Token: {swap['token']}")
print(f"  Amount: {swap['amount_wei']} wei")

timelock_absolute = w3.eth.get_block('latest')['timestamp'] + swap['timelock_seconds']

htlc_tx = htlc.functions.newContract(
    Web3.to_checksum_address(swap['receiver']),
    bytes.fromhex(swap['hashlock']),
    timelock_absolute,
    Web3.to_checksum_address(swap['token']),
    swap['amount_wei']
).build_transaction({
    'from': account.address,
    'nonce': w3.eth.get_transaction_count(account.address),
    'gas': 300000,
    'gasPrice': w3.eth.gas_price,
    'chainId': CHAIN_ID
})

signed_htlc = account.sign_transaction(htlc_tx)
htlc_hash = w3.eth.send_raw_transaction(signed_htlc.raw_transaction)
print(f"\nHTLC TX: {htlc_hash.hex()}")

htlc_receipt = w3.eth.wait_for_transaction_receipt(htlc_hash, timeout=120)
if htlc_receipt['status'] != 1:
    print("ERROR: HTLC transaction failed")
    sys.exit(1)

# Extract HTLC ID from logs
htlc_id = None
for log in htlc_receipt['logs']:
    if log['address'].lower() == swap['htlc_contract'].lower():
        # First topic after event signature is the contractId
        if len(log['topics']) > 1:
            htlc_id = log['topics'][1].hex()
            break

if not htlc_id:
    print("ERROR: Could not extract HTLC ID from logs")
    sys.exit(1)

print(f"\n=== SUCCESS ===")
print(f"HTLC Created!")
print(f"TX Hash: {htlc_hash.hex()}")
print(f"HTLC ID: {htlc_id}")
print(f"Block: {htlc_receipt['blockNumber']}")
print(f"Gas Used: {htlc_receipt['gasUsed']}")

# Save result
result = {
    'tx_hash': htlc_hash.hex(),
    'htlc_id': htlc_id,
    'block': htlc_receipt['blockNumber'],
    'gas_used': htlc_receipt['gasUsed']
}

with open('/tmp/usdc_htlc_result.json', 'w') as f:
    json.dump(result, f, indent=2)

print("\nResult saved to /tmp/usdc_htlc_result.json")
PYTHON_EOF

# Execute Python script on OP3
echo ""
echo "Executing HTLC creation on OP3..."
ssh -i ~/.ssh/id_ed25519_vps ubuntu@$OP3_IP 'python3 /tmp/create_usdc_htlc.py'

# Retrieve result
echo ""
echo "Retrieving result..."
scp -i ~/.ssh/id_ed25519_vps ubuntu@$OP3_IP:/tmp/usdc_htlc_result.json /tmp/usdc_htlc_result.json

if [[ -f /tmp/usdc_htlc_result.json ]]; then
    TX_HASH=$(jq -r '.tx_hash' /tmp/usdc_htlc_result.json)
    HTLC_ID=$(jq -r '.htlc_id' /tmp/usdc_htlc_result.json)
    
    echo ""
    echo "=== Registering HTLC with LP ==="
    curl -X POST "http://57.131.33.152:8080/api/swap/full/${SWAP_ID}/register-htlc?htlc_id=${HTLC_ID}" \
         -H "Content-Type: application/json"
    
    echo ""
    echo ""
    echo "=== USDC HTLC CREATED ==="
    echo "TX Hash: $TX_HASH"
    echo "HTLC ID: $HTLC_ID"
    echo "Explorer: https://sepolia.basescan.org/tx/$TX_HASH"
else
    echo "ERROR: Could not retrieve result"
    exit 1
fi
