#!/bin/bash
#
# Check LP balances (M1, USDC) for FlowSwap
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"      # Alice (LP1)
CORESDK_IP="162.19.251.75"  # Bob (LP2)

BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              LP Balances for FlowSwap                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"

echo -e "\n${CYAN}═══ LP1 - Alice (OP1) ═══${NC}"
echo "  IP: $OP1_IP"

# Alice M0/M1 balance
echo ""
echo "  BATHRON Wallet State:"
ssh $SSH_OPTS "ubuntu@$OP1_IP" "$BATHRON_CLI getwalletstate true" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
m0 = d.get('m0_available', 0)
m1_receipts = d.get('m1_receipts', [])
m1_total = sum(r['amount'] for r in m1_receipts)
print(f'    M0 available: {m0:,} sats')
print(f'    M1 total: {m1_total:,} sats ({len(m1_receipts)} receipts)')
if m1_receipts:
    print('    M1 receipts:')
    for r in m1_receipts[:5]:
        print(f'      - {r[\"outpoint\"]}: {r[\"amount\"]:,} sats')
"

# Alice USDC balance (optional)
echo ""
echo "  EVM (Base Sepolia):"
ssh $SSH_OPTS "ubuntu@$OP1_IP" "python3 -c \"
import json
try:
    with open('/home/ubuntu/.BathronKey/evm.json') as f:
        config = json.load(f)
    print(f'    Address: {config.get(\"address\", \"NOT SET\")}')
    print('    (USDC balance check requires web3 - skipped)')
except Exception as e:
    print(f'    Error: {e}')
\"" 2>/dev/null || echo "    EVM config not found"

echo -e "\n${CYAN}═══ LP2 - Bob (CoreSDK) ═══${NC}"
echo "  IP: $CORESDK_IP"

# Bob M0/M1 balance
echo ""
echo "  BATHRON Wallet State:"
ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "$BATHRON_CLI getwalletstate true" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
m0 = d.get('m0_available', 0)
m1_receipts = d.get('m1_receipts', [])
m1_total = sum(r['amount'] for r in m1_receipts)
print(f'    M0 available: {m0:,} sats')
print(f'    M1 total: {m1_total:,} sats ({len(m1_receipts)} receipts)')
if m1_receipts:
    print('    M1 receipts:')
    for r in m1_receipts[:5]:
        print(f'      - {r[\"outpoint\"]}: {r[\"amount\"]:,} sats')
"

# Bob USDC balance
echo ""
echo "  EVM (Base Sepolia):"
ssh $SSH_OPTS "ubuntu@$CORESDK_IP" "cd /home/ubuntu/pna-lp 2>/dev/null && python3 -c \"
import json
from web3 import Web3

# Load config
with open('/home/ubuntu/.BathronKey/evm.json') as f:
    config = json.load(f)

address = config.get('address', '')
print(f'    Address: {address}')

# Connect to Base Sepolia
w3 = Web3(Web3.HTTPProvider('https://sepolia.base.org'))

# USDC contract on Base Sepolia
USDC_ADDRESS = '0x036CbD53842c5426634e7929541eC2318f3dCF7e'
USDC_ABI = [{'constant': True, 'inputs': [{'name': '_owner', 'type': 'address'}], 'name': 'balanceOf', 'outputs': [{'name': 'balance', 'type': 'uint256'}], 'type': 'function'}]

usdc = w3.eth.contract(address=USDC_ADDRESS, abi=USDC_ABI)
balance = usdc.functions.balanceOf(address).call()
balance_usdc = balance / 10**6

print(f'    USDC balance: {balance_usdc:.2f} USDC')

# ETH balance for gas
eth_balance = w3.eth.get_balance(address)
eth_balance_eth = w3.from_wei(eth_balance, 'ether')
print(f'    ETH balance: {eth_balance_eth:.6f} ETH (for gas)')
\"" 2>/dev/null || echo "    Could not check EVM balances"

echo ""
echo -e "${CYAN}═══ Summary ═══${NC}"
echo ""
echo "  Required for FlowSwap E2E:"
echo "  ┌────────────┬─────────────────────────────────────────────────┐"
echo "  │ Actor      │ Needs                                           │"
echo "  ├────────────┼─────────────────────────────────────────────────┤"
echo "  │ LP1 Alice  │ M1 (to lock in HTLC3S for LP2)                  │"
echo "  │ LP2 Bob    │ USDC (to lock in EVM HTLC3S for User)           │"
echo "  │ User       │ BTC (to lock in P2WSH HTLC3S)                   │"
echo "  └────────────┴─────────────────────────────────────────────────┘"
echo ""
