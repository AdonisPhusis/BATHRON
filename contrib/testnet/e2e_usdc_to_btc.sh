#!/bin/bash
# =============================================================================
# e2e_usdc_to_btc.sh - E2E test: USDC → BTC reverse FlowSwap 3S
# =============================================================================
# Run from dev machine. Orchestrates:
#   1. Init swap on LP (gets hashlocks, BTC HTLC info)
#   2. Create USDC HTLC3S on Base Sepolia (from OP3/charlie)
#   3. Notify LP of USDC funded
#   4. Auto-presign → LP completes settlement
# =============================================================================

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP3_IP="51.75.31.44"
LP_URL="http://57.131.33.152:8080"

AMOUNT_USDC="${1:-2}"
USER_BTC_ADDR="${2:-tb1qkd2kyur0yqxpp6hvtwheukwpfjt2h5atapyhe7}"

echo "============================================================"
echo "  E2E Test: USDC → BTC (FlowSwap 3S Reverse)"
echo "============================================================"
echo "Amount: ${AMOUNT_USDC} USDC"
echo "BTC destination: ${USER_BTC_ADDR}"
echo ""

# ─── Step 0: Generate user secret ─────────────────────────────
echo "[0/5] Generating user secret..."
S_USER=$(openssl rand -hex 32)
H_USER=$(echo -n "$S_USER" | xxd -r -p | sha256sum | cut -d' ' -f1)
echo "  S_user: ${S_USER:0:16}..."
echo "  H_user: ${H_USER:0:16}..."
echo ""

# ─── Step 1: Init swap on LP ──────────────────────────────────
echo "[1/5] Calling LP /api/flowswap/init (USDC→BTC)..."
INIT_RESP=$(curl -sf -X POST "${LP_URL}/api/flowswap/init" \
    -H "Content-Type: application/json" \
    -d "{
        \"from_asset\":\"USDC\",
        \"to_asset\":\"BTC\",
        \"amount\":${AMOUNT_USDC},
        \"H_user\":\"${H_USER}\",
        \"user_btc_claim_address\":\"${USER_BTC_ADDR}\"
    }")

if [ $? -ne 0 ] || [ -z "$INIT_RESP" ]; then
    echo "ERROR: Init failed"
    exit 1
fi

SWAP_ID=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['swap_id'])")
STATE=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])")
HTLC3S_CONTRACT=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usdc_deposit']['contract'])")
USDC_TOKEN=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usdc_deposit']['token'])")
RECEIVER=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usdc_deposit']['recipient'])")
TIMELOCK_SEC=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['usdc_deposit']['timelock_seconds'])")
H_LP1=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['hashlocks']['H_lp1'])")
H_LP2=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['hashlocks']['H_lp2'])")
BTC_FUND_TXID=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['btc_output']['fund_txid'])")
BTC_AMOUNT=$(echo "$INIT_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['btc_output']['amount_btc'])")

echo "  Swap ID: $SWAP_ID"
echo "  State: $STATE"
echo "  BTC funded: $BTC_FUND_TXID (${BTC_AMOUNT} BTC)"
echo "  HTLC3S contract: $HTLC3S_CONTRACT"
echo "  USDC token: $USDC_TOKEN"
echo "  Receiver (LP): $RECEIVER"
echo "  Timelock: ${TIMELOCK_SEC}s"
echo "  H_lp1: ${H_LP1:0:16}..."
echo "  H_lp2: ${H_LP2:0:16}..."
echo ""

if [ "$STATE" != "awaiting_usdc" ]; then
    echo "ERROR: Expected state 'awaiting_usdc', got '$STATE'"
    exit 1
fi

# ─── Step 2: Create USDC HTLC3S on Base Sepolia (from OP3) ───
echo "[2/5] Creating USDC HTLC3S on Base Sepolia (OP3)..."

# Generate Python script and send to OP3
cat << PYEOF > /tmp/create_usdc_htlc3s_reverse.py
#!/usr/bin/env python3
"""Create USDC HTLC3S on Base Sepolia for reverse FlowSwap."""
import json, os, sys, time

RPC_URL = "https://sepolia.base.org"
CHAIN_ID = 84532

# Parameters from environment
HTLC3S_CONTRACT = "${HTLC3S_CONTRACT}"
USDC_TOKEN = "${USDC_TOKEN}"
RECEIVER = "${RECEIVER}"
AMOUNT_USDC = ${AMOUNT_USDC}
TIMELOCK_SEC = ${TIMELOCK_SEC}
H_USER = "${H_USER}"
H_LP1 = "${H_LP1}"
H_LP2 = "${H_LP2}"

# Load charlie EVM key
for kf in [os.path.expanduser("~/.BathronKey/evm.json"),
           os.path.expanduser("~/.keys/user_evm.json")]:
    if os.path.exists(kf):
        with open(kf) as f:
            keys = json.load(f)
        private_key = keys.get("private_key") or keys.get("privkey")
        if private_key:
            break
else:
    print("ERROR: No EVM key found"); sys.exit(1)

from web3 import Web3
from eth_account import Account

w3 = Web3(Web3.HTTPProvider(RPC_URL))
if not w3.is_connected():
    print("ERROR: Cannot connect to Base Sepolia"); sys.exit(1)

if not private_key.startswith("0x"):
    private_key = "0x" + private_key
account = Account.from_key(private_key)
print(f"Account: {account.address}")

# HTLC3S ABI (create + HTLCCreated event)
HTLC3S_ABI = [
    {
        "name": "create", "type": "function",
        "inputs": [
            {"name": "recipient", "type": "address"},
            {"name": "token", "type": "address"},
            {"name": "amount", "type": "uint256"},
            {"name": "H_user", "type": "bytes32"},
            {"name": "H_lp1", "type": "bytes32"},
            {"name": "H_lp2", "type": "bytes32"},
            {"name": "timelock", "type": "uint256"}
        ],
        "outputs": [{"name": "htlcId", "type": "bytes32"}]
    }
]

ERC20_ABI = [
    {"name": "approve", "type": "function",
     "inputs": [{"name": "spender", "type": "address"}, {"name": "amount", "type": "uint256"}],
     "outputs": [{"name": "", "type": "bool"}], "stateMutability": "nonpayable"},
    {"name": "allowance", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]},
    {"name": "balanceOf", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "account", "type": "address"}],
     "outputs": [{"name": "", "type": "uint256"}]}
]

usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_TOKEN), abi=ERC20_ABI)
htlc3s = w3.eth.contract(address=Web3.to_checksum_address(HTLC3S_CONTRACT), abi=HTLC3S_ABI)

amount_wei = int(AMOUNT_USDC * 1e6)

# Check USDC balance
bal = usdc.functions.balanceOf(account.address).call()
print(f"USDC balance: {bal/1e6:.2f} USDC")
if bal < amount_wei:
    print(f"ERROR: Need {amount_wei} wei, have {bal}"); sys.exit(1)

# Approve if needed
allowance = usdc.functions.allowance(account.address, Web3.to_checksum_address(HTLC3S_CONTRACT)).call()
if allowance < amount_wei:
    print("Approving USDC...")
    nonce = w3.eth.get_transaction_count(account.address, 'pending')
    tx = usdc.functions.approve(
        Web3.to_checksum_address(HTLC3S_CONTRACT), 2**256-1
    ).build_transaction({
        'from': account.address, 'nonce': nonce,
        'gas': 100000, 'gasPrice': int(w3.eth.gas_price * 1.2), 'chainId': CHAIN_ID
    })
    signed = account.sign_transaction(tx)
    h = w3.eth.send_raw_transaction(signed.raw_transaction)
    r = w3.eth.wait_for_transaction_receipt(h, timeout=120)
    if r['status'] != 1:
        print("ERROR: Approve failed"); sys.exit(1)
    print(f"  Approved: {h.hex()}")

# Create HTLC3S
timelock = int(time.time()) + TIMELOCK_SEC
h_user_b = bytes.fromhex(H_USER)
h_lp1_b = bytes.fromhex(H_LP1)
h_lp2_b = bytes.fromhex(H_LP2)

print(f"Creating HTLC3S: {AMOUNT_USDC} USDC, timelock={timelock}")

# Simulate
try:
    sim_id = htlc3s.functions.create(
        Web3.to_checksum_address(RECEIVER), Web3.to_checksum_address(USDC_TOKEN),
        amount_wei, h_user_b, h_lp1_b, h_lp2_b, timelock
    ).call({'from': account.address})
    print(f"  Simulation OK, expected ID: 0x{sim_id.hex()}")
except Exception as e:
    print(f"ERROR: Simulation failed: {e}"); sys.exit(1)

# Send
nonce = w3.eth.get_transaction_count(account.address, 'pending')
tx = htlc3s.functions.create(
    Web3.to_checksum_address(RECEIVER), Web3.to_checksum_address(USDC_TOKEN),
    amount_wei, h_user_b, h_lp1_b, h_lp2_b, timelock
).build_transaction({
    'from': account.address, 'nonce': nonce,
    'gas': 300000, 'gasPrice': int(w3.eth.gas_price * 1.2), 'chainId': CHAIN_ID
})
signed = account.sign_transaction(tx)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
print(f"  TX: {tx_hash.hex()}")

receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
if receipt['status'] != 1:
    print("ERROR: HTLC create failed"); sys.exit(1)

# Extract HTLC ID from topics[1]
htlc_id = None
contract_lower = HTLC3S_CONTRACT.lower()
for log_entry in receipt['logs']:
    addr = log_entry['address'].lower()
    if addr == contract_lower and len(log_entry['topics']) >= 2:
        t1 = log_entry['topics'][1]
        htlc_id = "0x" + (t1.hex() if hasattr(t1, 'hex') else t1.replace('0x',''))
        break

if not htlc_id:
    htlc_id = f"0x{sim_id.hex()}"
    print("  WARNING: Using simulated ID")

print(f"HTLC_ID={htlc_id}")
print(f"TX_HASH={tx_hash.hex()}")
print(f"Explorer: https://sepolia.basescan.org/tx/{tx_hash.hex()}")
PYEOF

# Copy and execute on OP3
echo "  Copying script to OP3..."
scp $SSH_OPTS /tmp/create_usdc_htlc3s_reverse.py ubuntu@${OP3_IP}:/tmp/ 2>&1
if [ $? -ne 0 ]; then
    echo "ERROR: SCP to OP3 failed. Check SSH key and connectivity."
    exit 1
fi
echo "  Running on OP3..."
HTLC_OUTPUT=$(ssh $SSH_OPTS ubuntu@${OP3_IP} "python3 /tmp/create_usdc_htlc3s_reverse.py" 2>&1)
SCP_EXIT=$?
echo "$HTLC_OUTPUT"
if [ $SCP_EXIT -ne 0 ]; then
    echo "ERROR: Script execution on OP3 failed (exit=$SCP_EXIT)"
    exit 1
fi

HTLC_ID=$(echo "$HTLC_OUTPUT" | grep "^HTLC_ID=" | cut -d= -f2)
TX_HASH=$(echo "$HTLC_OUTPUT" | grep "^TX_HASH=" | cut -d= -f2)

if [ -z "$HTLC_ID" ]; then
    echo "ERROR: Failed to create USDC HTLC"
    exit 1
fi

echo ""
echo "  USDC HTLC3S created: $HTLC_ID"
echo ""

# ─── Step 3: Notify LP that USDC is funded ────────────────────
echo "[3/5] Notifying LP: USDC funded..."
FUNDED_RESP=$(curl -sf -X POST "${LP_URL}/api/flowswap/${SWAP_ID}/usdc-funded" \
    -H "Content-Type: application/json" \
    -d "{\"htlc_id\":\"${HTLC_ID}\"}")

if [ $? -ne 0 ]; then
    echo "ERROR: usdc-funded notification failed"
    echo "$FUNDED_RESP"
    exit 1
fi

echo "  Response: $FUNDED_RESP"
echo ""

# ─── Step 4: Auto-presign (send S_user to LP) ─────────────────
echo "[4/5] Sending S_user to LP (presign)..."
sleep 2

PRESIGN_RESP=$(curl -sf -X POST "${LP_URL}/api/flowswap/${SWAP_ID}/presign" \
    -H "Content-Type: application/json" \
    -d "{\"S_user\":\"${S_USER}\"}")

if [ $? -ne 0 ]; then
    echo "ERROR: Presign failed"
    echo "$PRESIGN_RESP"
    exit 1
fi

echo "  Response: $PRESIGN_RESP"
echo ""

# ─── Step 5: Check final state ────────────────────────────────
echo "[5/5] Checking swap status..."
sleep 3

# Poll for completion (claims happen in background thread)
echo "  Polling for completion..."
for i in $(seq 1 36); do
    STATUS_RESP=$(curl -sf "${LP_URL}/api/flowswap/${SWAP_ID}" 2>/dev/null || echo '{}')
    FINAL_STATE=$(echo "$STATUS_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','?'))" 2>/dev/null)
    if [ "$FINAL_STATE" = "completed" ]; then
        break
    fi
    echo "  State: $FINAL_STATE (attempt $i/36, waiting 10s...)"
    sleep 10
done
echo "$STATUS_RESP" | python3 -m json.tool 2>/dev/null || echo "$STATUS_RESP"

echo ""
echo "============================================================"
if [ "$FINAL_STATE" = "completed" ]; then
    echo "  SUCCESS: USDC → BTC swap completed!"
    echo "  $AMOUNT_USDC USDC → $BTC_AMOUNT BTC"
    echo "  BTC sent to: $USER_BTC_ADDR"
else
    echo "  State: $FINAL_STATE (may still be processing)"
fi
echo "  Swap ID: $SWAP_ID"
echo "  USDC HTLC: $HTLC_ID"
echo "  BTC HTLC fund: $BTC_FUND_TXID"
echo "============================================================"
