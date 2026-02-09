#!/usr/bin/env bash
set -euo pipefail

# test_htlc_creation.sh
# Test HTLC creation with fresh M1 receipt

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"
CORESDK_CLI="\$HOME/BATHRON-Core/src/bathron-cli"

echo "=========================================="
echo "HTLC Creation Test"
echo "=========================================="
echo ""

echo "Step 1: Create fresh M1 receipt (lock 10000 M0)..."
echo "---------------------------------------------------"
LOCK_RESULT=$(ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CORESDK_CLI -testnet lock 10000" 2>&1)
echo "$LOCK_RESULT"
echo ""

if echo "$LOCK_RESULT" | grep -q "txid"; then
    RECEIPT_OUTPOINT=$(echo "$LOCK_RESULT" | grep receipt_outpoint | cut -d'"' -f4)
    echo "Receipt created: $RECEIPT_OUTPOINT"
    echo ""
    
    echo "Step 2: Wait for confirmation..."
    sleep 65  # Wait for next block
    
    echo "Step 3: Check receipt in wallet..."
    ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CORESDK_CLI -testnet getwalletstate true | grep -A 10 receipts"
    echo ""
    
    echo "Step 4: Generate HTLC parameters..."
    HTLC_GEN=$(ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CORESDK_CLI -testnet htlc_generate" 2>&1)
    echo "$HTLC_GEN"
    
    HASHLOCK=$(echo "$HTLC_GEN" | grep hashlock | cut -d'"' -f4)
    SECRET=$(echo "$HTLC_GEN" | grep secret | cut -d'"' -f4)
    
    echo ""
    echo "Step 5: Get claim address..."
    CLAIM_ADDR=$(ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CORESDK_CLI -testnet getnewaddress htlc_claim" 2>&1)
    echo "Claim address: $CLAIM_ADDR"
    echo ""
    
    echo "Step 6: Create HTLC..."
    echo "Command: htlc_create_m1 \"$RECEIPT_OUTPOINT\" \"$HASHLOCK\" \"$CLAIM_ADDR\" 20"
    echo ""
    
    HTLC_CREATE=$(ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CORESDK_CLI -testnet htlc_create_m1 \"$RECEIPT_OUTPOINT\" \"$HASHLOCK\" \"$CLAIM_ADDR\" 20" 2>&1)
    echo "$HTLC_CREATE"
    echo ""
    
    if echo "$HTLC_CREATE" | grep -q "txid"; then
        echo "SUCCESS: HTLC created!"
        echo "Secret (save this): $SECRET"
        
        HTLC_TXID=$(echo "$HTLC_CREATE" | grep '^\s*"txid"' | cut -d'"' -f4)
        
        echo ""
        echo "Step 7: Wait for block inclusion..."
        sleep 65
        
        echo "Step 8: Check HTLC status..."
        ssh $SSH_OPTS ubuntu@$CORESDK_IP "$CORESDK_CLI -testnet htlc_list"
        
    else
        echo "FAILED: HTLC creation rejected"
        echo "Error details above"
    fi
else
    echo "FAILED: Could not create M1 receipt"
fi

