#!/bin/bash
#
# remote_burn.sh - Execute a BTC burn on the Seed node (where Bitcoin Signet runs)
#
# Usage: ./remote_burn.sh <bathron_address> <amount_sats>
#
# Example: ./remote_burn.sh y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk 50000
#

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
SCP="scp -i $SSH_KEY $SSH_OPTS"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -lt 2 ]; then
    echo -e "${RED}Usage: $0 <bathron_address> <amount_sats>${NC}"
    echo ""
    echo "Example: $0 y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk 50000"
    echo ""
    echo "Test addresses:"
    echo "  alice:   yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
    echo "  bob:     y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk"
    echo "  charlie: yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"
    echo "  pilpous: xyszqryssGaNw13qpjbxB4PVoRqGat7RPd"
    exit 1
fi

BATHRON_ADDR="$1"
BURN_SATS="$2"

echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Remote BTC Burn on Seed                ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Target:${NC} $SEED_IP (Seed - Bitcoin Signet)"
echo -e "${YELLOW}BATHRON Address:${NC} $BATHRON_ADDR"
echo -e "${YELLOW}Amount:${NC} $BURN_SATS sats"
echo ""

# Step 1: Copy burn script to seed
echo -e "${YELLOW}[1/3] Copying burn script to seed...${NC}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
$SCP "$SCRIPT_DIR/burn_signet.sh" ubuntu@$SEED_IP:/tmp/burn_signet.sh
$SSH ubuntu@$SEED_IP "chmod +x /tmp/burn_signet.sh"
echo "  Done."

# Step 2: Check Bitcoin Signet status
echo ""
echo -e "${YELLOW}[2/3] Checking Bitcoin Signet on seed...${NC}"
BTC_STATUS=$($SSH ubuntu@$SEED_IP '
    BTCCLI=""
    if [ -f "/home/ubuntu/bitcoin-27.0/bin/bitcoin-cli" ]; then
        BTCCLI="/home/ubuntu/bitcoin-27.0/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet"
    elif [ -f "/home/ubuntu/BATHRON/BTCTESTNET/bitcoin-27.0/bin/bitcoin-cli" ]; then
        BTCCLI="/home/ubuntu/BATHRON/BTCTESTNET/bitcoin-27.0/bin/bitcoin-cli -datadir=/home/ubuntu/BATHRON/BTCTESTNET/data"
    else
        echo "NOTFOUND"
        exit 0
    fi

    HEIGHT=$($BTCCLI getblockcount 2>/dev/null || echo "ERROR")
    if [ "$HEIGHT" = "ERROR" ]; then
        echo "OFFLINE"
    else
        BALANCE=$($BTCCLI -rpcwallet=bathronburn getbalance 2>/dev/null || $BTCCLI -rpcwallet=burn_test getbalance 2>/dev/null || echo "0")
        echo "OK:$HEIGHT:$BALANCE"
    fi
')

if [[ "$BTC_STATUS" == "NOTFOUND" ]]; then
    echo -e "${RED}Error: Bitcoin CLI not found on seed${NC}"
    exit 1
elif [[ "$BTC_STATUS" == "OFFLINE" ]]; then
    echo -e "${RED}Error: Bitcoin Signet daemon not running on seed${NC}"
    echo "Start it with: ssh ubuntu@$SEED_IP 'bitcoind -signet -daemon'"
    exit 1
fi

IFS=':' read -r STATUS HEIGHT BALANCE <<< "$BTC_STATUS"
BALANCE_SATS=$(echo "$BALANCE * 100000000" | bc 2>/dev/null | cut -d. -f1 || echo "0")
echo "  Signet height: $HEIGHT"
echo "  Wallet balance: $BALANCE BTC ($BALANCE_SATS sats)"

if [ "$BALANCE_SATS" -lt "$BURN_SATS" ]; then
    echo -e "${RED}Error: Insufficient balance ($BALANCE_SATS < $BURN_SATS)${NC}"
    echo ""
    echo "Get signet coins from:"
    echo "  - https://signetfaucet.com/"
    echo "  - https://alt.signetfaucet.com/"
    exit 1
fi

# Step 3: Execute burn
echo ""
echo -e "${YELLOW}[3/3] Executing burn transaction...${NC}"
echo ""

# Run burn script with --yes for auto-confirm
RESULT=$($SSH ubuntu@$SEED_IP "/tmp/burn_signet.sh '$BATHRON_ADDR' $BURN_SATS --yes" 2>&1)

echo "$RESULT"

# Extract TXID from result
TXID=$(echo "$RESULT" | grep -oP 'TXID: \K[a-f0-9]{64}' | head -1 || true)

if [ -n "$TXID" ]; then
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                  BURN COMPLETE                            ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${GREEN}TXID: $TXID${NC}"
    echo ""
    echo "Track on mempool.space:"
    echo "  https://mempool.space/signet/tx/$TXID"
    echo ""
    echo "After 6 confirmations, add to genesis_burns.json and re-enrich."
else
    echo ""
    echo -e "${RED}Could not extract TXID from output. Check above for errors.${NC}"
fi
