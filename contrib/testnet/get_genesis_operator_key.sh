#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"

echo "=== Retrieving Genesis Operator Key ===" 
$SSH_CMD "cat ~/.BathronKey/operators.json 2>/dev/null" || echo "File not found"
