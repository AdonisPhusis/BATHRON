#!/bin/bash
# Find and fix BTC config on OP1

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
OP1_IP="57.131.33.152"

echo "=== Finding BTC Config on OP1 ==="

echo "1. Find all bitcoin directories:"
ssh $SSH_OPTS ubuntu@$OP1_IP "find ~ -name 'bitcoin*' -type d 2>/dev/null | head -20"

echo ""
echo "2. Find bitcoin.conf files:"
ssh $SSH_OPTS ubuntu@$OP1_IP "find ~ -name 'bitcoin.conf' 2>/dev/null"

echo ""
echo "3. Check running bitcoind process:"
ssh $SSH_OPTS ubuntu@$OP1_IP "ps aux | grep bitcoind | grep -v grep"

echo ""
echo "4. Try different CLI paths:"
for path in "/home/ubuntu/.bitcoin-signet" "/home/ubuntu/.bitcoin" "/home/ubuntu/bitcoin-signet"; do
    echo "  Trying: $path"
    ssh $SSH_OPTS ubuntu@$OP1_IP "/home/ubuntu/bitcoin/bin/bitcoin-cli -datadir=$path getblockcount 2>&1" | head -1
done

echo ""
echo "5. Check bitcoin.conf content:"
ssh $SSH_OPTS ubuntu@$OP1_IP "cat ~/.bitcoin-signet/bitcoin.conf 2>/dev/null || echo 'File not found'"
