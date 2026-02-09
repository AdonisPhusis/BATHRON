#!/bin/bash
# Run EVM HTLC3S debug on CoreSDK

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"

# Read hashlocks from local state
STATE_DIR="/tmp/flowswap_e2e_state"
H_user=$(cat "$STATE_DIR/H_user" 2>/dev/null)
H_lp1=$(cat "$STATE_DIR/H_lp1" 2>/dev/null)
H_lp2=$(cat "$STATE_DIR/H_lp2" 2>/dev/null)

if [[ -z "$H_user" ]] || [[ -z "$H_lp1" ]] || [[ -z "$H_lp2" ]]; then
    echo "ERROR: Missing hashlocks in $STATE_DIR"
    exit 1
fi

echo "=== EVM HTLC3S Debug on CoreSDK ==="
echo "H_user: $H_user"
echo "H_lp1:  $H_lp1"
echo "H_lp2:  $H_lp2"
echo

# Run debug on CoreSDK
ssh $SSH_OPTS "ubuntu@$CORESDK_IP" bash << 'REMOTE_EOF'
cd ~/pna-lp
source venv/bin/activate

python3 << 'PYTHON_EOF'
import json
import os
import time
from web3 import Web3

# Configuration
RPC_URL = "https://sepolia.base.org"
CHAIN_ID = 84532
HTLC3S_ADDRESS = "0x667E9bDC368F0aC2abff69F5963714e3656d2d9D"
USDC_ADDRESS = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
CHARLIE_EVM = "0x9f11B03618DeE8f12E7F90e753093B613CeD51D2"

# Hashlocks from environment
H_user = os.environ.get('H_USER', 'HASHLOCK_USER_PLACEHOLDER')
H_lp1 = os.environ.get('H_LP1', 'HASHLOCK_LP1_PLACEHOLDER')
H_lp2 = os.environ.get('H_LP2', 'HASHLOCK_LP2_PLACEHOLDER')

# Connect
w3 = Web3(Web3.HTTPProvider(RPC_URL))
print(f"Connected: {w3.is_connected()}")
print(f"Block: {w3.eth.block_number}")
block_ts = w3.eth.get_block('latest')['timestamp']
print(f"Block timestamp: {block_ts}")
print(f"Local time: {int(time.time())}")
print()

# Load Bob's key
key_file = os.path.expanduser("~/.BathronKey/evm.json")
with open(key_file) as f:
    keys = json.load(f)
private_key = keys.get("bob_private_key") or keys.get("private_key")
if not private_key:
    print("ERROR: No private key found")
    exit(1)

account = w3.eth.account.from_key(private_key)
bob_addr = account.address
print(f"Bob address: {bob_addr}")

# Check Bob's USDC balance
usdc_abi = [
    {"name": "balanceOf", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "account", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
    {"name": "allowance", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
]

usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_ADDRESS), abi=usdc_abi)
balance = usdc.functions.balanceOf(bob_addr).call()
allowance = usdc.functions.allowance(bob_addr, Web3.to_checksum_address(HTLC3S_ADDRESS)).call()

print(f"USDC balance: {balance} ({balance/1e6} USDC)")
print(f"USDC allowance: {allowance} ({allowance/1e6} USDC)")
print()

# Prepare create parameters
amount = 5_000_000  # 5 USDC
timelock = int(time.time()) + 3600  # 1 hour from now

print(f"H_user: {H_user}")
print(f"H_lp1:  {H_lp1}")
print(f"H_lp2:  {H_lp2}")
print(f"Amount: {amount} (5 USDC)")
print(f"Timelock: {timelock}")
print(f"Recipient: {CHARLIE_EVM}")
print()

# Normalize hashlocks to bytes32
def to_bytes32(hex_str):
    if hex_str.startswith("0x"):
        hex_str = hex_str[2:]
    return bytes.fromhex(hex_str)

h_user_bytes = to_bytes32(H_user)
h_lp1_bytes = to_bytes32(H_lp1)
h_lp2_bytes = to_bytes32(H_lp2)

print(f"h_user_bytes len: {len(h_user_bytes)}")
print(f"h_lp1_bytes len:  {len(h_lp1_bytes)}")
print(f"h_lp2_bytes len:  {len(h_lp2_bytes)}")
print()

# Contract ABI
htlc_abi = [
    {"name": "create", "type": "function",
     "inputs": [
         {"name": "recipient", "type": "address"},
         {"name": "token", "type": "address"},
         {"name": "amount", "type": "uint256"},
         {"name": "H_user", "type": "bytes32"},
         {"name": "H_lp1", "type": "bytes32"},
         {"name": "H_lp2", "type": "bytes32"},
         {"name": "timelock", "type": "uint256"}
     ],
     "outputs": [{"name": "htlcId", "type": "bytes32"}]}
]

htlc = w3.eth.contract(address=Web3.to_checksum_address(HTLC3S_ADDRESS), abi=htlc_abi)

# Build the function call
fn = htlc.functions.create(
    Web3.to_checksum_address(CHARLIE_EVM),
    Web3.to_checksum_address(USDC_ADDRESS),
    amount,
    h_user_bytes,
    h_lp1_bytes,
    h_lp2_bytes,
    timelock
)

# Try to estimate gas (this will give detailed revert reason)
print("Attempting gas estimation...")
try:
    gas = fn.estimate_gas({'from': bob_addr})
    print(f"✓ Gas estimate: {gas}")
except Exception as e:
    print(f"✗ Gas estimation failed: {e}")
    print(f"  Error type: {type(e).__name__}")
    if hasattr(e, 'args'):
        for i, arg in enumerate(e.args):
            print(f"  arg[{i}]: {arg}")

    # Check contract exists
    code = w3.eth.get_code(Web3.to_checksum_address(HTLC3S_ADDRESS))
    print(f"\nContract code exists: {len(code) > 0} ({len(code)} bytes)")

    # Check basic validations manually
    print("\nManual validation checks:")
    print(f"  recipient != 0: {CHARLIE_EVM != '0x' + '0'*40}")
    print(f"  token != 0: {USDC_ADDRESS != '0x' + '0'*40}")
    print(f"  amount > 0: {amount > 0}")
    print(f"  timelock > block.timestamp: {timelock} > {block_ts} = {timelock > block_ts}")
    print(f"  H_user != 0: {h_user_bytes != bytes(32)}")
    print(f"  H_lp1 != 0: {h_lp1_bytes != bytes(32)}")
    print(f"  H_lp2 != 0: {h_lp2_bytes != bytes(32)}")
    print(f"  balance >= amount: {balance} >= {amount} = {balance >= amount}")
    print(f"  allowance >= amount: {allowance} >= {amount} = {allowance >= amount}")
    exit(1)

# If gas estimation succeeds, try static call
print("\nTrying static call...")
try:
    result = fn.call({'from': bob_addr})
    print(f"✓ Static call succeeded, htlcId: 0x{result.hex()}")
except Exception as e:
    print(f"✗ Static call failed: {e}")
    exit(1)

# If static call succeeds, build and send transaction
print("\nBuilding transaction...")
nonce = w3.eth.get_transaction_count(bob_addr, 'pending')
gas_price = int(w3.eth.gas_price * 1.2)

tx = fn.build_transaction({
    'from': bob_addr,
    'nonce': nonce,
    'gas': int(gas * 1.2),
    'gasPrice': gas_price,
    'chainId': CHAIN_ID
})

print(f"TX built: nonce={nonce}, gas={tx['gas']}, gasPrice={gas_price}")

print("\nSigning and sending...")
signed = w3.eth.account.sign_transaction(tx, private_key)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
print(f"TX hash: {tx_hash.hex()}")

print("\nWaiting for receipt...")
receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

print(f"\nReceipt status: {receipt['status']} ({'SUCCESS' if receipt['status'] == 1 else 'FAILED'})")
print(f"Gas used: {receipt['gasUsed']}")

if receipt['status'] == 1:
    # Extract htlcId from logs
    for log in receipt['logs']:
        if log['address'].lower() == HTLC3S_ADDRESS.lower():
            if len(log['topics']) >= 2:
                htlc_id = log['topics'][1].hex()
                print(f"\n✓ HTLC created! ID: 0x{htlc_id}")
                break
else:
    print("\n✗ Transaction failed!")
PYTHON_EOF
REMOTE_EOF
