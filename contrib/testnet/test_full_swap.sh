#!/bin/bash
# =============================================================================
# TEST: Full Atomic Swap with Auto LP Response
# =============================================================================
# This tests the production-like flow:
# 1. User generates secret/hashlock
# 2. User initiates swap via API
# 3. User creates HTLC
# 4. LP auto-detects and creates counter-HTLC
# 5. User claims LP's HTLC
# 6. LP auto-claims user's HTLC
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
echo -e "${MAGENTA}║         FULL ATOMIC SWAP TEST (Production Flow)               ║${NC}"
echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# STEP 1: Choose swap direction
# =============================================================================
echo -e "${CYAN}[1/7]${NC} Configuration"
echo "─────────────────────────────────────────────────────────────────"

# Default: USDC → BTC
FROM_ASSET="${1:-USDC}"
FROM_AMOUNT="${2:-}"  # Optional second arg for amount

if [ "$FROM_ASSET" == "BTC" ]; then
    FROM_AMOUNT="${FROM_AMOUNT:-0.0001}"  # 10000 sats
    TO_ASSET="USDC"
elif [ "$FROM_ASSET" == "USDC" ]; then
    FROM_AMOUNT="${FROM_AMOUNT:-2.0}"     # 2 USDC (testnet low amount)
    TO_ASSET="BTC"
else
    echo "Usage: $0 [BTC|USDC] [amount]"
    echo "  Example: $0 USDC 2.0"
    exit 1
fi

echo "Swap: $FROM_AMOUNT $FROM_ASSET → $TO_ASSET"
echo ""

# =============================================================================
# STEP 2: User generates secret
# =============================================================================
echo -e "${CYAN}[2/7]${NC} User Generates Secret"
echo "─────────────────────────────────────────────────────────────────"

SECRET=$(openssl rand -hex 32)
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | openssl dgst -sha256 -binary | xxd -p | tr -d '\n')

echo "Secret:   $SECRET"
echo "Hashlock: $HASHLOCK"
echo ""

# =============================================================================
# STEP 3: Get user addresses
# =============================================================================
echo -e "${CYAN}[3/7]${NC} User Addresses"
echo "─────────────────────────────────────────────────────────────────"

# User's EVM address (for receiving USDC or sending USDC)
USER_EVM="0x4928542712Ab06c6C1963c42091827Cb2D70d265"
echo "User EVM:  $USER_EVM"

# User's BTC address (for receiving BTC or refund)
USER_BTC=$(ssh -i $SSH_KEY ubuntu@$OP3_IP '
    ~/bitcoin/bin/bitcoin-cli -signet -datadir=$HOME/.bitcoin-signet getnewaddress "swap_test" bech32
' 2>/dev/null || echo "btc_error")
echo "User BTC:  $USER_BTC"
echo ""

# =============================================================================
# STEP 4: Initiate swap via API
# =============================================================================
echo -e "${CYAN}[4/7]${NC} Initiate Full Swap"
echo "─────────────────────────────────────────────────────────────────"

if [ "$FROM_ASSET" == "USDC" ]; then
    RECEIVE_ADDR="$USER_BTC"
    REFUND_ADDR="$USER_EVM"
else
    RECEIVE_ADDR="$USER_EVM"
    REFUND_ADDR="$USER_BTC"
fi

INIT_RESULT=$(curl -s -X POST "$LP_API/api/swap/full/initiate" \
    -H "Content-Type: application/json" \
    -d "{
        \"from_asset\": \"$FROM_ASSET\",
        \"to_asset\": \"$TO_ASSET\",
        \"from_amount\": $FROM_AMOUNT,
        \"hashlock\": \"$HASHLOCK\",
        \"user_receive_address\": \"$RECEIVE_ADDR\",
        \"user_refund_address\": \"$REFUND_ADDR\"
    }")

SWAP_ID=$(echo "$INIT_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('swap_id',''))" 2>/dev/null)

if [ -z "$SWAP_ID" ]; then
    echo "ERROR: Failed to initiate swap"
    echo "$INIT_RESULT" | python3 -m json.tool 2>/dev/null || echo "$INIT_RESULT"
    exit 1
fi

echo -e "${GREEN}✓ Swap Initiated: $SWAP_ID${NC}"
echo ""
echo "Quote:"
echo "$INIT_RESULT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
q=d.get('quote',{})
print(f\"  {q.get('from_amount')} {q.get('from_asset')} → {q.get('to_amount')} {q.get('to_asset')}\")
print(f\"  Rate: {q.get('rate')} (spread: {q.get('spread_percent')}%)\")
"
echo ""
echo "Deposit Instructions:"
echo "$INIT_RESULT" | python3 -c "
import json,sys
d=json.load(sys.stdin).get('deposit_instructions',{})
for k,v in d.items():
    print(f\"  {k}: {v}\")
"
echo ""

# =============================================================================
# STEP 5: User creates HTLC
# =============================================================================
echo -e "${CYAN}[5/7]${NC} User Creates HTLC"
echo "─────────────────────────────────────────────────────────────────"

if [ "$FROM_ASSET" == "USDC" ]; then
    # Get user's private key
    USER_KEY=$(ssh -i $SSH_KEY ubuntu@$OP3_IP 'python3 -c "import json; print(json.load(open(\"/home/ubuntu/.keys/user_evm.json\"))[\"private_key\"])"')
    LP_EVM=$(echo "$INIT_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['deposit_instructions']['receiver'])")

    echo "Creating USDC HTLC: $FROM_AMOUNT USDC → LP ($LP_EVM)"

    # First approve HTLC contract
    echo "Approving HTLC contract..."
    APPROVE_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "
cd ~/pna-sdk && ./venv/bin/python3 << 'PYEOF'
from web3 import Web3
from eth_account import Account

RPC_URL = 'https://sepolia.base.org'
CHAIN_ID = 84532
USDC_CONTRACT = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
HTLC_CONTRACT = '0xBCf3eeb42629143A1B29d9542fad0E54a04dBFD2'
USER_KEY = '$USER_KEY'

w3 = Web3(Web3.HTTPProvider(RPC_URL))
account = Account.from_key('0x' + USER_KEY if not USER_KEY.startswith('0x') else USER_KEY)

MAX_UINT256 = 2**256 - 1
usdc_abi = [{'name': 'approve', 'type': 'function', 'inputs': [{'name': 'spender', 'type': 'address'}, {'name': 'amount', 'type': 'uint256'}], 'outputs': [{'name': '', 'type': 'bool'}]}, {'name': 'allowance', 'type': 'function', 'stateMutability': 'view', 'inputs': [{'name': 'owner', 'type': 'address'}, {'name': 'spender', 'type': 'address'}], 'outputs': [{'name': '', 'type': 'uint256'}]}]
usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_CONTRACT), abi=usdc_abi)

# Check allowance
allowance = usdc.functions.allowance(account.address, Web3.to_checksum_address(HTLC_CONTRACT)).call()
if allowance < int($FROM_AMOUNT * 1e6):
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
    print(f'Approved: {receipt[\"status\"]}')
else:
    print('Already approved')
PYEOF
")
    echo "  $APPROVE_RESULT"

    # Create HTLC
    echo "Creating HTLC..."
    HTLC_RESULT=$(ssh -i $SSH_KEY ubuntu@$OP1_IP "
cd ~/pna-sdk && ./venv/bin/python3 << 'PYEOF'
import json
from sdk.htlc.evm import create_htlc

result = create_htlc(
    receiver='$LP_EVM',
    amount_usdc=$FROM_AMOUNT,
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
        echo -e "${GREEN}✓ User USDC HTLC Created${NC}"
        echo "  HTLC ID: $HTLC_ID"
        echo "  TX: https://sepolia.basescan.org/tx/0x$TX_HASH"
    else
        echo "ERROR: $HTLC_RESULT"
        exit 1
    fi

    # Register HTLC with LP
    echo ""
    echo "Registering HTLC with LP..."
    REG_RESULT=$(curl -s -X POST "$LP_API/api/swap/full/$SWAP_ID/register-htlc?htlc_id=$HTLC_ID")
    echo "$REG_RESULT" | python3 -m json.tool 2>/dev/null | head -10

elif [ "$FROM_ASSET" == "BTC" ]; then
    # Get deposit address from init result
    HTLC_ADDR=$(echo "$INIT_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['deposit_instructions']['htlc_address'])")
    AMOUNT_BTC=$(echo "$INIT_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['deposit_instructions']['amount_btc'])")

    echo "BTC HTLC Address: $HTLC_ADDR"
    echo "Sending $AMOUNT_BTC BTC..."

    # Send BTC from user wallet
    SEND_TX=$(ssh -i $SSH_KEY ubuntu@$OP3_IP "
        ~/bitcoin/bin/bitcoin-cli -signet -datadir=\$HOME/.bitcoin-signet \
        sendtoaddress '$HTLC_ADDR' $AMOUNT_BTC
    " 2>&1)

    if [[ "$SEND_TX" =~ ^[a-f0-9]{64}$ ]]; then
        echo -e "${GREEN}✓ User BTC Sent: $SEND_TX${NC}"
    else
        echo -e "${YELLOW}! BTC send failed: $SEND_TX${NC}"
        exit 1
    fi
fi
echo ""

# =============================================================================
# STEP 6: Wait for LP to create counter-HTLC
# =============================================================================
echo -e "${CYAN}[6/8]${NC} Waiting for LP M1 HTLC (4-HTLC Step 2)"
echo "─────────────────────────────────────────────────────────────────"

echo "LP watcher will detect deposit and create M1 HTLC..."
echo "Polling swap status..."

for i in {1..30}; do
    sleep 5
    STATUS=$(curl -s "$LP_API/api/swap/full/$SWAP_ID/status")
    SWAP_STATUS=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)

    echo "  [$i/30] Status: $SWAP_STATUS"

    if [ "$SWAP_STATUS" == "m1_htlc_created" ]; then
        echo -e "${GREEN}✓ LP M1 HTLC Created!${NC}"
        echo "$STATUS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'lp_m1_htlc_outpoint' in d:
    print(f\"  M1 HTLC: {d['lp_m1_htlc_outpoint']}\")
"
        break
    fi

    if [ "$SWAP_STATUS" == "completed" ]; then
        echo -e "${GREEN}✓ Swap already completed!${NC}"
        break
    fi
done

# =============================================================================
# STEP 7: User claims M1 HTLC (reveals preimage on BATHRON)
# =============================================================================
echo ""
echo -e "${CYAN}[7/8]${NC} User Claims M1 HTLC (4-HTLC Step 3 - Reveals S)"
echo "─────────────────────────────────────────────────────────────────"

STATUS=$(curl -s "$LP_API/api/swap/full/$SWAP_ID/status")
SWAP_STATUS=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)

if [ "$SWAP_STATUS" == "m1_htlc_created" ]; then
    echo "User claims M1 HTLC with preimage S..."
    echo "Preimage: $SECRET"
    echo ""

    CLAIM_M1=$(curl -s -X POST "$LP_API/api/swap/full/$SWAP_ID/claim-m1?preimage=$SECRET")

    if echo "$CLAIM_M1" | grep -q '"success": true'; then
        M1_TX=$(echo "$CLAIM_M1" | python3 -c "import json,sys; print(json.load(sys.stdin).get('m1_claim_txid',''))" 2>/dev/null)
        echo -e "${GREEN}✓ M1 HTLC Claimed! Preimage revealed on BATHRON${NC}"
        echo "  M1 TX: $M1_TX"
        echo ""
        echo "LP will now detect preimage and complete the swap..."
    else
        echo "M1 claim result:"
        echo "$CLAIM_M1" | python3 -m json.tool 2>/dev/null || echo "$CLAIM_M1"
    fi
elif [ "$SWAP_STATUS" == "completed" ]; then
    echo -e "${GREEN}Swap already completed!${NC}"
else
    echo "Status: $SWAP_STATUS - cannot claim M1 yet"
fi

# =============================================================================
# STEP 7: User claims LP's HTLC (reveals preimage)
# =============================================================================
# =============================================================================
# STEP 8: Wait for LP to complete (4-HTLC Steps 4 & 5)
# =============================================================================
echo ""
echo -e "${CYAN}[8/8]${NC} Waiting for LP to Complete Swap"
echo "─────────────────────────────────────────────────────────────────"

echo "LP will detect preimage on M1 and:"
echo "  - Send BTC to user (Step 4)"
echo "  - Claim USDC from user's HTLC (Step 5)"
echo ""
echo "Polling for completion..."

for i in {1..20}; do
    sleep 5
    STATUS=$(curl -s "$LP_API/api/swap/full/$SWAP_ID/status")
    SWAP_STATUS=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)

    echo "  [$i/20] Status: $SWAP_STATUS"

    if [ "$SWAP_STATUS" == "completed" ]; then
        echo ""
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              4-HTLC ATOMIC SWAP COMPLETE!                     ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "$STATUS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('Transactions:')
if 'lp_m1_htlc_txid' in d:
    print(f\"  HTLC-2 (LP M1):  {d['lp_m1_htlc_txid']}\")
if 'm1_claim_txid' in d:
    print(f\"  M1 Claim:        {d['m1_claim_txid']}\")
if 'lp_btc_tx' in d:
    print(f\"  HTLC-4 (LP BTC): {d['lp_btc_tx']}\")
if 'lp_usdc_claim_tx' in d:
    print(f\"  USDC Claim:      {d['lp_usdc_claim_tx']}\")
"
        break
    fi
done

if [ "$SWAP_STATUS" != "completed" ]; then
    echo ""
    echo -e "${YELLOW}Swap not yet complete. Final status: $SWAP_STATUS${NC}"
fi

echo ""

# =============================================================================
# Final Status
# =============================================================================
echo "─────────────────────────────────────────────────────────────────"
echo "Final Swap Status:"
curl -s "$LP_API/api/swap/full/$SWAP_ID/status" | python3 -m json.tool 2>/dev/null | head -20

echo ""
echo -e "${MAGENTA}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║                 FULL ATOMIC SWAP TEST COMPLETE                 ║${NC}"
echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
