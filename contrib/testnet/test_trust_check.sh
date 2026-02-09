#!/bin/bash
# Test the trustless verification in reveal-preimage endpoint
# This verifies that LP cannot claim USDC without user claiming BTC first

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
OP1_IP="57.131.33.152"
LP_URL="http://$OP1_IP:8080"

echo "=== Testing Trustless Verification (reveal-preimage) ==="
echo ""

# Generate test secret and hashlock
SECRET=$(openssl rand -hex 32)
HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | sha256sum | cut -d' ' -f1)
echo "Generated Secret: $SECRET"
echo "Generated Hashlock: $HASHLOCK"
echo ""

# Step 1: Create a full swap
echo "Step 1: Creating full swap..."
RESPONSE=$(curl -s -X POST "$LP_URL/api/swap/full/initiate" \
  -H "Content-Type: application/json" \
  -d "{
    \"from_asset\": \"USDC\",
    \"to_asset\": \"BTC\",
    \"from_amount\": 100,
    \"hashlock\": \"$HASHLOCK\",
    \"user_receive_address\": \"tb1qkd2kyur0yqxpp6hvtwheukwpfjt2h5atapyhe7\"
  }")

SWAP_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('swap_id',''))")
echo "Swap ID: $SWAP_ID"

if [ -z "$SWAP_ID" ]; then
    echo "ERROR: Failed to create swap"
    echo "$RESPONSE"
    exit 1
fi

# Step 2: Get a real UTXO from OP1's BTC wallet for testing
echo ""
echo "Step 2: Getting a real BTC UTXO for trust check test..."
UTXO_INFO=$(ssh -i "$SSH_KEY" ubuntu@$OP1_IP '
~/bitcoin/bin/bitcoin-cli -signet listunspent 1 | python3 -c "
import json,sys
utxos = json.load(sys.stdin)
if utxos:
    u = utxos[0]
    print(u[\"txid\"], u[\"vout\"], u[\"address\"])
else:
    print(\"ERROR: No UTXOs found\")
"')

TXID=$(echo "$UTXO_INFO" | cut -d' ' -f1)
VOUT=$(echo "$UTXO_INFO" | cut -d' ' -f2)
BTC_ADDR=$(echo "$UTXO_INFO" | cut -d' ' -f3)

if [ "$TXID" = "ERROR:" ]; then
    echo "No UTXOs available for testing"
    exit 1
fi

echo "Using real UTXO for test:"
echo "  TXID: $TXID"
echo "  VOUT: $VOUT"
echo "  Address: $BTC_ADDR"

# Step 3: Set the BTC HTLC fields on the swap (simulating LP creating BTC HTLC)
echo ""
echo "Step 3: Setting BTC HTLC fields (simulating LP BTC HTLC creation)..."
curl -s -X POST "$LP_URL/api/test/swap/$SWAP_ID/set-btc-htlc?btc_address=$BTC_ADDR&funding_txid=$TXID&user_htlc_id=test_htlc_123" | python3 -m json.tool

# Step 4: Check swap status
echo ""
echo "Step 4: Checking swap status (should be btc_htlc_ready)..."
curl -s "$LP_URL/api/swap/full/$SWAP_ID/status" | python3 -m json.tool

# Step 5: Try to reveal preimage (this should FAIL - UTXO still exists)
echo ""
echo "Step 5: Attempting to reveal preimage (BTC HTLC NOT claimed yet)..."
echo "(This should be REJECTED by trustless verification)"
echo ""

REVEAL_RESPONSE=$(curl -s -X POST "$LP_URL/api/swap/full/$SWAP_ID/reveal-preimage?preimage=$SECRET")
echo "Response:"
echo "$REVEAL_RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$REVEAL_RESPONSE"

# Check if it was rejected with TRUSTLESS VIOLATION
if echo "$REVEAL_RESPONSE" | grep -qi "TRUSTLESS VIOLATION"; then
    echo ""
    echo "=============================================="
    echo "✓ TRUST CHECK VERIFIED WORKING!"
    echo "=============================================="
    echo ""
    echo "The trust check correctly REJECTED the preimage reveal because"
    echo "the BTC HTLC has not been claimed by the user yet."
    echo ""
    echo "This ensures:"
    echo "  1. LP cannot steal USDC by revealing preimage early"
    echo "  2. User MUST claim BTC first (revealing preimage on-chain)"
    echo "  3. Only then can LP claim USDC using the on-chain preimage"
    echo ""
    echo "ATOMIC SWAP IS TRUSTLESS! ✓"
else
    echo ""
    echo "=============================================="
    echo "✗ TRUST CHECK MAY NOT BE WORKING CORRECTLY"
    echo "=============================================="
    echo ""
    echo "Expected: TRUSTLESS VIOLATION error"
    echo "Got: $REVEAL_RESPONSE"
    echo ""
    echo "Check server logs: ./contrib/testnet/diagnose_pna_lp.sh logs"
fi

echo ""
echo "=== Test Complete ==="
