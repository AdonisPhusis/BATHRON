#!/bin/bash
# Check htlc_create_m1 syntax

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # Alice (LP)
M1_CLI="\$HOME/bathron-cli -testnet"

echo "=== HTLC_CREATE_M1 SYNTAX ==="
echo ""

ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI help htlc_create_m1" 2>&1
echo ""

echo ""
echo "=== CONCLUSION ==="
echo "The step 2 command should have specified Charlie's claim_address!"
echo ""
echo "Current HTLC recipient: 8px7CVhtSg8RH5DKVsHYAfP8676CCoahjL (unknown wallet)"
echo "Should have been: Charlie's address (yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe)"
