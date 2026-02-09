#!/bin/bash
#
# Send BTC from Charlie (OP3) to LP address
#
# Usage: ./send_btc_charlie_to_lp.sh <amount_btc> <lp_address>
#

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP3_IP="51.75.31.44"  # Charlie (fake user)
BTC_CLI_OP3="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

# Colors
G='\033[0;32m'
Y='\033[1;33m'
B='\033[0;34m'
N='\033[0m'

log() { echo -e "${B}[$(date '+%H:%M:%S')]${N} $1"; }
ok() { echo -e "${G}✓${N} $1"; }

# Parse arguments
AMOUNT_BTC=${1:-0.001}
LP_ADDRESS=${2:-"tb1qxuljrzqckwyzzmh5l7kq4zslcr6zvahzqfahre"}

echo "════════════════════════════════════════════════════════════════"
echo "  SEND BTC: Charlie → LP"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Amount: $AMOUNT_BTC BTC"
echo "LP Address: $LP_ADDRESS"
echo ""

# Check Charlie's balance
log "Checking Charlie's BTC balance..."
BALANCE=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$BTC_CLI_OP3 getbalance" 2>&1)
echo "  Current balance: $BALANCE BTC"

if [ -z "$BALANCE" ] || [ "$BALANCE" = "0.00000000" ]; then
    echo ""
    echo -e "${Y}⚠${N} No BTC available. Fund Charlie's wallet:"
    echo "  1. Get OP3 address: ssh ubuntu@$OP3_IP '$BTC_CLI_OP3 getnewaddress'"
    echo "  2. Use faucet: https://signetfaucet.com"
    exit 1
fi

# Send BTC
log "Sending $AMOUNT_BTC BTC to LP..."
TXID=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$BTC_CLI_OP3 sendtoaddress '$LP_ADDRESS' $AMOUNT_BTC 'atomic_swap_to_lp'" 2>&1)

if [[ "$TXID" =~ ^[a-f0-9]{64}$ ]]; then
    echo ""
    ok "BTC sent successfully!"
    echo ""
    echo "Transaction ID: $TXID"
    echo ""
    
    # Get updated balance
    log "Updated balance:"
    NEW_BALANCE=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$BTC_CLI_OP3 getbalance" 2>&1)
    echo "  Charlie's remaining: $NEW_BALANCE BTC"
    
    # Save to temp file
    echo "$TXID" > /tmp/charlie_btc_to_lp_txid.txt
    echo "$AMOUNT_BTC" > /tmp/charlie_btc_amount.txt
    echo "$LP_ADDRESS" > /tmp/lp_btc_address.txt
    
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "Next step: Wait for confirmations (usually 1-2 minutes on Signet)"
    echo "════════════════════════════════════════════════════════════════"
else
    echo ""
    echo -e "${Y}✗${N} Send failed: $TXID"
    exit 1
fi
