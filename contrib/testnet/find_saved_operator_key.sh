#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"

echo "=== Searching for Saved Operator Key on Seed ==="
$SSH_CMD "find /tmp /home/ubuntu -name '*operator*' -o -name '*genesis*key*' 2>/dev/null | grep -v '.ssh\|.cache'"
