#!/bin/bash
#
# Test script to verify hashlock byte order fix
# Tests that htlc_generate → htlc_verify roundtrip works correctly
#

set -e

SSH="ssh -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1="ubuntu@57.131.33.152"
CLI="~/bathron-cli -testnet"

echo "═══════════════════════════════════════════════════════════════"
echo "     HASHLOCK BYTE ORDER FIX VERIFICATION"
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "[1] Testing htlc_generate → htlc_verify roundtrip..."
echo "─────────────────────────────────────────────────────────────────"

# Generate secret and hashlock
RESULT=$($SSH $OP1 "$CLI htlc_generate")
echo "Generated: $RESULT"

SECRET=$(echo "$RESULT" | jq -r '.secret')
HASHLOCK=$(echo "$RESULT" | jq -r '.hashlock')

echo ""
echo "  Secret:   $SECRET"
echo "  Hashlock: $HASHLOCK"
echo ""

# Verify roundtrip
echo "  Verifying htlc_verify(secret, hashlock)..."
VERIFY=$($SSH $OP1 "$CLI htlc_verify $SECRET $HASHLOCK")
VALID=$(echo "$VERIFY" | jq -r '.valid')

if [[ "$VALID" == "true" ]]; then
    echo -e "  \033[0;32m✓ Roundtrip verification PASSED\033[0m"
else
    echo -e "  \033[0;31m✗ Roundtrip verification FAILED\033[0m"
    echo "    Response: $VERIFY"
    exit 1
fi

echo ""
echo "[2] Testing external hashlock (Python SHA256 format)..."
echo "─────────────────────────────────────────────────────────────────"

# Simulate what Python/EVM does: SHA256 in big-endian hex format
# Use a known secret and compute its hash
KNOWN_SECRET="de6638e23ba7af4dc7f3650f2a29ce68089a402b0527be80a3b7d0b49c847b3d"
EXPECTED_HASH=$(echo -n "$KNOWN_SECRET" | xxd -r -p | sha256sum | cut -d' ' -f1)

echo "  Known Secret:   $KNOWN_SECRET"
echo "  Expected Hash:  $EXPECTED_HASH"

# Verify with htlc_verify
echo ""
echo "  Verifying htlc_verify(known_secret, expected_hash)..."
VERIFY2=$($SSH $OP1 "$CLI htlc_verify $KNOWN_SECRET $EXPECTED_HASH")
VALID2=$(echo "$VERIFY2" | jq -r '.valid')

if [[ "$VALID2" == "true" ]]; then
    echo -e "  \033[0;32m✓ External hashlock verification PASSED\033[0m"
else
    echo -e "  \033[0;31m✗ External hashlock verification FAILED\033[0m"
    echo "    Response: $VERIFY2"
fi

echo ""
echo "[3] Testing M1 HTLC creation and list..."
echo "─────────────────────────────────────────────────────────────────"

# Check for existing receipts
RECEIPTS=$($SSH $OP1 "$CLI getwalletstate true" | jq '.m1.receipts // []')
RECEIPT_COUNT=$(echo "$RECEIPTS" | jq 'length')

if [[ "$RECEIPT_COUNT" -gt 0 ]]; then
    echo "  Found $RECEIPT_COUNT M1 receipt(s)"
    FIRST_RECEIPT=$(echo "$RECEIPTS" | jq -r '.[0].outpoint // empty')

    if [[ -n "$FIRST_RECEIPT" ]]; then
        echo "  Using receipt: $FIRST_RECEIPT"

        # Get claim address
        CLAIM_ADDR=$($SSH $OP1 "$CLI getnewaddress htlc_test")
        echo "  Claim address: $CLAIM_ADDR"

        # Create HTLC with the external hashlock
        echo ""
        echo "  Creating M1 HTLC with hashlock $EXPECTED_HASH..."
        HTLC_RESULT=$($SSH $OP1 "$CLI htlc_create_m1 $FIRST_RECEIPT $EXPECTED_HASH $CLAIM_ADDR" 2>&1) || true

        if echo "$HTLC_RESULT" | grep -q '"txid"'; then
            echo -e "  \033[0;32m✓ HTLC created successfully\033[0m"
            echo "  $HTLC_RESULT"

            # List HTLCs and verify hashlock matches
            echo ""
            echo "  Waiting for block confirmation..."
            sleep 10

            HTLC_LIST=$($SSH $OP1 "$CLI htlc_list")
            echo "  HTLC List: $HTLC_LIST"

            # Check if the hashlock in the list matches expected
            LIST_HASHLOCK=$(echo "$HTLC_LIST" | jq -r '.[0].hashlock // empty')
            if [[ "$LIST_HASHLOCK" == "$EXPECTED_HASH" ]]; then
                echo -e "  \033[0;32m✓ Hashlock in list matches input: $LIST_HASHLOCK\033[0m"
            else
                echo -e "  \033[0;31m✗ Hashlock mismatch!\033[0m"
                echo "    Input:    $EXPECTED_HASH"
                echo "    In list:  $LIST_HASHLOCK"
            fi
        else
            echo "  HTLC creation result: $HTLC_RESULT"
            echo "  (May fail if no suitable receipt available)"
        fi
    fi
else
    echo "  No M1 receipts available for HTLC test"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "                    TEST COMPLETE"
echo "═══════════════════════════════════════════════════════════════"
