#!/bin/bash
# Get BTC signet block hash at a given height from btcspv on Seed
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30"
SEED="57.131.33.151"
HEIGHT="${1:-286319}"

$SSH ubuntu@$SEED "~/bathron-cli -datadir=\$HOME/.bathron -testnet getbtcspvheader $HEIGHT 2>/dev/null || echo 'RPC not available'" 2>/dev/null
