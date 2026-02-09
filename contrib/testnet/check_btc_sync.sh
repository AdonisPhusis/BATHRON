#!/bin/bash
# Quick check BTC Signet sync status on OP3

SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

$SSH ubuntu@51.75.31.44 '
BTC=~/bitcoin/bin

echo "=== BTC Process ==="
ps aux | grep bitcoind | grep -v grep | head -1 || echo "Not running"

echo ""
echo "=== BTC Signet Sync ==="
$BTC/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet getblockchaininfo 2>&1 | head -20
'
