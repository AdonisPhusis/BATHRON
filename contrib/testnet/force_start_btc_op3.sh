#!/bin/bash
SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

echo "=== Force starting BTC Signet on OP3 ==="

# Step 1: Check current state
echo "Step 1: Check current state..."
$SSH ubuntu@51.75.31.44 'ps aux | grep -E "bitcoin|btc" | grep -v grep; echo "---"; ls -la /home/ubuntu/bitcoin/bin/ 2>/dev/null | head -5'

echo ""
echo "Step 2: Start daemon..."
$SSH ubuntu@51.75.31.44 'nohup /home/ubuntu/bitcoin/bin/bitcoind -signet -datadir=/home/ubuntu/.bitcoin-signet -daemon > /tmp/btc_start.log 2>&1; sleep 15; cat /tmp/btc_start.log'

echo ""
echo "Step 3: Check if running..."
$SSH ubuntu@51.75.31.44 'ps aux | grep bitcoind | grep -v grep'

echo ""
echo "Step 4: Check RPC..."
$SSH ubuntu@51.75.31.44 '/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet getblockchaininfo 2>&1 | head -15'

echo ""
echo "Step 5: Create wallet..."
$SSH ubuntu@51.75.31.44 '/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet createwallet "fake_user" 2>&1'
