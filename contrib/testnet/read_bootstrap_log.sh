#!/bin/bash
# Quick diagnostic: read bootstrap log from Seed
SSH="ssh -i ~/.ssh/id_ed25519_vps -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
SEED_IP=57.131.33.151

echo "=== Seed daemon status ==="
$SSH ubuntu@$SEED_IP '
    echo "Processes:"
    ps aux | grep bathrond | grep -v grep || echo "  (none)"
    echo ""
    echo "Normal daemon:"
    ~/bathron-cli -testnet getblockcount 2>&1 || echo "  Not running"
    echo ""
    echo "Bootstrap daemon:"
    ~/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet getblockcount 2>&1 || echo "  Not running"
' 2>/dev/null || echo "SSH failed"

echo ""
echo "=== btcspv state on Seed ==="
$SSH ubuntu@$SEED_IP '
    echo "Normal dir (~/.bathron/testnet5/btcspv):"
    ls -la ~/.bathron/testnet5/btcspv/*.ldb 2>/dev/null | wc -l | xargs -I{} echo "  {} ldb files"
    ls -la ~/.bathron/testnet5/btcspv/ 2>/dev/null | head -5

    echo ""
    echo "Bootstrap dir (/tmp/bathron_bootstrap/testnet5/btcspv):"
    ls -la /tmp/bathron_bootstrap/testnet5/btcspv/*.ldb 2>/dev/null | wc -l | xargs -I{} echo "  {} ldb files"
    ls -la /tmp/bathron_bootstrap/testnet5/btcspv/ 2>/dev/null | head -5

    echo ""
    echo "Backup files:"
    ls -lh ~/btcspv_backup_*.tar.gz 2>/dev/null || echo "  (none)"
    ls -lh ~/btcspv_backup_latest.tar.gz 2>/dev/null || echo "  (no latest symlink)"
    echo ""
    echo "Backup contents (file count):"
    tar tzf ~/btcspv_backup_latest.tar.gz 2>/dev/null | wc -l | xargs -I{} echo "  {} files in backup"
    tar tzf ~/btcspv_backup_latest.tar.gz 2>/dev/null | head -10

    echo ""
    echo "Normal daemon SPV status (if running):"
    ~/bathron-cli -testnet getbtcsyncstatus 2>&1 || echo "  (not available)"
' 2>/dev/null

echo ""
echo "=== Bootstrap log (last 30 lines) ==="
$SSH ubuntu@$SEED_IP 'tail -30 /tmp/genesis_bootstrap.log 2>/dev/null || echo "No bootstrap log"'

echo ""
echo "=== Normal daemon debug.log (BTC/SPV entries) ==="
$SSH ubuntu@$SEED_IP 'grep -i "btcspv\|BTC-SPV\|GENESIS.*EPOCH\|submitbtcheaders\|tip_height" ~/.bathron/testnet5/debug.log 2>/dev/null | tail -20 || echo "No debug log"'
