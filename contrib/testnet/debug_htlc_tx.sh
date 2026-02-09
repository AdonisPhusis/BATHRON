#!/bin/bash
# Debug HTLC transaction

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

HTLC_TXID="59a384a0d9857ea99caf330e90c3f937109514300cb6fca165b7dccace7dbd2e"

echo "=== Check TX in wallet ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet gettransaction $HTLC_TXID" 2>&1 | head -20

echo ""
echo "=== Check raw TX ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getrawtransaction $HTLC_TXID true" 2>&1 | head -40

echo ""
echo "=== Check mempool ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getmempoolentry $HTLC_TXID" 2>&1

echo ""
echo "=== Current block height ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet getblockcount"

echo ""
echo "=== All HTLCs in htlc_list ==="
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_list"
