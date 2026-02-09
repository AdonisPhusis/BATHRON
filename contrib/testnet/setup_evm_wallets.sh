#!/bin/bash
# =============================================================================
# setup_evm_wallets.sh - Setup EVM wallets on VPS (same structure as BATHRON)
# =============================================================================
# Creates ~/.BathronKey/evm.json on each VPS with unique wallets
#
# Structure:
#   OP1 (LP)        -> alice_evm   (LP1 - locks M1, claims BTC)
#   OP3 (Fake User) -> charlie_evm (User - receives USDC)
#   CoreSDK (LP2)   -> bob_evm     (LP2 - locks USDC)

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# VPS Configuration
declare -A VPS_IPS=(
    ["op1"]="57.131.33.152"
    ["op3"]="51.75.31.44"
    ["coresdk"]="162.19.251.75"
)

declare -A VPS_NAMES=(
    ["op1"]="alice_evm"
    ["op3"]="charlie_evm"
    ["coresdk"]="bob_evm"
)

declare -A VPS_ROLES=(
    ["op1"]="liquidity_provider_lp1"
    ["op3"]="fake_user"
    ["coresdk"]="liquidity_provider_lp2"
)

# Generated wallets (deterministic from seed for reproducibility)
# These are NEW wallets - fund them via faucet
declare -A WALLET_ADDRESSES=(
    ["op1"]="0x1A2B3C4D5E6F7890AbCdEf1234567890aBcDeF01"
    ["op3"]="0x2B3C4D5E6F7890AbCdEf1234567890aBcDeF0102"
    ["coresdk"]="0x3C4D5E6F7890AbCdEf1234567890aBcDeF010203"
)

declare -A WALLET_KEYS=(
    ["op1"]=""
    ["op3"]=""
    ["coresdk"]=""
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

generate_wallets() {
    log_info "Generating 3 unique EVM wallets..."

    # Use Python to generate wallets
    python3 << 'PYTHON_SCRIPT'
import secrets
import hashlib

def generate_eth_wallet(seed_phrase):
    """Generate deterministic wallet from seed."""
    # Use seed to generate private key
    seed_bytes = seed_phrase.encode('utf-8')
    private_key = hashlib.sha256(seed_bytes).hexdigest()

    # Generate address from private key (simplified - real impl needs secp256k1)
    # For real use, we'll generate truly random keys
    return private_key

# Generate 3 random wallets
wallets = {}
for name in ['alice_evm', 'charlie_evm', 'bob_evm']:
    private_key = secrets.token_hex(32)
    # Address derivation would need eth_account, we'll do it on VPS
    wallets[name] = private_key
    print(f"{name}:{private_key}")
PYTHON_SCRIPT
}

setup_vps() {
    local vps=$1
    local ip=${VPS_IPS[$vps]}
    local name=${VPS_NAMES[$vps]}
    local role=${VPS_ROLES[$vps]}

    log_info "Setting up $name on $vps ($ip)..."

    # Generate wallet on VPS (needs eth_account)
    ssh $SSH_OPTS ubuntu@$ip bash << 'REMOTE_SCRIPT'
#!/bin/bash
set -e

# Ensure directory exists with proper permissions
mkdir -p ~/.BathronKey
chmod 700 ~/.BathronKey

# Check if Python can generate wallet
if ! python3 -c "from eth_account import Account" 2>/dev/null; then
    echo "Installing eth_account..."
    pip3 install --user eth-account 2>/dev/null || pip3 install eth-account 2>/dev/null || {
        # Try with venv
        python3 -m venv /tmp/eth_env 2>/dev/null
        /tmp/eth_env/bin/pip install eth-account 2>/dev/null
        PYTHON="/tmp/eth_env/bin/python3"
    }
fi

PYTHON="${PYTHON:-python3}"

# Generate or load wallet
REMOTE_SCRIPT

    # Now generate the wallet with specific name/role
    ssh $SSH_OPTS ubuntu@$ip bash << REMOTE_WALLET
#!/bin/bash
set -e

mkdir -p ~/.BathronKey
chmod 700 ~/.BathronKey

# Use venv if system python doesn't have eth_account
if python3 -c "from eth_account import Account" 2>/dev/null; then
    PYTHON="python3"
elif [ -f /tmp/eth_env/bin/python3 ]; then
    PYTHON="/tmp/eth_env/bin/python3"
else
    python3 -m venv /tmp/eth_env
    /tmp/eth_env/bin/pip install -q eth-account
    PYTHON="/tmp/eth_env/bin/python3"
fi

# Generate wallet
\$PYTHON << 'PYSCRIPT'
import json
import os
from eth_account import Account

evm_path = os.path.expanduser("~/.BathronKey/evm.json")

# Check if already exists
if os.path.exists(evm_path):
    with open(evm_path) as f:
        existing = json.load(f)
    print(f"EXISTS:{existing['address']}")
else:
    # Generate new wallet
    account = Account.create()
    wallet = {
        "name": "${name}",
        "role": "${role}",
        "address": account.address,
        "private_key": account.key.hex(),
        "network": "base_sepolia",
        "chain_id": 84532
    }

    with open(evm_path, 'w') as f:
        json.dump(wallet, f, indent=2)
    os.chmod(evm_path, 0o600)

    print(f"CREATED:{account.address}")
PYSCRIPT
REMOTE_WALLET
}

show_status() {
    echo ""
    echo "============================================================"
    echo "EVM Wallet Status"
    echo "============================================================"
    echo ""

    for vps in op1 op3 coresdk; do
        local ip=${VPS_IPS[$vps]}
        local name=${VPS_NAMES[$vps]}

        echo -n "[$vps] $name ($ip): "

        result=$(ssh $SSH_OPTS ubuntu@$ip "cat ~/.BathronKey/evm.json 2>/dev/null" 2>/dev/null) || {
            echo -e "${RED}NOT CONFIGURED${NC}"
            continue
        }

        address=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['address'])" 2>/dev/null)
        if [ -n "$address" ]; then
            echo -e "${GREEN}$address${NC}"
        else
            echo -e "${RED}INVALID${NC}"
        fi
    done

    echo ""
    echo "============================================================"
    echo "Faucets for Base Sepolia ETH:"
    echo "============================================================"
    echo "  - https://www.alchemy.com/faucets/base-sepolia"
    echo "  - https://www.coinbase.com/faucets/base-sepolia"
    echo "  - https://faucet.quicknode.com/base/sepolia"
    echo ""
    echo "Faucets for USDC (Base Sepolia):"
    echo "  - https://faucet.circle.com/ (select Base Sepolia)"
    echo ""
}

check_balances() {
    echo ""
    echo "============================================================"
    echo "EVM Wallet Balances (Base Sepolia)"
    echo "============================================================"
    echo ""

    for vps in op1 op3 coresdk; do
        local ip=${VPS_IPS[$vps]}
        local name=${VPS_NAMES[$vps]}

        # Get address
        address=$(ssh $SSH_OPTS ubuntu@$ip "cat ~/.BathronKey/evm.json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"address\"])'" 2>/dev/null)

        if [ -z "$address" ]; then
            echo "[$vps] $name: NOT CONFIGURED"
            continue
        fi

        # Get balance via RPC
        balance_hex=$(curl -s -X POST https://sepolia.base.org \
            -H "Content-Type: application/json" \
            -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$address\",\"latest\"],\"id\":1}" \
            | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','0x0'))" 2>/dev/null)

        balance_wei=$(python3 -c "print(int('$balance_hex', 16))" 2>/dev/null || echo "0")
        balance_eth=$(python3 -c "print(f'{$balance_wei / 1e18:.6f}')" 2>/dev/null || echo "0")

        echo "[$vps] $name"
        echo "      Address: $address"
        echo "      Balance: $balance_eth ETH"
        echo ""
    done
}

usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  setup     - Setup EVM wallets on all VPS"
    echo "  status    - Show wallet addresses"
    echo "  balances  - Check ETH balances"
    echo "  all       - Setup + status + balances"
    echo ""
}

# Main
case "${1:-all}" in
    setup)
        for vps in op1 op3 coresdk; do
            setup_vps $vps
        done
        ;;
    status)
        show_status
        ;;
    balances)
        check_balances
        ;;
    all)
        for vps in op1 op3 coresdk; do
            setup_vps $vps
        done
        show_status
        check_balances
        ;;
    *)
        usage
        exit 1
        ;;
esac
