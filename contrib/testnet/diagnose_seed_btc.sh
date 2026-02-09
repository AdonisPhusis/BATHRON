#!/bin/bash
# Diagnose BTC Signet configuration on Seed

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_CMD="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "════════════════════════════════════════════════════════════════"
echo "  BTC Signet Configuration Diagnostic (Seed)"
echo "════════════════════════════════════════════════════════════════"
echo ""

$SSH_CMD ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
echo "=== BTC Binary Locations ==="
find ~ -name "bitcoin-cli" -type f -executable 2>/dev/null | head -5

echo ""
echo "=== BTC Datadir/Config Locations ==="
find ~ -name "bitcoin.conf" 2>/dev/null | head -5
ls -d ~/.bitcoin*/signet 2>/dev/null || echo "No ~/.bitcoin*/signet"
ls -d ~/BTCTESTNET/data 2>/dev/null || echo "No ~/BTCTESTNET/data"

echo ""
echo "=== Try Different BTC CLI Commands ==="
# Try with -conf
if [ -f ~/.bitcoin-signet/bitcoin.conf ]; then
    echo "[Test 1] bitcoin-cli -conf=~/.bitcoin-signet/bitcoin.conf"
    ~/bitcoin-27.0/bin/bitcoin-cli -conf=~/.bitcoin-signet/bitcoin.conf getblockcount 2>&1 | head -1
fi

# Try with -datadir absolute
echo "[Test 2] bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet"
~/bitcoin-27.0/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet getblockcount 2>&1 | head -1

# Try with -signet flag
echo "[Test 3] bitcoin-cli -signet (default datadir)"
~/bitcoin-27.0/bin/bitcoin-cli -signet getblockcount 2>&1 | head -1

# Try BTCTESTNET path if exists
if [ -f ~/BTCTESTNET/data/bitcoin.conf ]; then
    echo "[Test 4] bitcoin-cli -conf=~/BTCTESTNET/data/bitcoin.conf"
    ~/bitcoin-27.0/bin/bitcoin-cli -conf=~/BTCTESTNET/data/bitcoin.conf getblockcount 2>&1 | head -1
fi

# Check for running bitcoind
echo ""
echo "=== Running Bitcoin Processes ==="
pgrep -a bitcoind || echo "No bitcoind running"
REMOTE

