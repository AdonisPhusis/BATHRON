#!/bin/bash
# Deploy HTLC3S contract from OP1

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP1_IP="57.131.33.152"

echo "=== Copying deploy script to OP1 ==="
scp $SSH_OPTS /home/ubuntu/BATHRON/contrib/dex/pna-lp/scripts/deploy_htlc3s.py ubuntu@$OP1_IP:/tmp/deploy_htlc3s.py

echo ""
echo "=== Running deployment on OP1 ==="
ssh $SSH_OPTS ubuntu@$OP1_IP "
    # Install solcx if needed
    pip3 install py-solc-x --quiet 2>/dev/null || true
    
    # Run deployment
    python3 /tmp/deploy_htlc3s.py
"
