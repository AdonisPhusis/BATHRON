#!/bin/bash
# Diagnose why Charlie cannot claim HTLC 31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"  # alice (LP)
OP3_IP="51.75.31.44"    # charlie (user)

HTLC_OUTPOINT="31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0"
PREIMAGE="8f894b5829fc8f4096a9f177260e7cb46c175f2961ade379b58cdcdd338c36ef"
CHARLIE_ADDR="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"

echo "==== Diagnosing Charlie HTLC Claim Issue ===="
echo "HTLC: $HTLC_OUTPOINT"
echo "Preimage: $PREIMAGE"
echo "Charlie's address: $CHARLIE_ADDR"
echo ""

echo "=== 1. Check HTLC details on OP1 (alice - LP) ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "/home/ubuntu/bathron-cli -testnet htlc_get \"$HTLC_OUTPOINT\"" || echo "Failed to get HTLC details"
echo ""

echo "=== 2. Check if HTLC is in active list on OP1 ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "/home/ubuntu/bathron-cli -testnet htlc_list active" | grep -A 10 "$HTLC_OUTPOINT" || echo "Not found in active list"
echo ""

echo "=== 3. Check Charlie's wallet on OP3 ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet validateaddress \"$CHARLIE_ADDR\"" || echo "Failed to validate address"
echo ""

echo "=== 4. Check if Charlie's wallet has the claim key ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getaddressinfo \"$CHARLIE_ADDR\"" || echo "Failed to get address info"
echo ""

echo "=== 5. Try to claim HTLC from OP3 (charlie) ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet htlc_claim \"$HTLC_OUTPOINT\" \"$PREIMAGE\"" 2>&1 || echo "Claim attempt failed (expected if permission issue)"
echo ""

echo "=== 6. Check mempool on both nodes ==="
echo "--- OP1 mempool ---"
ssh -i $SSH_KEY ubuntu@$OP1_IP "/home/ubuntu/bathron-cli -testnet getmempoolinfo"
echo ""
echo "--- OP3 mempool ---"
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getmempoolinfo"
echo ""

echo "=== 7. Check current block height on both nodes ==="
echo "--- OP1 height ---"
ssh -i $SSH_KEY ubuntu@$OP1_IP "/home/ubuntu/bathron-cli -testnet getblockcount"
echo "--- OP3 height ---"
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getblockcount"
echo ""

echo "=== Diagnosis Complete ==="
