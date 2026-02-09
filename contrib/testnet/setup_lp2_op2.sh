#!/bin/bash
# =============================================================================
# setup_lp2_op2.sh - Setup LP2 infrastructure on OP2
#
# Installs: Bitcoin Core Signet + BTC wallet + EVM wallet + htlc3s config
# Target:   OP2 (57.131.33.214) - wallet "dev"
# =============================================================================

set -e

OP2_IP="57.131.33.214"
OP1_IP="57.131.33.152"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh $SSH_OPTS"
SCP="scp $SSH_OPTS"

BTC_VERSION="27.0"
BTC_TARBALL="bitcoin-${BTC_VERSION}-x86_64-linux-gnu.tar.gz"
BTC_URL="https://bitcoincore.org/bin/bitcoin-core-${BTC_VERSION}/${BTC_TARBALL}"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

# =============================================================================
# STATUS
# =============================================================================

check_status() {
    echo -e "\n${BLUE}=== LP2 (OP2) Status ===${NC}\n"

    log_info "Checking SSH connectivity..."
    if ! $SSH ubuntu@$OP2_IP "true" 2>/dev/null; then
        log_error "Cannot connect to OP2 ($OP2_IP)"
        return 1
    fi
    log_success "SSH OK"

    # BATHRON
    echo ""
    log_info "BATHRON daemon..."
    $SSH ubuntu@$OP2_IP '
        if pgrep -x bathrond > /dev/null; then
            CLI=~/bathron/bin/bathron-cli
            if [ ! -f "$CLI" ]; then CLI=~/BATHRON-Core/src/bathron-cli; fi
            echo "  bathrond: RUNNING"
            HEIGHT=$($CLI -testnet getblockcount 2>/dev/null || echo "N/A")
            echo "  Height: $HEIGHT"
            BAL=$($CLI -testnet getbalance 2>/dev/null || echo "N/A")
            echo "  M0 Balance: $BAL"
            M1=$($CLI -testnet getwalletstate true 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(\"m1_total\", \"N/A\"))" 2>/dev/null || echo "N/A")
            echo "  M1 Balance: $M1"
        else
            echo "  bathrond: NOT RUNNING"
        fi
    '

    # BTC Signet
    echo ""
    log_info "Bitcoin Signet..."
    $SSH ubuntu@$OP2_IP '
        BTC_BIN=~/bitcoin/bin
        BTC_DIR=~/.bitcoin-signet
        CLI="$BTC_BIN/bitcoin-cli -signet -datadir=$BTC_DIR"
        if [ ! -f "$BTC_BIN/bitcoind" ]; then
            echo "  Bitcoin Core: NOT INSTALLED"
        elif pgrep -x bitcoind > /dev/null; then
            echo "  bitcoind: RUNNING"
            $CLI getblockchaininfo 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"  Chain: {d[\"chain\"]}\")
print(f\"  Blocks: {d[\"blocks\"]}\")
print(f\"  Headers: {d[\"headers\"]}\")
sync = d[\"blocks\"] / d[\"headers\"] * 100 if d[\"headers\"] > 0 else 0
print(f\"  Sync: {sync:.1f}%\")
" 2>/dev/null || echo "  RPC not ready"
            # Wallet balance
            $CLI -rpcwallet=lp2_wallet getbalance 2>/dev/null && echo "" || echo "  Wallet: not loaded"
        else
            echo "  bitcoind: INSTALLED but NOT RUNNING"
        fi
    '

    # EVM wallet
    echo ""
    log_info "EVM wallet..."
    $SSH ubuntu@$OP2_IP '
        if [ -f ~/.BathronKey/evm.json ]; then
            ADDR=$(python3 -c "import json; print(json.load(open(\"$HOME/.BathronKey/evm.json\"))[\"address\"])" 2>/dev/null)
            echo "  EVM Address: $ADDR"
        else
            echo "  EVM wallet: NOT CONFIGURED"
        fi
    '

    # Keys
    echo ""
    log_info "Key files..."
    $SSH ubuntu@$OP2_IP '
        for f in wallet.json btc.json evm.json htlc3s.json; do
            if [ -f ~/.BathronKey/$f ]; then
                echo "  ~/.BathronKey/$f: EXISTS"
            else
                echo "  ~/.BathronKey/$f: MISSING"
            fi
        done
    '

    # pna-lp server
    echo ""
    log_info "pna-lp server..."
    if curl -s --connect-timeout 3 "http://$OP2_IP:8080/api/status" | python3 -m json.tool 2>/dev/null; then
        echo -e "\n  ${GREEN}Server is running${NC}"
    else
        echo -e "  ${YELLOW}Server not running${NC}"
    fi

    echo ""
}

# =============================================================================
# INSTALL BTC SIGNET
# =============================================================================

install_btc() {
    log_info "Installing Bitcoin Core $BTC_VERSION on OP2..."

    $SSH ubuntu@$OP2_IP "
        set -e
        BTC_BIN=~/bitcoin/bin

        if [ -f \"\$BTC_BIN/bitcoind\" ]; then
            echo 'Bitcoin Core already installed'
            \$BTC_BIN/bitcoind --version | head -1
        else
            echo 'Downloading Bitcoin Core ${BTC_VERSION}...'
            cd /tmp
            wget -q --show-progress '${BTC_URL}' -O '${BTC_TARBALL}'
            echo 'Extracting...'
            tar xzf '${BTC_TARBALL}'
            mkdir -p ~/bitcoin/bin
            cp bitcoin-${BTC_VERSION}/bin/bitcoind ~/bitcoin/bin/
            cp bitcoin-${BTC_VERSION}/bin/bitcoin-cli ~/bitcoin/bin/
            chmod +x ~/bitcoin/bin/*
            rm -rf bitcoin-${BTC_VERSION} '${BTC_TARBALL}'
            echo 'Installed:'
            ~/bitcoin/bin/bitcoind --version | head -1
        fi
    "
    log_success "Bitcoin Core installed"
}

# =============================================================================
# CONFIGURE + START BTC SIGNET
# =============================================================================

setup_btc() {
    log_info "Configuring Bitcoin Signet on OP2..."

    $SSH ubuntu@$OP2_IP '
        set -e
        BTC_DIR=~/.bitcoin-signet
        BTC_BIN=~/bitcoin/bin
        CLI="$BTC_BIN/bitcoin-cli -signet -datadir=$BTC_DIR"

        # Create data dir + config
        mkdir -p $BTC_DIR
        if [ ! -f "$BTC_DIR/bitcoin.conf" ]; then
            cat > $BTC_DIR/bitcoin.conf << CONF
signet=1
server=1
txindex=1
[signet]
rpcuser=btcuser
rpcpassword=btcpass123
rpcallowip=127.0.0.1
CONF
            echo "Created bitcoin.conf"
        else
            echo "bitcoin.conf already exists"
        fi

        # Start bitcoind
        if pgrep -x bitcoind > /dev/null; then
            echo "bitcoind already running"
        else
            echo "Starting bitcoind..."
            $BTC_BIN/bitcoind -signet -datadir=$BTC_DIR -daemon
            echo "Started, waiting for RPC..."
        fi

        # Wait for RPC
        for i in $(seq 1 30); do
            if $CLI getblockchaininfo > /dev/null 2>&1; then
                echo "RPC ready"
                break
            fi
            echo "  Waiting... ($i/30)"
            sleep 2
        done

        # Show sync status
        $CLI getblockchaininfo | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f\"Chain: {d[chr(39)+chr(39) if False else \"chain\"]}\")
blocks = d[\"blocks\"]
headers = d[\"headers\"]
sync = blocks / headers * 100 if headers > 0 else 0
print(f\"Blocks: {blocks}/{headers} ({sync:.1f}%)\")
"
    '
    log_success "Bitcoin Signet configured and started"
}

# =============================================================================
# CREATE BTC WALLET
# =============================================================================

create_btc_wallet() {
    log_info "Creating BTC wallet lp2_wallet on OP2..."

    $SSH ubuntu@$OP2_IP 'set -e
BTC_BIN="$HOME/bitcoin/bin"
BTC_DIR="$HOME/.bitcoin-signet"
CLI="$BTC_BIN/bitcoin-cli -signet -datadir=$BTC_DIR"

# Create wallet (ignore if exists), then ensure loaded
$CLI createwallet "lp2_wallet" 2>/dev/null && echo "Wallet created" || true
$CLI loadwallet "lp2_wallet" 2>/dev/null && echo "Wallet loaded" || true

# Verify wallet is accessible
$CLI -rpcwallet=lp2_wallet getwalletinfo > /dev/null 2>&1 || { echo "ERROR: Cannot access lp2_wallet"; exit 1; }
echo "Wallet ready"

# Generate address
ADDR=$($CLI -rpcwallet=lp2_wallet getnewaddress "lp_deposit" "bech32")
echo "Address: $ADDR"

# Get pubkey
INFO=$($CLI -rpcwallet=lp2_wallet getaddressinfo "$ADDR")
PUBKEY=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)[\"pubkey\"])")
echo "Pubkey: $PUBKEY"

# Save to BathronKey
mkdir -p $HOME/.BathronKey
cat > $HOME/.BathronKey/btc.json << BTCJSON
{
  "name": "dev_btc",
  "role": "liquidity_provider_2",
  "network": "signet",
  "address": "$ADDR",
  "pubkey": "$PUBKEY",
  "wallet": "lp2_wallet"
}
BTCJSON
chmod 600 $HOME/.BathronKey/btc.json
echo "Saved ~/.BathronKey/btc.json"
cat $HOME/.BathronKey/btc.json'
    log_success "BTC wallet created"
}

# =============================================================================
# CREATE EVM WALLET
# =============================================================================

create_evm_wallet() {
    log_info "Generating EVM wallet for LP2..."

    # Check if already exists on OP2
    EXISTING=$($SSH ubuntu@$OP2_IP 'cat $HOME/.BathronKey/evm.json 2>/dev/null || echo ""')
    if [ -n "$EXISTING" ] && echo "$EXISTING" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        ADDR=$(echo "$EXISTING" | python3 -c "import sys,json; print(json.load(sys.stdin)['address'])")
        log_info "EVM wallet already exists: $ADDR"
        return 0
    fi

    # Generate locally using any available Python with eth-account
    log_info "Generating EVM key locally..."
    local PYBIN=""
    # Try known venv locations
    for candidate in \
        "/tmp/claude-evm-gen/bin/python" \
        "$HOME/BATHRON/contrib/dex/pna-lp/venv/bin/python" \
        "python3"; do
        if $candidate -c "from eth_account import Account" 2>/dev/null; then
            PYBIN="$candidate"
            break
        fi
    done

    if [ -z "$PYBIN" ]; then
        log_info "Installing eth-account in temp venv..."
        python3 -m venv /tmp/claude-evm-gen
        /tmp/claude-evm-gen/bin/pip install -q eth-account
        PYBIN="/tmp/claude-evm-gen/bin/python"
    fi

    EVM_JSON=$($PYBIN -c "
from eth_account import Account
import json
acct = Account.create()
wallet = {
    'name': 'dev_evm',
    'role': 'liquidity_provider_2',
    'network': 'base_sepolia',
    'address': acct.address,
    'private_key': '0x' + acct.key.hex()
}
print(json.dumps(wallet, indent=2))
")

    if [ -z "$EVM_JSON" ]; then
        log_error "Failed to generate EVM wallet"
        return 1
    fi

    ADDR=$(echo "$EVM_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['address'])")
    log_info "Generated EVM address: $ADDR"

    # Upload to OP2
    echo "$EVM_JSON" | $SSH ubuntu@$OP2_IP 'cat > $HOME/.BathronKey/evm.json && chmod 600 $HOME/.BathronKey/evm.json'
    log_success "EVM wallet created and uploaded to OP2"
}

# =============================================================================
# COPY HTLC3S CONFIG FROM OP1
# =============================================================================

copy_htlc3s() {
    log_info "Copying htlc3s.json from OP1 to OP2..."

    # Download from OP1 to local /tmp
    $SCP ubuntu@$OP1_IP:~/.BathronKey/htlc3s.json /tmp/htlc3s_lp2.json 2>/dev/null || {
        log_warn "htlc3s.json not found on OP1, skipping"
        return 0
    }

    # Upload to OP2
    $SCP /tmp/htlc3s_lp2.json ubuntu@$OP2_IP:~/.BathronKey/htlc3s.json
    $SSH ubuntu@$OP2_IP 'chmod 600 ~/.BathronKey/htlc3s.json'
    rm -f /tmp/htlc3s_lp2.json

    log_success "htlc3s.json copied"
}

# =============================================================================
# UPDATE WALLET ROLE
# =============================================================================

update_wallet_role() {
    log_info "Updating wallet.json role on OP2..."

    $SSH ubuntu@$OP2_IP 'python3 -c "
import json, os
path = os.path.expanduser(chr(126) + chr(47) + \".BathronKey/wallet.json\")
with open(path) as f:
    w = json.load(f)
if w.get(\"role\") == \"liquidity_provider_2\":
    print(\"Role already set: \" + w[\"role\"])
else:
    old = w.get(\"role\", \"unknown\")
    w[\"role\"] = \"liquidity_provider_2\"
    with open(path, \"w\") as f:
        json.dump(w, f, indent=2)
    print(\"Updated role: \" + old + \" -> liquidity_provider_2\")
"'
    log_success "Wallet role updated"
}

# =============================================================================
# FULL SETUP
# =============================================================================

full_setup() {
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}  LP2 Setup on OP2 ($OP2_IP)${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""

    # Pre-check SSH
    log_info "Checking SSH connectivity to OP2..."
    if ! $SSH ubuntu@$OP2_IP "true" 2>/dev/null; then
        log_error "Cannot connect to OP2 ($OP2_IP)"
        exit 1
    fi
    log_success "SSH OK"

    echo ""
    install_btc
    echo ""
    setup_btc
    echo ""
    create_btc_wallet
    echo ""
    create_evm_wallet
    echo ""
    copy_htlc3s
    echo ""
    update_wallet_role

    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  LP2 Setup Complete!${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""

    # Get addresses for funding instructions
    BTC_ADDR=$($SSH ubuntu@$OP2_IP 'python3 -c "import json; print(json.load(open(\"$HOME/.BathronKey/btc.json\".replace(\"$HOME\", __import__(\"os\").path.expanduser(\"~\"))))[\"address\"])"' 2>/dev/null || echo "CHECK ~/.BathronKey/btc.json")
    EVM_ADDR=$($SSH ubuntu@$OP2_IP 'python3 -c "import json; print(json.load(open(\"$HOME/.BathronKey/evm.json\".replace(\"$HOME\", __import__(\"os\").path.expanduser(\"~\"))))[\"address\"])"' 2>/dev/null || echo "CHECK ~/.BathronKey/evm.json")
    M1_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"

    echo -e "${YELLOW}NEXT STEPS - Fund these addresses:${NC}"
    echo ""
    echo "  1. BTC Signet (for LP inventory):"
    echo "     Address: $BTC_ADDR"
    echo "     Faucet:  https://signetfaucet.com"
    echo ""
    echo "  2. Base Sepolia ETH (for gas):"
    echo "     Address: $EVM_ADDR"
    echo "     Faucet:  https://www.alchemy.com/faucets/base-sepolia"
    echo ""
    echo "  3. Base Sepolia USDC (for LP inventory):"
    echo "     Address: $EVM_ADDR"
    echo "     Faucet:  https://faucet.circle.com/ (select Base Sepolia)"
    echo ""
    echo "  4. M0 BATHRON (send from Seed/OP1, then lock -> M1):"
    echo "     Address: $M1_ADDR"
    echo "     From OP1: ~/bathron/bin/bathron-cli -testnet sendtoaddress $M1_ADDR 10000"
    echo "     Then on OP2: ~/bathron/bin/bathron-cli -testnet lock 5000"
    echo ""
    echo "  5. Deploy pna-lp:"
    echo "     ./contrib/testnet/deploy_pna_lp.sh deploy lp2"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

case "${1:-setup}" in
    setup)    full_setup ;;
    status)   check_status ;;
    btc)      install_btc && setup_btc && create_btc_wallet ;;
    evm)      create_evm_wallet ;;
    htlc3s)   copy_htlc3s ;;
    wallet)   update_wallet_role ;;
    *)
        echo "Usage: $0 {setup|status|btc|evm|htlc3s|wallet}"
        echo ""
        echo "  setup   - Full LP2 setup (BTC + EVM + htlc3s + wallet)"
        echo "  status  - Check LP2 status"
        echo "  btc     - Install + setup BTC Signet only"
        echo "  evm     - Generate EVM wallet only"
        echo "  htlc3s  - Copy htlc3s.json from OP1 only"
        echo "  wallet  - Update wallet.json role only"
        exit 1
        ;;
esac
