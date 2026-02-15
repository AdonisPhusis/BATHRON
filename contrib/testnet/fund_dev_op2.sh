#!/bin/bash
# Send M0 from Seed (pilpous) to OP2 (dev) for LP registration
set -uo pipefail

SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

SEED_IP="57.131.33.151"
SEED_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
DEV_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"
AMOUNT="${1:-1000}"  # default 1000 sats

echo "=== Funding OP2 (dev) from Seed ==="
echo "  To: $DEV_ADDR"
echo "  Amount: $AMOUNT sats"
echo ""

RESULT=$($SSH ubuntu@$SEED_IP "$SEED_CLI sendmany '' '{\"$DEV_ADDR\":$AMOUNT}' 2>&1" 2>/dev/null)
echo "  Result: $RESULT"

if echo "$RESULT" | grep -qE '^[0-9a-f]{64}$'; then
    echo "  TX sent! Waiting for confirmation..."
    sleep 70
    CONFS=$($SSH ubuntu@$SEED_IP "$SEED_CLI getrawtransaction $RESULT true 2>/dev/null | jq -r '.confirmations // 0'" 2>/dev/null)
    echo "  Confirmations: $CONFS"
else
    echo "  ERROR: Send failed"
fi
