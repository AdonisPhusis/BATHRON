#!/bin/bash
# ATOMICITY CLAIM - Extract secrets from BTC witness, claim EVM
#
# USAGE: ./atomicity_claim_from_btc.sh <btc_claim_txid>
#
# SECURITY:
# - Secrets extracted ONLY from BTC witness (not from files)
# - EVM claim gated on BTC reveal observation
# - No secret printing

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <btc_claim_txid>"
    echo ""
    echo "This script:"
    echo "  1. Extracts secrets from BTC claim transaction witness"
    echo "  2. Claims EVM HTLC using ONLY those extracted secrets"
    echo "  3. Proves atomicity: secrets came from BTC, not files"
    exit 1
fi

BTC_CLAIM_TXID="$1"

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

HTLC3S_CONTRACT="0x667E9bDC368F0aC2abff69F5963714e3656d2d9D"

echo "============================================================"
echo "ATOMICITY CLAIM FROM BTC WITNESS"
echo "============================================================"
echo ""
echo "BTC Claim TXID: $BTC_CLAIM_TXID"
echo ""

# ============================================================
# STEP 1: Extract secrets from BTC witness
# ============================================================
echo "=== STEP 1: Extract secrets from BTC witness ==="

EXTRACT_RESULT=$(ssh $SSH_OPTS ubuntu@$OP3_IP "
python3 << PYEOF
import subprocess
import json

CLI = '/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet'

def run_cli(cmd):
    result = subprocess.run(f'{CLI} {cmd}', shell=True, capture_output=True, text=True)
    return result.stdout.strip()

txid = '$BTC_CLAIM_TXID'
raw_tx = run_cli(f'getrawtransaction {txid} 1')

if not raw_tx:
    print('ERROR:TX_NOT_FOUND')
    exit(1)

tx = json.loads(raw_tx)
confirmations = tx.get('confirmations', 0)
print(f'CONFIRMATIONS:{confirmations}')

# Extract witness
witness = tx['vin'][0].get('txinwitness', [])
print(f'WITNESS_ITEMS:{len(witness)}')

if len(witness) < 5:
    print('ERROR:INVALID_WITNESS')
    exit(1)

# Witness structure: [sig, s_lp2, s_lp1, s_user, TRUE, script]
s_lp2_hex = witness[1]
s_lp1_hex = witness[2]
s_user_hex = witness[3]

# Output in parseable format (NOT the actual secrets - just confirmation they exist)
print(f'S_USER_LEN:{len(s_user_hex)//2}')
print(f'S_LP1_LEN:{len(s_lp1_hex)//2}')
print(f'S_LP2_LEN:{len(s_lp2_hex)//2}')

# Store for EVM claim (in a temp file, not stdout)
import os
os.makedirs('/tmp/btc_extract', exist_ok=True)
with open('/tmp/btc_extract/secrets.json', 'w') as f:
    json.dump({
        's_user': s_user_hex,
        's_lp1': s_lp1_hex,
        's_lp2': s_lp2_hex,
        'btc_txid': txid,
        'confirmations': confirmations
    }, f)
os.chmod('/tmp/btc_extract/secrets.json', 0o600)

print('EXTRACTED:OK')
print('SOURCE:BTC_WITNESS')
PYEOF
")

echo "$EXTRACT_RESULT"

# Check extraction succeeded
if ! echo "$EXTRACT_RESULT" | grep -q "EXTRACTED:OK"; then
    echo ""
    echo "ERROR: Failed to extract secrets from BTC witness"
    exit 1
fi

CONFIRMATIONS=$(echo "$EXTRACT_RESULT" | grep "^CONFIRMATIONS:" | cut -d: -f2)
echo ""
echo "Secrets extracted from BTC witness (${CONFIRMATIONS} confirmations)"

# ============================================================
# STEP 2: Transfer secrets to OP1 and claim EVM
# ============================================================
echo ""
echo "=== STEP 2: Claim EVM HTLC with extracted secrets ==="

# Get the HTLC ID from swap state
HTLC_ID=$(ssh $SSH_OPTS ubuntu@$OP1_IP "cat /tmp/atomicity_fresh/swap_state.json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"htlc_id\"])'")

if [ -z "$HTLC_ID" ]; then
    echo "ERROR: No HTLC ID found in swap state"
    echo "Did you run atomicity_fresh_cycle.sh first?"
    exit 1
fi

echo "HTLC ID: $HTLC_ID"

# Copy extracted secrets from OP3 to OP1
ssh $SSH_OPTS ubuntu@$OP3_IP "cat /tmp/btc_extract/secrets.json" | \
    ssh $SSH_OPTS ubuntu@$OP1_IP "cat > /tmp/btc_extract_secrets.json && chmod 600 /tmp/btc_extract_secrets.json"

# Claim on EVM
CLAIM_RESULT=$(ssh $SSH_OPTS ubuntu@$OP1_IP "
cd /home/ubuntu/pna-lp
source venv/bin/activate 2>/dev/null || true

python3 << PYEOF
import json
from web3 import Web3
from eth_account import Account

# Load secrets EXTRACTED FROM BTC (not from swap state!)
with open('/tmp/btc_extract_secrets.json') as f:
    btc_data = json.load(f)

s_user = bytes.fromhex(btc_data['s_user'])
s_lp1 = bytes.fromhex(btc_data['s_lp1'])
s_lp2 = bytes.fromhex(btc_data['s_lp2'])
btc_txid = btc_data['btc_txid']

print(f'BTC_SOURCE:{btc_txid[:16]}...')
print(f'REVEAL_SOURCE:BTC_WITNESS')

# GATE CHECK: Secrets must come from BTC
if not btc_txid or len(btc_txid) != 64:
    print('ERROR:NO_BTC_REVEAL')
    exit(1)

# Connect
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

HTLC3S_ADDR = '$HTLC3S_CONTRACT'
HTLC3S_ABI = [
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
contract = w3.eth.contract(address=HTLC3S_ADDR, abi=HTLC3S_ABI)

htlc_id = bytes.fromhex('$HTLC_ID'.replace('0x', ''))

# Check HTLC exists and not claimed
htlc = contract.functions.htlcs(htlc_id).call()
print(f'HTLC_AMOUNT:{htlc[3]}')
print(f'HTLC_CLAIMED:{htlc[8]}')
print(f'HTLC_REFUNDED:{htlc[9]}')

if htlc[0] == '0x0000000000000000000000000000000000000000':
    print('ERROR:HTLC_NOT_FOUND')
    exit(1)

if htlc[8]:
    print('ERROR:ALREADY_CLAIMED')
    exit(1)

if htlc[9]:
    print('ERROR:ALREADY_REFUNDED')
    exit(1)

# Load wallet for gas (no key logging!)
with open('/home/ubuntu/.BathronKey/evm.json') as f:
    evm_data = json.load(f)
account = Account.from_key(evm_data['private_key'])

# Claim
nonce = w3.eth.get_transaction_count(account.address)
claim_tx = contract.functions.claim(
    htlc_id, s_user, s_lp1, s_lp2
).build_transaction({
    'from': account.address,
    'nonce': nonce,
    'gas': 200000,
    'gasPrice': int(w3.eth.gas_price * 1.5)
})

signed = account.sign_transaction(claim_tx)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
print(f'CLAIM_TX:{tx_hash.hex()}')

receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

if receipt['status'] == 1:
    print('CLAIM_STATUS:SUCCESS')
    print(f'EXPLORER:https://sepolia.basescan.org/tx/{tx_hash.hex()}')
else:
    print('CLAIM_STATUS:FAILED')
    exit(1)
PYEOF
")

echo "$CLAIM_RESULT"

# ============================================================
# VERIFY ATOMICITY
# ============================================================
echo ""
echo "============================================================"
if echo "$CLAIM_RESULT" | grep -q "CLAIM_STATUS:SUCCESS"; then
    echo "ATOMICITY PROVEN"
    echo "============================================================"
    echo ""
    echo "The EVM claim succeeded using secrets extracted from BTC witness."
    echo ""
    echo "Proof chain:"
    echo "  1. BTC HTLC claimed -> secrets revealed in witness"
    echo "  2. Secrets extracted from BTC transaction: $BTC_CLAIM_TXID"
    echo "  3. EVM HTLC claimed using ONLY extracted secrets"
    echo ""
    echo "The ONLY source of secrets was the BTC claim transaction."
    echo "This proves cryptographic atomicity."
else
    echo "ATOMICITY TEST FAILED"
    echo "============================================================"
    echo ""
    echo "EVM claim did not succeed. Check the error above."
fi
