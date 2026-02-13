#!/bin/bash
# inspect_block.sh - Inspect block contents

set -e

SSH_KEY="~/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

HEIGHT=$1
if [ -z "$HEIGHT" ]; then
    echo "Usage: $0 <height>"
    exit 1
fi

# Use CoreSDK as reference
IP="162.19.251.75"
CLI="~/bathron-cli -testnet"

echo "=== Block $HEIGHT Details ==="
echo ""

HASH=$($SSH ubuntu@$IP "$CLI getblockhash $HEIGHT")
echo "Hash: $HASH"
echo ""

echo "Block details:"
$SSH ubuntu@$IP "$CLI getblock $HASH 2" | head -100
