#!/bin/bash
set -e

# Script: Create USDC HTLC for 4-HTLC atomic swap
# MUST be run on OP3 (51.75.31.44) - charlie (fake user)
#
# Reads parameters from /tmp/swap_details.json
# Creates USDC HTLC on Base Sepolia
# Registers with LP
# Reports final status

SCRIPT_NAME="create_usdc_htlc_for_swap.sh"
CURRENT_HOST=$(hostname)

# Check if running on OP3
if [[ "$CURRENT_HOST" != *"vps"* ]] && [[ "$CURRENT_HOST" != *"51.75.31.44"* ]]; then
    echo "ERROR: This script must be run on OP3 (51.75.31.44)"
    echo "Current host: $CURRENT_HOST"
    echo ""
    echo "Usage from dev machine:"
    echo "  ssh -i ~/.ssh/id_ed25519_vps ubuntu@51.75.31.44 'bash -s' < contrib/testnet/$SCRIPT_NAME"
    exit 1
fi

if [ ! -f /tmp/swap_details.json ]; then
    echo "ERROR: /tmp/swap_details.json not found"
    exit 1
fi

# Read swap details
SWAP_ID=$(jq -r '.swap_id' /tmp/swap_details.json)
SECRET=$(jq -r '.secret' /tmp/swap_details.json)
HASHLOCK=$(jq -r '.hashlock' /tmp/swap_details.json)
HTLC_CONTRACT=$(jq -r '.htlc_contract' /tmp/swap_details.json)
RECEIVER=$(jq -r '.receiver' /tmp/swap_details.json)
TOKEN=$(jq -r '.token' /tmp/swap_details.json)
AMOUNT_USDC=$(jq -r '.amount_usdc' /tmp/swap_details.json)
AMOUNT_WEI=$(jq -r '.amount_wei' /tmp/swap_details.json)
TIMELOCK_SECONDS=$(jq -r '.timelock_seconds' /tmp/swap_details.json)

echo "=== Creating USDC HTLC on Base Sepolia ==="
echo "Swap ID: $SWAP_ID"
echo "HTLC Contract: $HTLC_CONTRACT"
echo "Receiver (LP): $RECEIVER"
echo "Token (USDC): $TOKEN"
echo "Amount: $AMOUNT_USDC USDC ($AMOUNT_WEI wei)"
echo "Timelock: $TIMELOCK_SECONDS seconds"
echo ""

# Create Python script
cat > /tmp/create_usdc_htlc.py << 'PYTHON_EOF'
#!/usr/bin/env python3
"""
Create USDC HTLC on Base Sepolia for 4-HTLC atomic swap.
Runs on OP3 (51.75.31.44).
"""
import json
import sys
import os
import time

# Read swap parameters from environment
SWAP_ID = os.environ.get('SWAP_ID', '')
HASHLOCK = os.environ.get('HASHLOCK', '')
HTLC_CONTRACT = os.environ.get('HTLC_CONTRACT', '')
RECEIVER = os.environ.get('RECEIVER', '')
TOKEN = os.environ.get('TOKEN', '')
AMOUNT_USDC = float(os.environ.get('AMOUNT_USDC', '0'))
TIMELOCK_SECONDS = int(os.environ.get('TIMELOCK_SECONDS', '3600'))

# RPC Configuration
RPC_URL = "https://sepolia.base.org"
CHAIN_ID = 84532

# Load user EVM key
key_file = os.path.expanduser("~/.keys/user_evm.json")
if not os.path.exists(key_file):
    print(f"ERROR: EVM key file not found at {key_file}")
    print("Run: ./contrib/testnet/create_user_evm_wallet.sh")
    sys.exit(1)

with open(key_file, 'r') as f:
    keys = json.load(f)
    private_key = keys['private_key']
    user_address = keys['address']

print(f"User address: {user_address}")
print(f"Creating HTLC for {AMOUNT_USDC} USDC...")
print("")

# Import web3
try:
    from web3 import Web3
    from eth_account import Account
except ImportError:
    print("ERROR: web3 or eth_account not installed")
    print("Install: pip3 install web3 eth-account")
    sys.exit(1)

# Connect to Base Sepolia
w3 = Web3(Web3.HTTPProvider(RPC_URL))
if not w3.is_connected():
    print("ERROR: Cannot connect to Base Sepolia RPC")
    sys.exit(1)

print(f"Connected to Base Sepolia (Chain ID: {w3.eth.chain_id})")

# Account
if not private_key.startswith("0x"):
    private_key = "0x" + private_key
account = Account.from_key(private_key)
print(f"Account loaded: {account.address}")

# Contract ABIs
HTLC_ABI = [
    {
        "name": "create",
        "type": "function",
        "inputs": [
            {"name": "receiver", "type": "address"},
            {"name": "token", "type": "address"},
            {"name": "amount", "type": "uint256"},
            {"name": "hashlock", "type": "bytes32"},
            {"name": "timelock", "type": "uint256"}
        ],
        "outputs": [{"name": "htlcId", "type": "bytes32"}],
        "stateMutability": "nonpayable"
    }
]

ERC20_ABI = [
    {
        "name": "approve",
        "type": "function",
        "inputs": [
            {"name": "spender", "type": "address"},
            {"name": "amount", "type": "uint256"}
        ],
        "outputs": [{"name": "", "type": "bool"}],
        "stateMutability": "nonpayable"
    },
    {
        "name": "allowance",
        "type": "function",
        "stateMutability": "view",
        "inputs": [
            {"name": "owner", "type": "address"},
            {"name": "spender", "type": "address"}
        ],
        "outputs": [{"name": "", "type": "uint256"}]
    },
    {
        "name": "balanceOf",
        "type": "function",
        "stateMutability": "view",
        "inputs": [{"name": "account", "type": "address"}],
        "outputs": [{"name": "", "type": "uint256"}]
    }
]

# Contracts
usdc_contract = w3.eth.contract(
    address=Web3.to_checksum_address(TOKEN),
    abi=ERC20_ABI
)

htlc_contract = w3.eth.contract(
    address=Web3.to_checksum_address(HTLC_CONTRACT),
    abi=HTLC_ABI
)

# Check USDC balance
balance = usdc_contract.functions.balanceOf(account.address).call()
print(f"USDC balance: {balance} wei ({balance/1e6:.6f} USDC)")

amount_wei = int(AMOUNT_USDC * 1e6)
if balance < amount_wei:
    print(f"ERROR: Insufficient balance. Need {amount_wei} wei, have {balance} wei")
    print("Fund with: https://faucet.circle.com/ (Base Sepolia)")
    sys.exit(1)

# Check and approve if needed
allowance = usdc_contract.functions.allowance(
    account.address,
    Web3.to_checksum_address(HTLC_CONTRACT)
).call()

print(f"Current allowance: {allowance} wei")

if allowance < amount_wei:
    print(f"Approving HTLC contract to spend {amount_wei} USDC...")
    
    # Use max uint256 for unlimited approval
    MAX_UINT256 = 2**256 - 1
    
    nonce = w3.eth.get_transaction_count(account.address, 'pending')
    gas_price = int(w3.eth.gas_price * 1.2)  # 20% buffer
    
    approve_tx = usdc_contract.functions.approve(
        Web3.to_checksum_address(HTLC_CONTRACT),
        MAX_UINT256
    ).build_transaction({
        'from': account.address,
        'nonce': nonce,
        'gas': 100000,
        'gasPrice': gas_price,
        'chainId': CHAIN_ID
    })
    
    signed_approve = account.sign_transaction(approve_tx)
    approve_hash = w3.eth.send_raw_transaction(signed_approve.raw_transaction)
    print(f"Approval TX: {approve_hash.hex()}")
    
    # Wait for approval
    print("Waiting for approval confirmation...")
    approve_receipt = w3.eth.wait_for_transaction_receipt(approve_hash, timeout=120)
    
    if approve_receipt['status'] != 1:
        print("ERROR: Approval transaction failed")
        sys.exit(1)
    
    print("Approval confirmed!")

# Calculate absolute timelock
timelock = int(time.time()) + TIMELOCK_SECONDS

# Ensure hashlock is bytes32
if not HASHLOCK.startswith("0x"):
    hashlock_hex = "0x" + HASHLOCK
else:
    hashlock_hex = HASHLOCK
hashlock_bytes = bytes.fromhex(hashlock_hex[2:])

print("")
print("Creating HTLC...")
print(f"  Receiver: {RECEIVER}")
print(f"  Token: {TOKEN}")
print(f"  Amount: {amount_wei} wei ({AMOUNT_USDC} USDC)")
print(f"  Hashlock: {hashlock_hex}")
print(f"  Timelock: {timelock} ({TIMELOCK_SECONDS}s from now)")

# Simulate first
try:
    simulated_id = htlc_contract.functions.create(
        Web3.to_checksum_address(RECEIVER),
        Web3.to_checksum_address(TOKEN),
        amount_wei,
        hashlock_bytes,
        timelock
    ).call({'from': account.address})
    print(f"Simulation OK, expected HTLC ID: 0x{simulated_id.hex()}")
except Exception as e:
    print(f"ERROR: Simulation failed: {e}")
    sys.exit(1)

# Build and send transaction
nonce = w3.eth.get_transaction_count(account.address, 'pending')
gas_price = int(w3.eth.gas_price * 1.2)

create_tx = htlc_contract.functions.create(
    Web3.to_checksum_address(RECEIVER),
    Web3.to_checksum_address(TOKEN),
    amount_wei,
    hashlock_bytes,
    timelock
).build_transaction({
    'from': account.address,
    'nonce': nonce,
    'gas': 300000,
    'gasPrice': gas_price,
    'chainId': CHAIN_ID
})

signed_tx = account.sign_transaction(create_tx)
tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)

print(f"\nHTLC TX submitted: {tx_hash.hex()}")
print("Waiting for confirmation...")

receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

if receipt['status'] != 1:
    print("ERROR: HTLC transaction failed")
    sys.exit(1)

# Extract HTLC ID from logs
htlc_id = None
htlc_contract_lower = HTLC_CONTRACT.lower()

for log in receipt['logs']:
    log_addr = log['address'].lower() if isinstance(log['address'], str) else log['address'].hex().lower()
    if log_addr == htlc_contract_lower and len(log['topics']) >= 2:
        # topics[1] = htlcId (indexed)
        topic1 = log['topics'][1]
        htlc_id = topic1.hex() if hasattr(topic1, 'hex') else topic1
        if htlc_id.startswith('0x'):
            htlc_id = htlc_id[2:]
        htlc_id = '0x' + htlc_id
        break

if not htlc_id:
    # Fallback to simulated ID
    print("WARNING: Could not extract HTLC ID from logs, using simulated ID")
    htlc_id = f"0x{simulated_id.hex()}"

print("")
print("=== SUCCESS ===")
print(f"HTLC Created!")
print(f"TX Hash: {tx_hash.hex()}")
print(f"HTLC ID: {htlc_id}")
print(f"Block: {receipt['blockNumber']}")
print(f"Gas Used: {receipt['gasUsed']}")
print(f"Explorer: https://sepolia.basescan.org/tx/{tx_hash.hex()}")
print("")

# Save result
result = {
    'swap_id': SWAP_ID,
    'tx_hash': tx_hash.hex(),
    'htlc_id': htlc_id,
    'contract': HTLC_CONTRACT,
    'receiver': RECEIVER,
    'token': TOKEN,
    'amount_usdc': AMOUNT_USDC,
    'amount_wei': amount_wei,
    'hashlock': hashlock_hex,
    'timelock': timelock,
    'block': receipt['blockNumber'],
    'gas_used': receipt['gasUsed']
}

with open('/tmp/usdc_htlc_result.json', 'w') as f:
    json.dump(result, f, indent=2)

print("Result saved to /tmp/usdc_htlc_result.json")

# Output for parsing
print("HTLC_ID=" + htlc_id)
print("TX_HASH=" + tx_hash.hex())
PYTHON_EOF

# Execute Python script with environment variables
echo "Executing HTLC creation..."
SWAP_ID="$SWAP_ID" \
HASHLOCK="$HASHLOCK" \
HTLC_CONTRACT="$HTLC_CONTRACT" \
RECEIVER="$RECEIVER" \
TOKEN="$TOKEN" \
AMOUNT_USDC="$AMOUNT_USDC" \
TIMELOCK_SECONDS="$TIMELOCK_SECONDS" \
python3 /tmp/create_usdc_htlc.py | tee /tmp/htlc_output.txt

# Extract results
if grep -q "HTLC_ID=" /tmp/htlc_output.txt; then
    HTLC_ID=$(grep "HTLC_ID=" /tmp/htlc_output.txt | cut -d= -f2)
    TX_HASH=$(grep "TX_HASH=" /tmp/htlc_output.txt | cut -d= -f2)
    
    echo ""
    echo "=== Registering HTLC with LP ==="
    REGISTER_URL="http://57.131.33.152:8080/api/swap/full/${SWAP_ID}/register-htlc?htlc_id=${HTLC_ID}"
    echo "POST $REGISTER_URL"
    
    REGISTER_RESPONSE=$(curl -s -X POST "$REGISTER_URL" -H "Content-Type: application/json")
    echo "Response: $REGISTER_RESPONSE"
    
    echo ""
    echo "Waiting 15 seconds for LP to process..."
    sleep 15
    
    echo ""
    echo "=== Checking Swap Status ==="
    STATUS_URL="http://57.131.33.152:8080/api/swap/full/${SWAP_ID}/status"
    echo "GET $STATUS_URL"
    curl -s "$STATUS_URL" | jq '.'
    
    echo ""
    echo "=========================================="
    echo "=== USDC HTLC CREATED ==="
    echo "=========================================="
    echo "Swap ID: $SWAP_ID"
    echo "HTLC ID: $HTLC_ID"
    echo "TX Hash: $TX_HASH"
    echo "Explorer: https://sepolia.basescan.org/tx/$TX_HASH"
    echo "=========================================="
else
    echo ""
    echo "ERROR: Could not extract HTLC details from output"
    echo "Full output:"
    cat /tmp/htlc_output.txt
    exit 1
fi
