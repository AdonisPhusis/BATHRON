#!/bin/bash
set -e

# Script: Deploy and execute USDC HTLC creation on OP3
# Runs from dev machine
# Transfers swap details and script to OP3
# Executes remotely and reports results

OP3_IP="51.75.31.44"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== Deploying USDC HTLC Creation to OP3 ==="
echo ""

# Check swap details file exists locally
if [ ! -f /tmp/swap_details.json ]; then
    echo "ERROR: /tmp/swap_details.json not found"
    echo "This file should contain swap parameters"
    exit 1
fi

echo "Found swap details:"
cat /tmp/swap_details.json | jq '.'
echo ""

# Transfer swap details to OP3
echo "Transferring swap details to OP3..."
scp -i "$SSH_KEY" /tmp/swap_details.json ubuntu@${OP3_IP}:/tmp/

# Transfer script to OP3
echo "Transferring creation script to OP3..."
scp -i "$SSH_KEY" contrib/testnet/create_usdc_htlc_for_swap.sh ubuntu@${OP3_IP}:/tmp/

# Execute on OP3
echo ""
echo "Executing HTLC creation on OP3..."
echo "=========================================="
ssh -i "$SSH_KEY" ubuntu@${OP3_IP} 'bash /tmp/create_usdc_htlc_for_swap.sh'

echo ""
echo "=== Deployment Complete ==="
