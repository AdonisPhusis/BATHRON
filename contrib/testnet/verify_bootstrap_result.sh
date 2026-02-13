#!/bin/bash
# Verify bootstrap result on Seed

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "════════════════════════════════════════════════════════════════"
echo "  Verify Bootstrap Result"
echo "════════════════════════════════════════════════════════════════"
echo ""

$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
DATADIR=/tmp/bathron_bootstrap/testnet5

echo "=== Bootstrap Files ==="
ls -lh /tmp/bathron_bootstrap/testnet5/blocks/*.dat 2>/dev/null | wc -l | xargs echo "Block files:"
ls -lh /tmp/bathron_bootstrap/testnet5/chainstate/*.ldb 2>/dev/null | wc -l | xargs echo "Chainstate files:"
ls -lh /tmp/bathron_bootstrap/testnet5/btcheadersdb/*.ldb 2>/dev/null | wc -l | xargs echo "BTC headers files:"

echo ""
echo "=== Check bootstrap log ==="
if [ -f /tmp/genesis_bootstrap.log ]; then
    # Look for summary at end
    tail -50 /tmp/genesis_bootstrap.log | grep -A20 "GENESIS BOOTSTRAP COMPLETE" || echo "No completion marker found"
else
    echo "No /tmp/genesis_bootstrap.log found"
fi

echo ""
echo "=== Check operator keys ==="
if [ -f ~/.BathronKey/operators.json ]; then
    echo "[OK] Operator keys exist"
    jq -r '.operator | "MN count: " + (.mn_count | tostring) + ", pubkey: " + .pubkey[:32] + "..."' ~/.BathronKey/operators.json
else
    echo "[ERROR] No operator keys found"
fi
REMOTE
