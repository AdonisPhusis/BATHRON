#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"

echo "=== Finding Genesis Operator Key ==="
echo ""

echo "Checking /tmp/bathron_bootstrap for operator key..."
$SSH_CMD "find /tmp/bathron_bootstrap -name 'operator*' -o -name '*.wif' 2>/dev/null"

echo ""
echo "Checking for genesis operator WIF in temp dir..."
$SSH_CMD "ls -la /tmp/bathron_bootstrap/ 2>/dev/null | grep -i operator"

echo ""
echo "Checking bootstrap debug log for operator key..."
$SSH_CMD "grep -i 'operator.*private\|wif\|cV\|cT\|cP\|cQ\|cR\|cS' /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null | tail -20"
