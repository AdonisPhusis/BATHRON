#!/bin/bash
SSH_KEY="~/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
SEED_IP="57.131.33.151"
SEED_CLI="~/BATHRON-Core/src/bathron-cli -testnet"
$SSH ubuntu@$SEED_IP "$SEED_CLI getblockhash $1"
