#!/bin/bash
# Check BTC Signet setup on OP1 and OP3

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

check_btc_node() {
    local IP=$1
    local NAME=$2

    echo "=== $NAME ($IP) BTC Signet ==="

    # Check if bitcoin-cli exists
    echo "1. Bitcoin CLI location:"
    ssh $SSH_OPTS ubuntu@$IP "ls -la ~/bitcoin/bin/bitcoin-cli 2>/dev/null || ls -la /usr/local/bin/bitcoin-cli 2>/dev/null || echo 'Not found'"

    # Check data directories
    echo ""
    echo "2. Data directories:"
    ssh $SSH_OPTS ubuntu@$IP "ls -la ~/.bitcoin-signet 2>/dev/null || ls -la ~/.bitcoin 2>/dev/null || echo 'No bitcoin data directory'"

    # Check if bitcoind is running
    echo ""
    echo "3. Running processes:"
    ssh $SSH_OPTS ubuntu@$IP "pgrep -a bitcoind 2>/dev/null || echo 'bitcoind not running'"

    # Try to get blockchain info
    echo ""
    echo "4. Blockchain info (if running):"
    ssh $SSH_OPTS ubuntu@$IP "bitcoin-cli -signet getblockchaininfo 2>/dev/null | head -10 || echo 'Cannot connect to bitcoind'"

    echo ""
    echo ""
}

check_btc_node "57.131.33.152" "OP1 (LP)"
check_btc_node "51.75.31.44" "OP3 (User)"
