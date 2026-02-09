#!/bin/bash
# Redeploy HTLC3S contract to Base Sepolia

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
CORESDK_IP="162.19.251.75"
OP1_IP="57.131.33.152"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Redeploying HTLC3S Contract ==="

# Sync the deploy script
echo "Syncing deploy script..."
scp $SSH_OPTS "$PROJECT_ROOT/contrib/dex/pna-lp/scripts/deploy_htlc3s_fresh.py" \
    "ubuntu@$CORESDK_IP:~/pna-lp/scripts/"

# Ensure venv and dependencies
echo "Setting up Python environment..."
ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && \
    test -d venv || python3 -m venv venv && \
    source venv/bin/activate && \
    pip install -q web3 py-solc-x eth-account"

# Run deployment
echo "Running deployment..."
RESULT=$(ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd ~/pna-lp && source venv/bin/activate && python3 scripts/deploy_htlc3s_fresh.py")

echo ""
echo "Result: $RESULT"

# Extract address
ADDRESS=$(echo "$RESULT" | grep -oP '"address":\s*"\K[^"]+')

if [[ -n "$ADDRESS" ]]; then
    echo ""
    echo "=== Updating Configuration ==="
    echo "New contract address: $ADDRESS"

    # Update evm_3s.py
    echo "Updating SDK..."
    sed -i "s/HTLC3S_CONTRACT_ADDRESS = .*/HTLC3S_CONTRACT_ADDRESS = \"$ADDRESS\"/" \
        "$PROJECT_ROOT/contrib/dex/pna-lp/sdk/htlc/evm_3s.py"

    # Update E2E test
    echo "Updating E2E test..."
    sed -i "s/HTLC3S_CONTRACT=.*/HTLC3S_CONTRACT=\"$ADDRESS\"/" \
        "$PROJECT_ROOT/contrib/testnet/e2e_flowswap_3secrets.sh"

    # Sync SDK to CoreSDK
    echo "Syncing SDK to CoreSDK..."
    rsync -az --quiet \
        -e "ssh $SSH_OPTS" \
        "$PROJECT_ROOT/contrib/dex/pna-lp/sdk/" \
        "ubuntu@$CORESDK_IP:~/pna-lp/sdk/"

    # Update OP1 config
    TX_HASH=$(echo "$RESULT" | grep -oP '"tx_hash":\s*"\K[^"]+')
    echo "Updating OP1 config..."
    ssh $SSH_OPTS "ubuntu@$OP1_IP" "cat > ~/.BathronKey/htlc3s.json << 'CFGEOF'
{
  \"htlc3s_address\": \"$ADDRESS\",
  \"chain_id\": 84532,
  \"rpc_url\": \"https://sepolia.base.org\",
  \"deployed_by\": \"Bob\",
  \"tx_hash\": \"$TX_HASH\",
  \"note\": \"Redeployed with correct source\"
}
CFGEOF"

    echo ""
    echo "=== Deployment Complete ==="
    echo "Contract: $ADDRESS"
    echo "TX: https://sepolia.basescan.org/tx/$TX_HASH"
else
    echo "ERROR: Failed to extract address from result"
    exit 1
fi
