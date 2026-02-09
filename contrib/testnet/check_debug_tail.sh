#!/usr/bin/env bash
set -euo pipefail

CORESDK_IP="162.19.251.75"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "[$(date +%H:%M:%S)] Tailing debug.log (last 100 lines)"
echo ""

$SSH ubuntu@$CORESDK_IP 'tail -100 ~/.bathron/testnet5/debug.log'

echo ""
echo "[$(date +%H:%M:%S)] Debug log tail complete"
