#!/bin/bash
# Create EVM wallet for fake retail user
# Generates on OP1 (has python packages) then copies to OP3

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

echo "=== Creating EVM Wallet for Fake User ==="

# Generate on OP1 which has eth-account installed
WALLET_JSON=$(ssh -i $SSH_KEY ubuntu@$OP1_IP '
cd ~/pna-sdk && ./venv/bin/python3 << "PYEOF"
from eth_account import Account
import json

# Generate new wallet
acct = Account.create()

wallet_data = {
    "_description": "Fake User EVM Wallet - For USDC swaps on Base Sepolia",
    "network": "base_sepolia",
    "chain_id": 84532,
    "address": acct.address,
    "private_key": acct.key.hex()
}

print(json.dumps(wallet_data))
PYEOF
')

if [ -z "$WALLET_JSON" ]; then
    echo "ERROR: Failed to generate wallet"
    exit 1
fi

# Extract address for display
ADDRESS=$(echo "$WALLET_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['address'])")
PRIVKEY=$(echo "$WALLET_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['private_key'])")

echo ""
echo "============================================================"
echo "NEW EVM WALLET FOR FAKE USER (Base Sepolia)"
echo "============================================================"
echo "Address:     $ADDRESS"
echo "Private Key: $PRIVKEY"
echo "============================================================"

# Save to OP3
echo ""
echo "Saving to OP3 (~/.keys/user_evm.json)..."
ssh -i $SSH_KEY ubuntu@$OP3_IP "mkdir -p ~/.keys && cat > ~/.keys/user_evm.json && chmod 600 ~/.keys/user_evm.json" << EOF
$WALLET_JSON
EOF

echo "Done!"
echo ""
echo "FUND THIS WALLET:"
echo "1. ETH (gas): https://www.alchemy.com/faucets/base-sepolia"
echo "2. USDC: https://faucet.circle.com/ (select Base Sepolia)"
echo ""
echo "Address to fund: $ADDRESS"
