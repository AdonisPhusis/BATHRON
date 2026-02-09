#!/bin/bash
# FRESH ATOMICITY CYCLE - Event-driven, no secret leaks
#
# SECURITY RULES:
# - NEVER print preimages (S_user, S_lp1, S_lp2)
# - NEVER print private keys (even partial)
# - Log only: H_*, htlcId, txid, addresses
# - Secrets stay in RAM or encrypted files only

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP1_IP="57.131.33.152"  # LP
OP3_IP="51.75.31.44"    # User

HTLC3S_CONTRACT="0x667E9bDC368F0aC2abff69F5963714e3656d2d9D"
USDC_CONTRACT="0x036CbD53842c5426634e7929541eC2318f3dCF7e"
CHARLIE_EVM="0x9F11b0391ba0C9bbfeB52C2d68A3e76ad5481d7d"

echo "============================================================"
echo "FRESH ATOMICITY CYCLE - Event-Driven"
echo "============================================================"
echo ""
echo "Contract: $HTLC3S_CONTRACT"
echo "Recipient: $CHARLIE_EVM"
echo ""

# ============================================================
# STEP 1: Generate secrets and create EVM HTLC
# ============================================================
echo "=== STEP 1: Create EVM HTLC (event-driven htlcId) ==="

HTLC_RESULT=$(ssh $SSH_OPTS ubuntu@$OP1_IP "
cd /home/ubuntu/pna-lp
source venv/bin/activate 2>/dev/null || true

python3 << 'PYEOF'
import os
import json
import secrets
import hashlib
from web3 import Web3
from eth_account import Account

# Connect with retry
rpcs = ['https://base-sepolia-rpc.publicnode.com', 'https://sepolia.base.org']
w3 = None
for rpc in rpcs:
    try:
        w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={'timeout': 30}))
        if w3.is_connected():
            break
    except:
        continue

if not w3 or not w3.is_connected():
    print('ERROR:RPC_FAILED')
    exit(1)

# Generate secrets (32 bytes each) - NEVER printed
s_user = secrets.token_bytes(32)
s_lp1 = secrets.token_bytes(32)
s_lp2 = secrets.token_bytes(32)

# Compute hashes (safe to log)
h_user = hashlib.sha256(s_user).digest()
h_lp1 = hashlib.sha256(s_lp1).digest()
h_lp2 = hashlib.sha256(s_lp2).digest()

print(f'H_USER:{h_user.hex()}')
print(f'H_LP1:{h_lp1.hex()}')
print(f'H_LP2:{h_lp2.hex()}')

# Contract setup
HTLC3S_ADDR = '$HTLC3S_CONTRACT'
USDC_ADDR = '$USDC_CONTRACT'

HTLC3S_ABI = [
    {
        'inputs': [
            {'name': '_recipient', 'type': 'address'},
            {'name': '_token', 'type': 'address'},
            {'name': '_amount', 'type': 'uint256'},
            {'name': '_h_user', 'type': 'bytes32'},
            {'name': '_h_lp1', 'type': 'bytes32'},
            {'name': '_h_lp2', 'type': 'bytes32'},
            {'name': '_timelock', 'type': 'uint256'}
        ],
        'name': 'create',
        'outputs': [{'name': '', 'type': 'bytes32'}],
        'stateMutability': 'nonpayable',
        'type': 'function'
    },
    {
        'anonymous': False,
        'inputs': [
            {'indexed': True, 'name': 'htlcId', 'type': 'bytes32'},
            {'indexed': True, 'name': 'sender', 'type': 'address'},
            {'indexed': True, 'name': 'recipient', 'type': 'address'},
            {'indexed': False, 'name': 'token', 'type': 'address'},
            {'indexed': False, 'name': 'amount', 'type': 'uint256'},
            {'indexed': False, 'name': 'H_user', 'type': 'bytes32'},
            {'indexed': False, 'name': 'H_lp1', 'type': 'bytes32'},
            {'indexed': False, 'name': 'H_lp2', 'type': 'bytes32'},
            {'indexed': False, 'name': 'timelock', 'type': 'uint256'}
        ],
        'name': 'HTLCCreated',
        'type': 'event'
    }
]

ERC20_ABI = [
    {'inputs': [{'name': 'spender', 'type': 'address'}, {'name': 'amount', 'type': 'uint256'}],
     'name': 'approve', 'outputs': [{'name': '', 'type': 'bool'}], 'stateMutability': 'nonpayable', 'type': 'function'},
    {'inputs': [{'name': 'account', 'type': 'address'}],
     'name': 'balanceOf', 'outputs': [{'name': '', 'type': 'uint256'}], 'stateMutability': 'view', 'type': 'function'}
]

htlc3s = w3.eth.contract(address=HTLC3S_ADDR, abi=HTLC3S_ABI)
usdc = w3.eth.contract(address=USDC_ADDR, abi=ERC20_ABI)

# Load LP wallet (no key logging!)
with open('/home/ubuntu/.BathronKey/evm.json') as f:
    evm_data = json.load(f)
lp_account = Account.from_key(evm_data['private_key'])
print(f'LP_ADDR:{lp_account.address}')

# Check balance
balance = usdc.functions.balanceOf(lp_account.address).call()
print(f'USDC_BALANCE:{balance}')

if balance < 1_000_000:
    print('ERROR:INSUFFICIENT_USDC')
    exit(1)

# HTLC params
recipient = '$CHARLIE_EVM'
amount = 1_000_000  # 1 USDC
timelock = int(w3.eth.get_block('latest')['timestamp']) + 3600

# Approve
nonce = w3.eth.get_transaction_count(lp_account.address)
approve_tx = usdc.functions.approve(HTLC3S_ADDR, amount).build_transaction({
    'from': lp_account.address, 'nonce': nonce, 'gas': 100000,
    'gasPrice': int(w3.eth.gas_price * 1.5)
})
signed = lp_account.sign_transaction(approve_tx)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
print(f'APPROVE_TX:{tx_hash.hex()}')

# Create HTLC
nonce = w3.eth.get_transaction_count(lp_account.address)
create_tx = htlc3s.functions.create(
    recipient, USDC_ADDR, amount, h_user, h_lp1, h_lp2, timelock
).build_transaction({
    'from': lp_account.address, 'nonce': nonce, 'gas': 300000,
    'gasPrice': int(w3.eth.gas_price * 1.5)
})
signed = lp_account.sign_transaction(create_tx)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

if receipt['status'] != 1:
    print('ERROR:HTLC_CREATE_FAILED')
    exit(1)

print(f'CREATE_TX:{tx_hash.hex()}')

# Extract htlcId from HTLCCreated event
htlc_id = None
for log in receipt['logs']:
    if log['address'].lower() == HTLC3S_ADDR.lower():
        # First topic is event signature, second is indexed htlcId
        if len(log['topics']) >= 2:
            htlc_id = log['topics'][1].hex()
            break

if not htlc_id:
    print('ERROR:NO_EVENT')
    exit(1)

print(f'HTLC_ID:{htlc_id}')
print(f'TIMELOCK:{timelock}')

# Save secrets securely (encrypted or protected file)
import base64
secret_data = {
    's_user': base64.b64encode(s_user).decode(),
    's_lp1': base64.b64encode(s_lp1).decode(),
    's_lp2': base64.b64encode(s_lp2).decode(),
    'htlc_id': htlc_id,
    'h_user': h_user.hex(),
    'h_lp1': h_lp1.hex(),
    'h_lp2': h_lp2.hex()
}
os.makedirs('/tmp/atomicity_fresh', exist_ok=True)
with open('/tmp/atomicity_fresh/swap_state.json', 'w') as f:
    json.dump(secret_data, f)
os.chmod('/tmp/atomicity_fresh/swap_state.json', 0o600)

print('SECRETS_SAVED:/tmp/atomicity_fresh/swap_state.json')
print('SUCCESS')
PYEOF
")

echo "$HTLC_RESULT" | grep -E "^(H_|LP_ADDR|USDC_|APPROVE_TX|CREATE_TX|HTLC_ID|TIMELOCK|SUCCESS|ERROR)" || true

# Parse results
HTLC_ID=$(echo "$HTLC_RESULT" | grep "^HTLC_ID:" | cut -d: -f2)
H_USER=$(echo "$HTLC_RESULT" | grep "^H_USER:" | cut -d: -f2)
H_LP1=$(echo "$HTLC_RESULT" | grep "^H_LP1:" | cut -d: -f2)
H_LP2=$(echo "$HTLC_RESULT" | grep "^H_LP2:" | cut -d: -f2)

if [ -z "$HTLC_ID" ]; then
    echo ""
    echo "ERROR: Failed to create EVM HTLC"
    exit 1
fi

echo ""
echo "EVM HTLC Created:"
echo "  HTLC ID: $HTLC_ID"
echo "  H_user:  ${H_USER:0:16}..."
echo "  H_lp1:   ${H_LP1:0:16}..."
echo "  H_lp2:   ${H_LP2:0:16}..."

# ============================================================
# STEP 2: Output BTC HTLC script requirements
# ============================================================
echo ""
echo "=== STEP 2: BTC HTLC Requirements ==="
echo ""
echo "To complete the cycle, create a BTC HTLC with:"
echo "  H_user (RIPEMD160): $(echo -n "$H_USER" | xxd -r -p | openssl dgst -ripemd160 -binary | xxd -p)"
echo "  H_lp1 (RIPEMD160):  $(echo -n "$H_LP1" | xxd -r -p | openssl dgst -ripemd160 -binary | xxd -p)"
echo "  H_lp2 (RIPEMD160):  $(echo -n "$H_LP2" | xxd -r -p | openssl dgst -ripemd160 -binary | xxd -p)"
echo ""
echo "NOTE: BTC uses HASH160 (RIPEMD160(SHA256(x))) for HTLCs"
echo "      EVM uses SHA256 directly"

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "============================================================"
echo "FRESH CYCLE STATUS"
echo "============================================================"
echo ""
echo "[OK] EVM HTLC created with event-driven ID"
echo "[OK] Secrets saved securely (not logged)"
echo ""
echo "NEXT STEPS:"
echo "  1. Create BTC HTLC with matching hashes"
echo "  2. Fund BTC HTLC"
echo "  3. LP1 claims BTC (reveals secrets in witness)"
echo "  4. Extract secrets from BTC witness"
echo "  5. Claim EVM using: atomicity_claim_from_btc.sh <btc_txid>"
echo ""
echo "HTLC ID for claim: $HTLC_ID"
echo "Swap state: OP1:/tmp/atomicity_fresh/swap_state.json"
echo ""
echo "============================================================"
