#!/bin/bash
# Check LP server logs for BTC HTLC errors
OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== Checking LP server logs on OP1 ==="
ssh -i "$SSH_KEY" ubuntu@${OP1_IP} 'tail -100 /tmp/pna-lp.log | grep -A10 -B5 "BTC HTLC\|btc_htlc\|Failed to create"'
