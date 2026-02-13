#!/bin/bash
# Check which binary is running on Seed and what btcspv returns
SSH="ssh -i ~/.ssh/id_ed25519_vps -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
SEED_IP=57.131.33.151

echo "=== Binary checksum ==="
echo "Local:"
md5sum /home/ubuntu/BATHRON/src/bathrond | cut -d' ' -f1
echo "Seed ~/bathrond:"
$SSH ubuntu@$SEED_IP 'md5sum ~/bathrond 2>/dev/null | cut -d" " -f1 || echo "missing"'
echo "Seed ~/BATHRON-Core/src/bathrond:"
$SSH ubuntu@$SEED_IP 'md5sum ~/BATHRON-Core/src/bathrond 2>/dev/null | cut -d" " -f1 || echo "missing"'

echo ""
echo "=== Daemon running? ==="
$SSH ubuntu@$SEED_IP 'pgrep -a bathrond 2>/dev/null || echo "not running"'

echo ""
echo "=== Start fresh daemon and check SPV ==="
$SSH ubuntu@$SEED_IP '
    pkill -9 bathrond 2>/dev/null; sleep 2
    rm -rf ~/.bathron/testnet5/btcspv ~/.bathron/testnet5/blocks ~/.bathron/testnet5/chainstate
    rm -rf ~/.bathron/testnet5/evodb ~/.bathron/testnet5/llmq ~/.bathron/testnet5/.lock
    ~/bathrond -testnet -daemon -noconnect -masternode=0 2>&1
    sleep 10
    echo "--- getbtcsyncstatus ---"
    ~/bathron-cli -testnet getbtcsyncstatus 2>&1
    echo "--- getblockcount ---"
    ~/bathron-cli -testnet getblockcount 2>&1
    echo "--- btcspv dir ---"
    ls -la ~/.bathron/testnet5/btcspv/ 2>/dev/null || echo "no btcspv dir"
    echo "--- stopping ---"
    ~/bathron-cli -testnet stop 2>&1
'
