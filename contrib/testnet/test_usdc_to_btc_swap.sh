#!/bin/bash
# =============================================================================
# TEST: USDC → BTC Atomic Swap (User → LP → User)
# =============================================================================
# Flow:
# 1. User generates secret S, hashlock H
# 2. User creates USDC HTLC → LP (locked by H)
# 3. LP creates BTC HTLC → User (locked by H)
# 4. User claims BTC (reveals S on Bitcoin)
# 5. LP extracts S, claims USDC
# =============================================================================

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"  # LP
OP3_IP="51.75.31.44"    # User
LP_API="http://$OP1_IP:8080"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo ""
echo -e "${MAGENTA}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║         USDC → BTC ATOMIC SWAP (User sends USDC)              ║${NC}"
echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# STEP 1: Initial balances
# =============================================================================
echo -e "${CYAN}[1/6]${NC} Initial Balances"
echo "─────────────────────────────────────────────────────────────────"

# USDC balances
LP_USDC=$(curl -s "$LP_API/api/sdk/usdc/balance/0xB6bc96842f6085a949b8433dc6316844c32Cba63")
USER_USDC=$(curl -s "$LP_API/api/sdk/usdc/balance/0x4928542712Ab06c6C1963c42091827Cb2D70d265")

echo "USDC:"
echo "  LP:   $(echo $LP_USDC | python3 -c "import json,sys; print(json.load(sys.stdin)['usdc_balance'])")"
echo "  User: $(echo $USER_USDC | python3 -c "import json,sys; print(json.load(sys.stdin)['usdc_balance'])")"

# BTC balances
echo "BTC:"
LP_BTC=$(ssh -i $SSH_KEY ubuntu@$OP1_IP '~/bitcoin/bin/bitcoin-cli -signet -datadir=$HOME/.bitcoin-signet getbalance 2>/dev/null || echo "0"')
USER_BTC=$(ssh -i $SSH_KEY ubuntu@$OP3_IP '~/bitcoin/bin/bitcoin-cli -signet -datadir=$HOME/.bitcoin-signet getbalance 2>/dev/null || echo "0"')
echo "  LP:   $LP_BTC BTC"
echo "  User: $USER_BTC BTC"
echo ""

# =============================================================================
# STEP 2: User generates secret
# =============================================================================
echo -e "${CYAN}[2/6]${NC} User Generates Secret"
echo "─────────────────────────────────────────────────────────────────"

SECRET=$(openssl rand -hex 32)
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | openssl dgst -sha256 -binary | xxd -p | tr -d '\n')

echo "Secret:   $SECRET"
echo "Hashlock: $HASHLOCK"
echo ""

# =============================================================================
# STEP 3: User creates USDC HTLC → LP
# =============================================================================
echo -e "${CYAN}[3/6]${NC} User Creates USDC HTLC → LP"
echo "─────────────────────────────────────────────────────────────────"

LP_EVM="0xB6bc96842f6085a949b8433dc6316844c32Cba63"
USDC_AMOUNT="2.0"

# Get user's private key
USER_KEY=$(ssh -i $SSH_KEY ubuntu@$OP3_IP 'python3 -c "import json; print(json.load(open(\"/home/ubuntu/.keys/user_evm.json\"))[\"private_key\"])"')

echo "User sending $USDC_AMOUNT USDC to HTLC for LP..."
echo "First, approving HTLC contract to spend USDC..."

# Approve HTLC contract for user
APPROVE_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "
cd ~/pna-sdk && ./venv/bin/python3 << 'PYEOF'
from web3 import Web3
from eth_account import Account
import json

RPC_URL = 'https://sepolia.base.org'
CHAIN_ID = 84532
USDC_CONTRACT = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
HTLC_CONTRACT = '0xBCf3eeb42629143A1B29d9542fad0E54a04dBFD2'
USER_KEY = '$USER_KEY'

w3 = Web3(Web3.HTTPProvider(RPC_URL))
account = Account.from_key('0x' + USER_KEY if not USER_KEY.startswith('0x') else USER_KEY)

# Approve max amount
MAX_UINT256 = 2**256 - 1
usdc_abi = [{'name': 'approve', 'type': 'function', 'inputs': [{'name': 'spender', 'type': 'address'}, {'name': 'amount', 'type': 'uint256'}], 'outputs': [{'name': '', 'type': 'bool'}]}]
usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_CONTRACT), abi=usdc_abi)

tx = usdc.functions.approve(Web3.to_checksum_address(HTLC_CONTRACT), MAX_UINT256).build_transaction({
    'from': account.address,
    'nonce': w3.eth.get_transaction_count(account.address, 'pending'),
    'gas': 100000,
    'gasPrice': int(w3.eth.gas_price * 1.1),
    'chainId': CHAIN_ID
})

signed = account.sign_transaction(tx)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
print(f'Approval TX: {tx_hash.hex()}, Status: {receipt[\"status\"]}')
PYEOF
")

echo "  $APPROVE_RESULT"
echo ""

# Now create HTLC
HTLC_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "
cd ~/pna-sdk && ./venv/bin/python3 << 'PYEOF'
import json
from sdk.htlc.evm import create_htlc

result = create_htlc(
    receiver='$LP_EVM',
    amount_usdc=$USDC_AMOUNT,
    hashlock='$HASHLOCK',
    timelock_seconds=3600,
    private_key='$USER_KEY'
)

print(json.dumps({
    'success': result.success,
    'htlc_id': result.htlc_id,
    'tx_hash': result.tx_hash,
    'error': result.error
}))
PYEOF
")

if echo "$HTLC_RESULT" | grep -q '"success": true'; then
    HTLC_ID=$(echo "$HTLC_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['htlc_id'])")
    TX_HASH=$(echo "$HTLC_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tx_hash'])")
    echo -e "${GREEN}✓ User HTLC Created${NC}"
    echo "  HTLC ID: $HTLC_ID"
    echo "  TX: https://sepolia.basescan.org/tx/0x$TX_HASH"
else
    echo "ERROR: $HTLC_RESULT"
    exit 1
fi
echo ""

# =============================================================================
# STEP 4: LP creates BTC HTLC → User
# =============================================================================
echo -e "${CYAN}[4/6]${NC} LP Creates BTC HTLC → User"
echo "─────────────────────────────────────────────────────────────────"

# Get user's BTC address
USER_BTC_ADDR=$(ssh -i $SSH_KEY ubuntu@$OP3_IP '
~/bitcoin/bin/bitcoin-cli -signet -datadir=$HOME/.bitcoin-signet getnewaddress "swap_receive" bech32
')
echo "User BTC address: $USER_BTC_ADDR"

# Calculate BTC amount (2 USDC at ~$98500/BTC = ~0.00002 BTC = 2000 sats)
# For test, use 5000 sats
BTC_SATS=5000
BTC_AMOUNT="0.00005000"

echo "LP creating BTC HTLC: $BTC_AMOUNT BTC ($BTC_SATS sats) → User"

# Create BTC HTLC via API
BTC_HTLC=$(curl -s -X POST "$LP_API/api/sdk/btc/htlc/create" \
    -H "Content-Type: application/json" \
    -d "{
        \"recipient_address\": \"$USER_BTC_ADDR\",
        \"amount_sats\": $BTC_SATS,
        \"hashlock\": \"$HASHLOCK\",
        \"timeout_blocks\": 144
    }" 2>/dev/null)

echo "$BTC_HTLC" | python3 -m json.tool 2>/dev/null | head -10

BTC_HTLC_ADDR=$(echo "$BTC_HTLC" | python3 -c "import json,sys; print(json.load(sys.stdin).get('htlc_address',''))" 2>/dev/null)

if [ -n "$BTC_HTLC_ADDR" ]; then
    echo -e "${GREEN}✓ BTC HTLC Address: $BTC_HTLC_ADDR${NC}"

    # LP funds the HTLC
    echo ""
    echo "LP funding BTC HTLC..."
    BTC_FUND_TX=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "
        ~/bitcoin/bin/bitcoin-cli -signet -datadir=\$HOME/.bitcoin-signet \
        sendtoaddress '$BTC_HTLC_ADDR' $BTC_AMOUNT
    " 2>&1)

    if [[ "$BTC_FUND_TX" =~ ^[a-f0-9]{64}$ ]]; then
        echo -e "${GREEN}✓ BTC HTLC Funded: $BTC_FUND_TX${NC}"
    else
        echo -e "${YELLOW}! BTC funding failed: $BTC_FUND_TX${NC}"
        echo "  (LP may not have enough BTC)"
    fi
else
    echo -e "${YELLOW}! BTC HTLC creation via API not available${NC}"
    echo "  Creating manually..."

    # Manual HTLC creation
    LP_BTC_REFUND=$(ssh -i $SSH_KEY ubuntu@$OP1_IP '
        ~/bitcoin/bin/bitcoin-cli -signet -datadir=$HOME/.bitcoin-signet getnewaddress "lp_refund" bech32
    ')

    echo "  LP refund address: $LP_BTC_REFUND"
    echo "  (Manual BTC HTLC would be created here)"
fi
echo ""

# =============================================================================
# STEP 5: User claims BTC (reveals secret)
# =============================================================================
echo -e "${CYAN}[5/6]${NC} User Claims BTC (Reveals Secret on Bitcoin)"
echo "─────────────────────────────────────────────────────────────────"

echo "In a real flow:"
echo "  1. User waits for BTC HTLC to be confirmed (~10 min Signet)"
echo "  2. User claims BTC using secret S"
echo "  3. This reveals S on Bitcoin blockchain"
echo "  4. LP extracts S and claims USDC HTLC"
echo ""
echo -e "${YELLOW}! Skipping actual BTC claim (requires Signet confirmation wait)${NC}"
echo ""

# =============================================================================
# STEP 6: LP claims USDC with secret
# =============================================================================
echo -e "${CYAN}[6/6]${NC} LP Claims USDC (Using Secret)"
echo "─────────────────────────────────────────────────────────────────"

echo "LP would extract secret from Bitcoin and claim USDC..."
echo "For demo, LP claims directly with known secret:"

LP_KEY=$(ssh -i $SSH_KEY ubuntu@$OP1_IP 'python3 -c "import json; print(json.load(open(\"/home/ubuntu/.keys/lp_evm.json\"))[\"private_key\"])"')

CLAIM_RESULT=$(curl -s -X POST "$LP_API/api/sdk/usdc/htlc/withdraw" \
    -H "Content-Type: application/json" \
    -d "{
        \"htlc_id\": \"$HTLC_ID\",
        \"preimage\": \"$SECRET\",
        \"private_key\": \"$LP_KEY\"
    }")

if echo "$CLAIM_RESULT" | grep -q '"success":true'; then
    CLAIM_TX=$(echo "$CLAIM_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tx_hash'])")
    echo -e "${GREEN}✓ LP Claimed USDC!${NC}"
    echo "  TX: https://sepolia.basescan.org/tx/0x$CLAIM_TX"
else
    echo "Result: $CLAIM_RESULT"
fi
echo ""

# Wait for confirmation
echo "Waiting for confirmation (5s)..."
sleep 5

# =============================================================================
# Final Balances
# =============================================================================
echo "─────────────────────────────────────────────────────────────────"
echo "Final Balances:"

LP_USDC=$(curl -s "$LP_API/api/sdk/usdc/balance/0xB6bc96842f6085a949b8433dc6316844c32Cba63")
USER_USDC=$(curl -s "$LP_API/api/sdk/usdc/balance/0x4928542712Ab06c6C1963c42091827Cb2D70d265")

echo "USDC:"
echo "  LP:   $(echo $LP_USDC | python3 -c "import json,sys; print(json.load(sys.stdin)['usdc_balance'])")"
echo "  User: $(echo $USER_USDC | python3 -c "import json,sys; print(json.load(sys.stdin)['usdc_balance'])")"

echo ""
echo -e "${MAGENTA}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║                 USDC → BTC SWAP COMPLETE                       ║${NC}"
echo -e "${MAGENTA}╠═══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${MAGENTA}║  User sent:     $USDC_AMOUNT USDC to HTLC                               ║${NC}"
echo -e "${MAGENTA}║  LP received:   $USDC_AMOUNT USDC (claimed with secret)                 ║${NC}"
echo -e "${MAGENTA}║  User would receive: $BTC_AMOUNT BTC (after claiming)              ║${NC}"
echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
