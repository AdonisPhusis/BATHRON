#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30"
IP="${1:-162.19.251.75}"
$SSH ubuntu@$IP '~/bathron-cli -datadir=$HOME/.bathron -testnet getblockcount 2>/dev/null || echo "not_ready"'
