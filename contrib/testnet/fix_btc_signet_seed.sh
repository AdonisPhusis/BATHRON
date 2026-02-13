#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

ssh_run() {
    timeout 20 ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@"$SEED_IP" "$@" 2>&1
}

echo "=== BTC Signet Seed Diagnostic & Fix ==="
echo

# Step 1: Check bitcoind binary
echo -e "${YELLOW}[1/7]${NC} Checking bitcoind binary..."
if ssh_run '[ -f ~/bitcoin-27.0/bin/bitcoind ] && [ -x ~/bitcoin-27.0/bin/bitcoind ]' >/dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Binary exists and is executable"
else
    echo -e "${RED}✗${NC} Binary missing or not executable"
    exit 1
fi

# Step 2: Check bitcoin.conf
echo -e "${YELLOW}[2/7]${NC} Checking bitcoin.conf..."
CONFIG_CHECK=$(ssh_run 'cat ~/.bitcoin-signet/bitcoin.conf 2>/dev/null || echo "MISSING"')
if [ "$CONFIG_CHECK" = "MISSING" ]; then
    echo -e "${RED}✗${NC} bitcoin.conf not found"
    exit 1
else
    echo -e "${GREEN}✓${NC} bitcoin.conf exists"
    # Check if datadir is specified
    if echo "$CONFIG_CHECK" | grep -q "^datadir="; then
        echo -e "${YELLOW}!${NC} Config has datadir directive (potential issue)"
    fi
fi

# Step 3: Clean up lock and processes
echo -e "${YELLOW}[3/7]${NC} Cleaning up lock files and processes..."
CLEANUP_RESULT=$(ssh_run 'bash -s' << 'REMOTE_SCRIPT'
rm -f ~/.bitcoin-signet/signet/.lock 2>/dev/null
pkill -9 -f "bitcoind.*signet" 2>/dev/null || true
sleep 2
if pgrep -f "bitcoind.*signet" >/dev/null 2>&1; then
    echo "CLEANUP_FAILED"
else
    echo "CLEANUP_OK"
fi
REMOTE_SCRIPT
)

if [ "$CLEANUP_RESULT" = "CLEANUP_OK" ]; then
    echo -e "${GREEN}✓${NC} Cleanup successful"
else
    echo -e "${RED}✗${NC} Failed to clean up processes"
    exit 1
fi

# Step 4: Check recent debug.log
echo -e "${YELLOW}[4/7]${NC} Checking recent debug.log..."
DEBUG_LOG=$(ssh_run 'tail -10 ~/.bitcoin-signet/signet/debug.log 2>/dev/null || echo "NO_LOG"')
if [ "$DEBUG_LOG" != "NO_LOG" ]; then
    echo "Last shutdown info:"
    echo "$DEBUG_LOG" | grep -E "Shutdown|error" | tail -5 | sed 's/^/  /'
else
    echo -e "${YELLOW}!${NC} No debug.log found"
fi

# Step 5: Start bitcoind with ABSOLUTE PATH to config
echo -e "${YELLOW}[5/7]${NC} Starting bitcoind..."
START_RESULT=$(ssh_run 'bash -s' << 'REMOTE_SCRIPT'
# Use absolute path to config
CONF_PATH="$HOME/.bitcoin-signet/bitcoin.conf"
~/bitcoin-27.0/bin/bitcoind -conf="$CONF_PATH" -daemon 2>&1
START_EXIT=$?
sleep 3

if [ $START_EXIT -eq 0 ] && pgrep -f "bitcoind.*signet" >/dev/null 2>&1; then
    echo "START_OK"
else
    echo "START_FAILED"
    tail -5 ~/.bitcoin-signet/signet/debug.log 2>/dev/null || echo "(no log)"
fi
REMOTE_SCRIPT
)

if echo "$START_RESULT" | grep -q "START_OK"; then
    echo -e "${GREEN}✓${NC} bitcoind started"
else
    echo -e "${RED}✗${NC} Failed to start:"
    echo "$START_RESULT" | sed 's/^/  /'
    exit 1
fi

# Step 6: Wait for RPC to respond
echo -e "${YELLOW}[6/7]${NC} Waiting for RPC (up to 60s)..."
ONLINE=false
for i in {1..12}; do
    RPC_CHECK=$(ssh_run 'CONF="$HOME/.bitcoin-signet/bitcoin.conf"; ~/bitcoin-27.0/bin/bitcoin-cli -conf="$CONF" getblockchaininfo 2>&1 || echo "RPC_DOWN"')
    if ! echo "$RPC_CHECK" | grep -q "RPC_DOWN\|error\|Could not connect"; then
        ONLINE=true
        echo -e "${GREEN}✓${NC} RPC online (after $((i*5))s)"
        break
    fi
    echo -n "."
    sleep 5
done
echo

# Step 7: Final status
echo -e "${YELLOW}[7/7]${NC} Final status..."
if [ "$ONLINE" = true ]; then
    CHAININFO=$(ssh_run 'CONF="$HOME/.bitcoin-signet/bitcoin.conf"; ~/bitcoin-27.0/bin/bitcoin-cli -conf="$CONF" getblockchaininfo 2>&1')
    PEERS=$(ssh_run 'CONF="$HOME/.bitcoin-signet/bitcoin.conf"; ~/bitcoin-27.0/bin/bitcoin-cli -conf="$CONF" getconnectioncount 2>&1')
    
    echo -e "${GREEN}SUCCESS${NC}: BTC Signet node is running"
    echo
    echo "Status:"
    BLOCKS=$(echo "$CHAININFO" | grep '"blocks":' | grep -o '[0-9]*' | head -1)
    HEADERS=$(echo "$CHAININFO" | grep '"headers":' | grep -o '[0-9]*' | head -1)
    echo "  Blocks: $BLOCKS"
    echo "  Headers: $HEADERS"
    echo "  Peers: $PEERS"
    
    if [ -n "$BLOCKS" ] && [ -n "$HEADERS" ]; then
        if [ "$BLOCKS" -lt "$HEADERS" ]; then
            DIFF=$((HEADERS - BLOCKS))
            echo -e "  ${YELLOW}Status: Syncing ($DIFF blocks behind)${NC}"
        else
            echo -e "  ${GREEN}Status: Synced${NC}"
        fi
    fi
else
    echo -e "${RED}FAILED${NC}: RPC did not come online"
    echo
    echo "Recent debug.log:"
    ssh_run 'tail -20 ~/.bitcoin-signet/signet/debug.log 2>/dev/null' | sed 's/^/  /'
    exit 1
fi

echo
echo "=== Complete ==="
