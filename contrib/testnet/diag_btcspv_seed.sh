#!/bin/bash
# Diagnostic: check btcspv state on Seed
SSH="ssh -i ~/.ssh/id_ed25519_vps -o ConnectTimeout=10 -o StrictHostKeyChecking=no"
SEED_IP=57.131.33.151

echo "=== btcspv directory ==="
$SSH ubuntu@$SEED_IP 'ls -la ~/.bathron/testnet5/btcspv/ 2>/dev/null | head -30 || echo "btcspv dir missing"'

echo ""
echo "=== btcspv backup ==="
$SSH ubuntu@$SEED_IP 'ls -la ~/btcspv_backup_*.tar.gz 2>/dev/null || echo "no backups"'

echo ""
echo "=== daemon running? ==="
$SSH ubuntu@$SEED_IP 'pgrep -u ubuntu bathrond >/dev/null 2>&1 && echo "YES" || echo "NO"'

echo ""
echo "=== debug.log BTC-SPV entries (last 50) ==="
$SSH ubuntu@$SEED_IP 'grep "BTC-SPV" ~/.bathron/testnet5/debug.log 2>/dev/null | tail -50 || echo "no debug.log or no BTC-SPV entries"'

echo ""
echo "=== debug.log CRITICAL/FAIL/Refusing entries ==="
$SSH ubuntu@$SEED_IP 'grep -iE "CRITICAL|FAIL|Refusing|CHECKPOINT|retarget" ~/.bathron/testnet5/debug.log 2>/dev/null | tail -30 || echo "none found"'
