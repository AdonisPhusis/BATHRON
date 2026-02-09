#!/bin/bash
#
# Fund LP wallets with M0 for FlowSwap testing
#
# Sends M0 from Seed (pilpous) to:
# - Alice (LP1): for M1 HTLC lock
# - Bob (LP2): for receiving M1 claim
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

SEED_IP="57.131.33.151"
BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

# Addresses
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
BOB_ADDR="y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk"

# Amount to send (in BATH)
AMOUNT="1.0"  # 1 BATH = 100,000,000 sats

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Fund LP Wallets for FlowSwap                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "=== Current Seed balance ==="
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI getbalance" 2>/dev/null || echo "Error"

echo ""
echo "=== Sending $AMOUNT BATH to Alice ($ALICE_ADDR) ==="
ALICE_TXID=$(ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI sendtoaddress \"$ALICE_ADDR\" $AMOUNT" 2>/dev/null || echo "ERROR")
if [[ "$ALICE_TXID" == "ERROR" ]]; then
    echo "  FAILED to send to Alice"
else
    echo "  TX: $ALICE_TXID"
fi

echo ""
echo "=== Sending $AMOUNT BATH to Bob ($BOB_ADDR) ==="
BOB_TXID=$(ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI sendtoaddress \"$BOB_ADDR\" $AMOUNT" 2>/dev/null || echo "ERROR")
if [[ "$BOB_TXID" == "ERROR" ]]; then
    echo "  FAILED to send to Bob"
else
    echo "  TX: $BOB_TXID"
fi

echo ""
echo "=== Waiting for confirmation (1 block) ==="
sleep 5

echo ""
echo "=== Checking new balances ==="

echo ""
echo "Alice (OP1):"
ssh $SSH_OPTS "ubuntu@57.131.33.152" "$BATHRON_CLI getwalletstate true" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
m0 = d.get('m0_available', 0)
print(f'  M0: {m0:,} sats')
" || echo "  Error"

echo ""
echo "Bob (CoreSDK):"
ssh $SSH_OPTS "ubuntu@162.19.251.75" "$BATHRON_CLI getwalletstate true" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
m0 = d.get('m0_available', 0)
print(f'  M0: {m0:,} sats')
" || echo "  Error"

echo ""
echo "Done! LP wallets should now have M0 for testing."
echo ""
echo "Next steps:"
echo "  1. Alice: bathron-cli -testnet lock 50000000  # Lock 0.5 BATH as M1"
echo "  2. Run FlowSwap E2E test"
