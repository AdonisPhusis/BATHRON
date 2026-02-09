#!/bin/bash
# =============================================================================
# deploy_htlc3s_contract.sh - Deploy HTLC3S to Base Sepolia via OP1
# =============================================================================
# Syncs the deploy script to OP1 and executes it remotely.
# The EVM private key must exist on OP1 in ~/.BathronKey/evm.json

set -e

# Configuration
OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================================"
echo "Deploy HTLC3S Contract to Base Sepolia"
echo "============================================================"
echo ""

# Test SSH connection
log_info "Testing connection to OP1 ($OP1_IP)..."
if ! ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$OP1_IP "echo OK" >/dev/null 2>&1; then
    log_error "Cannot connect to OP1"
    exit 1
fi
log_success "Connected"

# Sync deploy script
log_info "Syncing deploy script..."
scp -i "$SSH_KEY" $SSH_OPTS \
    "$SCRIPT_DIR/deploy_htlc3s_op1.sh" \
    ubuntu@$OP1_IP:~/deploy_htlc3s.sh

ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$OP1_IP "chmod +x ~/deploy_htlc3s.sh"
log_success "Script synced"

# Check if EVM key exists
log_info "Checking EVM key on OP1..."
KEY_CHECK=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$OP1_IP '
    for f in ~/.BathronKey/evm.json ~/.evm_key; do
        if [ -f "$f" ]; then
            echo "FOUND:$f"
            exit 0
        fi
    done
    echo "NOT_FOUND"
')

if [[ "$KEY_CHECK" == "NOT_FOUND" ]]; then
    log_error "EVM key not found on OP1"
    echo ""
    echo "Please create ~/.BathronKey/evm.json on OP1 with format:"
    echo '{"private_key": "0x..."}'
    echo ""
    echo "Or create ~/.evm_key with just the private key"
    exit 1
fi
log_success "EVM key found: ${KEY_CHECK#FOUND:}"

# Check Python dependencies
log_info "Checking Python dependencies on OP1..."
DEP_CHECK=$(ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$OP1_IP '
    python3 -c "import web3, eth_account, solcx; print(\"OK\")" 2>/dev/null || echo "MISSING"
')

if [[ "$DEP_CHECK" == "MISSING" ]]; then
    log_info "Installing Python dependencies..."
    ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$OP1_IP '
        pip3 install --user web3 eth-account py-solc-x 2>/dev/null || \
        pip3 install web3 eth-account py-solc-x
    '
fi
log_success "Dependencies OK"

# Execute deployment
echo ""
log_info "Executing deployment on OP1..."
echo "============================================================"

# Get key and run
ssh -i "$SSH_KEY" $SSH_OPTS ubuntu@$OP1_IP '
    # Find and export key
    KEY_FILE=""
    for f in ~/.BathronKey/evm.json ~/.evm_key; do
        if [ -f "$f" ]; then
            KEY_FILE="$f"
            break
        fi
    done

    if [ -z "$KEY_FILE" ]; then
        echo "[ERROR] Key file not found"
        exit 1
    fi

    # Extract key
    if [[ "$KEY_FILE" == *.json ]]; then
        export PRIVATE_KEY=$(python3 -c "import json; d=json.load(open(\"$KEY_FILE\")); print(d.get(\"private_key\") or d.get(\"privateKey\"))" 2>/dev/null)
    else
        export PRIVATE_KEY=$(cat "$KEY_FILE" | tr -d "\n")
    fi

    if [ -z "$PRIVATE_KEY" ]; then
        echo "[ERROR] Could not extract private key"
        exit 1
    fi

    # Run deploy script
    ~/deploy_htlc3s.sh
'

STATUS=$?
echo "============================================================"

if [ $STATUS -eq 0 ]; then
    log_success "Deployment complete!"
    echo ""
    echo "Next steps:"
    echo "1. Copy the contract address from output above"
    echo "2. Update contrib/dex/pna-lp/sdk/htlc/evm_3s.py:"
    echo '   HTLC3S_CONTRACT_ADDRESS = "0x..."'
    echo ""
else
    log_error "Deployment failed"
    exit 1
fi
