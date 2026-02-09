#!/bin/bash
SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

$SSH ubuntu@51.75.31.44 '
echo "=== Process ==="
ps aux | grep bitcoind | grep -v grep

echo ""
echo "=== Config ==="
cat /home/ubuntu/.bitcoin-signet/bitcoin.conf 2>/dev/null | head -10

echo ""
echo "=== Debug log (last 20 lines) ==="
tail -20 /home/ubuntu/.bitcoin-signet/signet/debug.log 2>/dev/null || tail -20 /home/ubuntu/.bitcoin-signet/debug.log 2>/dev/null || echo "No log found"

echo ""
echo "=== Disk space ==="
df -h /home/ubuntu
'
