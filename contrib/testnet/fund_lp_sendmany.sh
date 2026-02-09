#!/bin/bash
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
BOB_ADDR="y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk"

echo "=== Fund LP wallets via sendmany ==="
echo ""

echo "Current balance:"
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI getbalance"

echo ""
echo "Available M0 (checking listunspent):"
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI listunspent" 2>&1 | head -50

echo ""
echo "=== Sending 100000 sats to Alice and Bob ==="
# Note: sendmany format is: sendmany "" {"addr":amount, ...}
# Amount is in BATH (1 BATH = 100000000 sats)

# Try 0.001 BATH = 100000 sats each
ssh $SSH_OPTS "ubuntu@$SEED_IP" bash << 'REMOTE'
/home/ubuntu/bathron-cli -testnet sendmany "" "{\"yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo\":0.001, \"y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk\":0.001}"
REMOTE

echo ""
echo "Done! Check balances on Alice and Bob."
