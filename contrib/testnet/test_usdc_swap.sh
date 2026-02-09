#!/bin/bash
# =============================================================================
# TEST: USDC Atomic Swap (LP → User)
# =============================================================================
# Simulates: User pays BTC, LP sends USDC via HTLC
# User claims USDC by revealing secret
# =============================================================================

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"  # LP
OP3_IP="51.75.31.44"    # User
LP_API="http://$OP1_IP:8080"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           USDC ATOMIC SWAP TEST (LP → User)                   ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# STEP 1: Initial balances
# =============================================================================
echo -e "${CYAN}[1/5]${NC} Initial Balances"
echo "─────────────────────────────────────────────────────────────────"

LP_BAL=$(curl -s "$LP_API/api/sdk/usdc/balance/0xB6bc96842f6085a949b8433dc6316844c32Cba63")
USER_BAL=$(curl -s "$LP_API/api/sdk/usdc/balance/0x4928542712Ab06c6C1963c42091827Cb2D70d265")

echo "LP Wallet:   $(echo $LP_BAL | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['usdc_balance']} USDC, {d['eth_balance']:.4f} ETH\")")"
echo "User Wallet: $(echo $USER_BAL | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['usdc_balance']} USDC, {d['eth_balance']:.4f} ETH\")")"
echo ""

# =============================================================================
# STEP 2: User generates secret
# =============================================================================
echo -e "${CYAN}[2/5]${NC} User Generates Secret"
echo "─────────────────────────────────────────────────────────────────"

SECRET=$(openssl rand -hex 32)
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | openssl dgst -sha256 -binary | xxd -p | tr -d '\n')

echo "Secret:   $SECRET"
echo "Hashlock: $HASHLOCK"
echo ""

# =============================================================================
# STEP 3: LP creates USDC HTLC
# =============================================================================
echo -e "${CYAN}[3/5]${NC} LP Creates USDC HTLC (2 USDC)"
echo "─────────────────────────────────────────────────────────────────"

USER_EVM="0x4928542712Ab06c6C1963c42091827Cb2D70d265"
USDC_AMOUNT="2.0"

echo "Creating HTLC: $USDC_AMOUNT USDC → $USER_EVM"
echo ""

HTLC_RESULT=$(curl -s -X POST "$LP_API/api/sdk/usdc/htlc/create" \
    -H "Content-Type: application/json" \
    -d "{
        \"receiver\": \"$USER_EVM\",
        \"amount_usdc\": $USDC_AMOUNT,
        \"hashlock\": \"$HASHLOCK\",
        \"timelock_seconds\": 3600
    }")

if echo "$HTLC_RESULT" | grep -q '"success":true'; then
    HTLC_ID=$(echo "$HTLC_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['htlc_id'])")
    TX_HASH=$(echo "$HTLC_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tx_hash'])")
    echo -e "${GREEN}✓ HTLC Created${NC}"
    echo "  HTLC ID: $HTLC_ID"
    echo "  TX: https://sepolia.basescan.org/tx/0x$TX_HASH"
else
    echo "ERROR: $(echo $HTLC_RESULT | python3 -c "import json,sys; print(json.load(sys.stdin).get('detail','Unknown error'))")"
    exit 1
fi
echo ""

# =============================================================================
# STEP 4: User claims USDC with secret
# =============================================================================
echo -e "${CYAN}[4/5]${NC} User Claims USDC (Reveals Secret)"
echo "─────────────────────────────────────────────────────────────────"

# Get user's private key
USER_KEY=$(ssh -i $SSH_KEY ubuntu@$OP3_IP 'python3 -c "import json; print(json.load(open(\"/home/ubuntu/.keys/user_evm.json\"))[\"private_key\"])"')

echo "Claiming with secret..."

CLAIM_RESULT=$(curl -s -X POST "$LP_API/api/sdk/usdc/htlc/withdraw" \
    -H "Content-Type: application/json" \
    -d "{
        \"htlc_id\": \"$HTLC_ID\",
        \"preimage\": \"$SECRET\",
        \"private_key\": \"$USER_KEY\"
    }")

if echo "$CLAIM_RESULT" | grep -q '"success":true'; then
    CLAIM_TX=$(echo "$CLAIM_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['tx_hash'])")
    echo -e "${GREEN}✓ USDC Claimed!${NC}"
    echo "  TX: https://sepolia.basescan.org/tx/0x$CLAIM_TX"
else
    echo "ERROR: $(echo $CLAIM_RESULT | python3 -c "import json,sys; print(json.load(sys.stdin).get('detail','Unknown error'))")"
    exit 1
fi
echo ""

# Wait for confirmation
echo "Waiting for confirmation (5s)..."
sleep 5

# =============================================================================
# STEP 5: Verify & Final Balances
# =============================================================================
echo -e "${CYAN}[5/5]${NC} Final Balances"
echo "─────────────────────────────────────────────────────────────────"

LP_BAL=$(curl -s "$LP_API/api/sdk/usdc/balance/0xB6bc96842f6085a949b8433dc6316844c32Cba63")
USER_BAL=$(curl -s "$LP_API/api/sdk/usdc/balance/0x4928542712Ab06c6C1963c42091827Cb2D70d265")

echo "LP Wallet:   $(echo $LP_BAL | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['usdc_balance']} USDC, {d['eth_balance']:.4f} ETH\")")"
echo "User Wallet: $(echo $USER_BAL | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['usdc_balance']} USDC, {d['eth_balance']:.4f} ETH\")")"

# Check HTLC state
echo ""
echo "HTLC State (preimage revealed on-chain):"
HTLC_STATE=$(curl -s "$LP_API/api/sdk/usdc/htlc/${HTLC_ID#0x}")
PREIMAGE=$(echo "$HTLC_STATE" | python3 -c "import json,sys; h=json.load(sys.stdin).get('htlc',{}); print(h.get('preimage','N/A'))")
STATUS=$(echo "$HTLC_STATE" | python3 -c "import json,sys; h=json.load(sys.stdin).get('htlc',{}); print(h.get('status','N/A'))")
echo "  Status: $STATUS"
echo "  Preimage: $PREIMAGE"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    SWAP SUCCESSFUL!                           ║${NC}"
echo -e "${GREEN}╠═══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  User received: $USDC_AMOUNT USDC                                       ║${NC}"
echo -e "${GREEN}║  Secret revealed on Base Sepolia                              ║${NC}"
echo -e "${GREEN}║  LP can now use this secret to claim BTC HTLC                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
