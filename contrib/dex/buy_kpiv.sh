#!/bin/bash
#
# BATHRON DEX - Buy KPIV with USDC (Fully Automated)
#
# Usage: ./buy_kpiv.sh <EVM_PRIVATE_KEY>
#
# This script:
# 1. Sends 0.10 USDC to the LP address on Polygon
# 2. Waits for confirmations
# 3. Calls lot_take automatically
#

set -e

# ============ CONFIGURATION ============
LOT_OUTPOINT="89ac7d0c2d215c6460d1b979632ce50cd7d4f27c303ebdce64841a1260552d8c:0"
USDC_AMOUNT="0.10"
LP_ADDRESS="0x73748C0CDf44c360De6F4aC66E488384F4c8664B"
BATHRON_RECEIVE="y1smYcdnocYQrZNAwz5W4e9QxRxRE8PVMv"
BATHRON_CLI="$HOME/BATHRON-Core/src/bathron-cli"

# Polygon Mainnet
POLYGON_RPC="https://polygon-rpc.com"
USDC_CONTRACT="0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"
CHAIN_ID=137

# ============ FUNCTIONS ============

check_deps() {
    if ! command -v python3 &> /dev/null; then
        echo "❌ Python3 required"
        exit 1
    fi

    if ! python3 -c "import web3" 2>/dev/null; then
        echo "📦 Installing web3..."
        pip3 install web3 --quiet
    fi
}

send_usdc() {
    local PRIVATE_KEY="$1"

    python3 << PYTHON
import sys
from web3 import Web3

# Connect to Polygon
w3 = Web3(Web3.HTTPProvider("${POLYGON_RPC}"))
if not w3.is_connected():
    print("❌ Cannot connect to Polygon RPC")
    sys.exit(1)

print("✅ Connected to Polygon")

# Account from private key
account = w3.eth.account.from_key("${PRIVATE_KEY}")
print(f"📍 From: {account.address}")

# USDC Contract (ERC20)
USDC_ABI = [{"constant":False,"inputs":[{"name":"_to","type":"address"},{"name":"_value","type":"uint256"}],"name":"transfer","outputs":[{"name":"","type":"bool"}],"type":"function"},{"constant":True,"inputs":[{"name":"_owner","type":"address"}],"name":"balanceOf","outputs":[{"name":"balance","type":"uint256"}],"type":"function"}]

usdc = w3.eth.contract(address=Web3.to_checksum_address("${USDC_CONTRACT}"), abi=USDC_ABI)

# Check balance
balance = usdc.functions.balanceOf(account.address).call()
amount_units = int(${USDC_AMOUNT} * 1000000)  # 6 decimals

print(f"💰 USDC Balance: {balance / 1000000:.2f}")
if balance < amount_units:
    print("❌ Insufficient USDC balance")
    sys.exit(1)

# Build transaction
nonce = w3.eth.get_transaction_count(account.address)
tx = usdc.functions.transfer(
    Web3.to_checksum_address("${LP_ADDRESS}"),
    amount_units
).build_transaction({
    'chainId': ${CHAIN_ID},
    'gas': 100000,
    'maxFeePerGas': w3.to_wei(50, 'gwei'),
    'maxPriorityFeePerGas': w3.to_wei(30, 'gwei'),
    'nonce': nonce,
})

# Sign and send
print(f"📤 Sending {${USDC_AMOUNT}} USDC to ${LP_ADDRESS}...")
signed = w3.eth.account.sign_transaction(tx, "${PRIVATE_KEY}")
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
print(f"📋 TX Hash: {tx_hash.hex()}")

# Wait for confirmation
print("⏳ Waiting for confirmation...")
receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

if receipt['status'] == 1:
    print(f"✅ Confirmed in block {receipt['blockNumber']}")
    print(f"TX_HASH={tx_hash.hex()}")
else:
    print("❌ Transaction failed!")
    sys.exit(1)
PYTHON
}

# ============ MAIN ============

echo "╔════════════════════════════════════════════╗"
echo "║     BATHRON DEX - Buy KPIV with USDC          ║"
echo "╚════════════════════════════════════════════╝"
echo ""

# Check for private key
if [ -z "$1" ]; then
    echo "Usage: $0 <EVM_PRIVATE_KEY>"
    echo ""
    echo "Example: $0 abc123...def456"
    echo ""
    echo "The private key should be hex without 0x prefix"
    exit 1
fi

EVM_KEY="$1"

echo "📦 LOT: $LOT_OUTPOINT"
echo "💵 Price: $USDC_AMOUNT USDC"
echo "📍 LP Address: $LP_ADDRESS"
echo "🎯 Receive KPIV at: $BATHRON_RECEIVE"
echo ""

# Check dependencies
check_deps

# Step 1: Send USDC
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Sending USDC on Polygon..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TX_OUTPUT=$(send_usdc "$EVM_KEY" 2>&1)
echo "$TX_OUTPUT"

# Extract TX hash
TX_HASH=$(echo "$TX_OUTPUT" | grep "TX_HASH=" | cut -d'=' -f2)

if [ -z "$TX_HASH" ]; then
    echo "❌ Failed to get TX hash"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Calling lot_take..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Step 2: Call lot_take
echo "🔄 Executing: $BATHRON_CLI -testnet lot_take \"$LOT_OUTPOINT\" \"USDC\" \"$BATHRON_RECEIVE\" \"$TX_HASH\""

RESULT=$($BATHRON_CLI -testnet lot_take "$LOT_OUTPOINT" "USDC" "$BATHRON_RECEIVE" "$TX_HASH" 2>&1)

echo "$RESULT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ DONE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Polygon TX: https://polygonscan.com/tx/$TX_HASH"
echo ""
echo "The MN quorum will now verify your payment and release the KPIV."
