#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OP3_IP="51.75.31.44"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== Claiming M1 HTLC for Charlie on OP3 ==="

HTLC_OUTPOINT="fc92a707573b1b9f42bd1b15554219c09e4ae96e11da86cb203c5ddb0bcc075c:0"
PREIMAGE="847d6f974d45b17d181be9e33717551dda1e5c1fd24907265bbb4ab892448e31"
CHARLIE_M1_ADDR="yEtEU5nWMENkpeTDhZhroerDhUadgVazs1"

echo "HTLC Outpoint: $HTLC_OUTPOINT"
echo "Preimage: $PREIMAGE"
echo "Charlie M1 Address: $CHARLIE_M1_ADDR"
echo ""

echo "Step 1: Verify HTLC exists on chain..."
ssh -i "$SSH_KEY" ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet htlc_get '$HTLC_OUTPOINT'" || {
    echo "ERROR: HTLC not found on chain"
    exit 1
}
echo ""

echo "Step 2: Check if wallet has the required key..."
ssh -i "$SSH_KEY" ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getaddressinfo '$CHARLIE_M1_ADDR'" | grep -q '"ismine": true' || {
    echo "WARNING: Wallet doesn't have key for $CHARLIE_M1_ADDR"
    echo "Checking if we need to import key..."
    
    # Check if key file exists
    if ssh -i "$SSH_KEY" ubuntu@$OP3_IP "[ -f ~/.BathronKey/wallet.json ]"; then
        echo "Key file exists, attempting to import..."
        # This would require the WIF from the wallet.json
        echo "NOTE: Manual key import may be required"
    fi
}
echo ""

echo "Step 3: Claiming HTLC..."
CLAIM_TXID=$(ssh -i "$SSH_KEY" ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet htlc_claim '$HTLC_OUTPOINT' '$PREIMAGE'")

if [ $? -eq 0 ]; then
    echo "✓ HTLC Claim successful!"
    echo "Claim Transaction ID: $CLAIM_TXID"
    echo ""
    
    echo "Step 4: Verify transaction..."
    sleep 2
    ssh -i "$SSH_KEY" ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getrawtransaction '$CLAIM_TXID' 1" || true
    echo ""
    
    echo "Step 5: Check mempool..."
    ssh -i "$SSH_KEY" ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getmempoolinfo"
    
    echo ""
    echo "=== Claim Complete ==="
    echo "Transaction: $CLAIM_TXID"
    echo "Preimage revealed on BATHRON chain"
else
    echo "ERROR: HTLC claim failed"
    echo "Output: $CLAIM_TXID"
    exit 1
fi
