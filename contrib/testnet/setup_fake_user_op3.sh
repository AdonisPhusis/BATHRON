#!/bin/bash
# =============================================================================
# setup_fake_user_op3.sh - Configure OP3 as "Fake Retail User" for swap tests
# =============================================================================
#
# OP3 (51.75.31.44) simule un utilisateur retail qui:
# - A du BTC sur Signet
# - Veut échanger BTC contre M1 (ou autre)
# - Utilise l'interface P&A Swap
#
# =============================================================================

set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# SSH config
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
SCP="scp -i $SSH_KEY $SSH_OPTS"

# OP3 = Fake User
OP3_IP="51.75.31.44"
BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

# BTC Signet config
BTC_VERSION="27.0"
BTC_URL="https://bitcoincore.org/bin/bitcoin-core-${BTC_VERSION}/bitcoin-${BTC_VERSION}-x86_64-linux-gnu.tar.gz"

install_btc_signet() {
    log_step "Installing BTC Signet on OP3"

    $SSH ubuntu@$OP3_IP "
        # Check if already installed
        if [ -x ~/bitcoin/bin/bitcoind ]; then
            echo 'Bitcoin already installed'
            ~/bitcoin/bin/bitcoind --version | head -1
        else
            echo 'Downloading Bitcoin Core $BTC_VERSION...'
            cd ~
            wget -q '$BTC_URL' -O bitcoin.tar.gz
            tar xzf bitcoin.tar.gz
            mv bitcoin-$BTC_VERSION bitcoin
            rm bitcoin.tar.gz
            echo 'Bitcoin installed'
        fi

        # Create config
        mkdir -p /home/ubuntu/.bitcoin-signet
        cat > /home/ubuntu/.bitcoin-signet/bitcoin.conf << 'EOF'
# Signet config for Fake User
signet=1
server=1
txindex=0
rpcuser=fakeuser
rpcpassword=fakepass123

# Wallet - don't auto-load, create manually
# wallet=fake_user

# Network
listen=0
maxconnections=8

# Prune to save space (550MB minimum)
prune=550
EOF

        echo 'Config created'
    "

    log_ok "BTC Signet installed on OP3"
}

start_btc_signet() {
    log_step "Starting BTC Signet on OP3"

    $SSH ubuntu@$OP3_IP '
        BTC=/home/ubuntu/bitcoin/bin
        DATADIR=/home/ubuntu/.bitcoin-signet

        # Check if BTC Signet process running (not bathrond!)
        PID=$(pgrep -f "bitcoin.*signet" | head -1)
        if [ -n "$PID" ]; then
            echo "BTC Signet already running (PID: $PID)"
            $BTC/bitcoin-cli -signet -datadir=$DATADIR getblockcount 2>/dev/null || echo "(syncing...)"
        else
            echo "Starting BTC Signet daemon..."

            # Start daemon
            $BTC/bitcoind -signet -datadir=$DATADIR -daemon 2>&1

            echo "Waiting for startup..."
            sleep 15

            # Wait for RPC to be ready
            for i in {1..30}; do
                RESULT=$($BTC/bitcoin-cli -signet -datadir=$DATADIR getblockchaininfo 2>&1)
                if echo "$RESULT" | grep -q "blocks"; then
                    echo "RPC ready!"
                    echo "$RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"  Blocks: {d.get(\"blocks\",0)}/{d.get(\"headers\",0)}\")
"
                    break
                fi
                echo "Waiting for RPC... ($i/30)"
                sleep 3
            done

            # Create wallet if not exists
            echo "Creating wallet..."
            $BTC/bitcoin-cli -signet -datadir=$DATADIR createwallet "fake_user" false false "" false false 2>&1 || true
            $BTC/bitcoin-cli -signet -datadir=$DATADIR loadwallet "fake_user" 2>&1 || true

            echo "BTC Signet started"
        fi
    '

    log_ok "BTC Signet running on OP3"
}

stop_btc_signet() {
    log_step "Stopping BTC Signet on OP3"

    $SSH ubuntu@$OP3_IP '
        BTC=/home/ubuntu/bitcoin/bin
        DATADIR=/home/ubuntu/.bitcoin-signet

        # Try graceful stop
        $BTC/bitcoin-cli -signet -datadir=$DATADIR stop 2>/dev/null || true

        # Force kill if still running
        sleep 2
        if pgrep -f "bitcoind.*signet" > /dev/null; then
            echo "Force killing..."
            pkill -9 -f "bitcoind.*signet" || true
        fi

        echo "Stopped"
    '

    log_ok "BTC Signet stopped"
}

check_status() {
    log_step "Checking OP3 (Fake User) Status"

    $SSH ubuntu@$OP3_IP '
        CLI=/home/ubuntu/bathron-cli
        BTC=/home/ubuntu/bitcoin/bin
        DATADIR=/home/ubuntu/.bitcoin-signet

        echo "=== BATHRON Status ==="
        $CLI -testnet getblockcount 2>/dev/null && echo "BATHRON: OK" || echo "BATHRON: ERROR"

        echo ""
        echo "=== BATHRON Wallet ==="
        $CLI -testnet getbalance 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"  M0: {d.get(\"m0\",0)}\")
print(f\"  M1: {d.get(\"m1\",0)}\")
" 2>/dev/null || echo "  No balance"

        echo ""
        echo "=== BTC Signet Status ==="
        if pgrep -f "bitcoind.*signet" > /dev/null; then
            INFO=$($BTC/bitcoin-cli -signet -datadir=$DATADIR getblockchaininfo 2>/dev/null)
            if [ -n "$INFO" ]; then
                echo "$INFO" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"  Chain: {d.get(\"chain\",\"?\")}\")
print(f\"  Blocks: {d.get(\"blocks\",0)}/{d.get(\"headers\",0)}\")
print(f\"  Progress: {d.get(\"verificationprogress\",0)*100:.1f}%\")
"
                BALANCE=$($BTC/bitcoin-cli -signet -datadir=$DATADIR getbalance 2>/dev/null || echo "0")
                echo "  Balance: $BALANCE BTC"
            else
                echo "  RPC not ready (syncing initial blocks...)"
            fi
        else
            echo "  BTC Signet: NOT RUNNING"
            echo "  Run: ./setup_fake_user_op3.sh start-btc"
        fi
    '
}

get_btc_address() {
    log_step "Getting BTC deposit address for Fake User"

    $SSH ubuntu@$OP3_IP '
        BTC=/home/ubuntu/bitcoin/bin
        DATADIR=/home/ubuntu/.bitcoin-signet

        ADDR=$($BTC/bitcoin-cli -signet -datadir=$DATADIR getnewaddress "faucet_deposit" "bech32" 2>/dev/null)

        if [ -n "$ADDR" ]; then
            echo ""
            echo "========================================"
            echo "  FAKE USER BTC DEPOSIT ADDRESS"
            echo "========================================"
            echo ""
            echo "  $ADDR"
            echo ""
            echo "  Get testnet BTC from:"
            echo "    https://signetfaucet.com"
            echo "    https://alt.signetfaucet.com"
            echo "========================================"
        else
            echo "ERROR: Could not get address. BTC Signet may still be syncing."
            echo "Run: ./setup_fake_user_op3.sh status"
        fi
    '
}

import_bathron_keys() {
    log_step "Importing BATHRON test keys on OP3"

    # Use a dedicated test user for fake user
    FAKE_USER_WIF="cPtPSZLkcufXMryYoCTr63zkPDGPtYWxbZ24NGBWzDfzJUuZaEbE"  # charlie
    FAKE_USER_ADDR="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"

    $SSH ubuntu@$OP3_IP "
        $BATHRON_CLI importprivkey '$FAKE_USER_WIF' 'fake_user' true 2>/dev/null || echo 'Key already imported'
        echo 'Fake user BATHRON address: $FAKE_USER_ADDR'
    "

    log_ok "BATHRON keys imported"
}

setup_auto_shutdown() {
    log_step "Setting up auto-shutdown for BTC Signet (if idle)"

    $SSH ubuntu@$OP3_IP "
        # Create shutdown script
        cat > ~/btc_auto_shutdown.sh << 'SCRIPT'
#!/bin/bash
# Auto-shutdown BTC Signet if idle for 2 hours
IDLE_FILE=/tmp/btc_last_activity
BTC_CLI=~/bitcoin/bin/bitcoin-cli

# Update activity timestamp on any RPC call
touch \$IDLE_FILE

# Check if idle
if [ -f \$IDLE_FILE ]; then
    LAST=\$(stat -c %Y \$IDLE_FILE)
    NOW=\$(date +%s)
    DIFF=\$((NOW - LAST))

    # 2 hours = 7200 seconds
    if [ \$DIFF -gt 7200 ]; then
        echo \"BTC Signet idle for 2h, stopping...\"
        \$BTC_CLI -signet -datadir=~/.bitcoin-signet stop 2>/dev/null
        rm -f \$IDLE_FILE
    fi
fi
SCRIPT
        chmod +x ~/btc_auto_shutdown.sh

        # Add cron job (check every 30 min)
        (crontab -l 2>/dev/null | grep -v btc_auto_shutdown; echo '*/30 * * * * ~/btc_auto_shutdown.sh') | crontab -

        echo 'Auto-shutdown configured (2h idle = stop)'
    "

    log_ok "Auto-shutdown configured"
}

full_setup() {
    install_btc_signet
    start_btc_signet
    import_bathron_keys
    setup_auto_shutdown
    check_status
    get_btc_address
}

case "${1:-help}" in
    install)
        install_btc_signet
        ;;
    start-btc)
        start_btc_signet
        ;;
    stop-btc)
        stop_btc_signet
        ;;
    status)
        check_status
        ;;
    address)
        get_btc_address
        ;;
    keys)
        import_bathron_keys
        ;;
    auto-shutdown)
        setup_auto_shutdown
        ;;
    setup|full)
        full_setup
        ;;
    *)
        echo "Usage: $0 {install|start-btc|stop-btc|status|address|keys|auto-shutdown|setup}"
        echo ""
        echo "Commands:"
        echo "  install       - Install BTC Signet on OP3"
        echo "  start-btc     - Start BTC Signet daemon"
        echo "  stop-btc      - Stop BTC Signet daemon"
        echo "  status        - Check full status"
        echo "  address       - Get BTC deposit address"
        echo "  keys          - Import BATHRON test keys"
        echo "  auto-shutdown - Setup auto-shutdown when idle"
        echo "  setup         - Full setup (all of the above)"
        echo ""
        echo "OP3 (51.75.31.44) = Fake Retail User for swap tests"
        ;;
esac
