#!/bin/bash
# fix_mn_registration.sh - Fix stalled MN registration
# Clears bad ProRegTx from mempool, verifies UTXOs, re-registers MNs

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SEED_IP="57.131.33.151"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== Fix MN Registration ==="
echo ""

# Step 1: Stop Seed daemon and clear mempool
echo "[1/5] Stopping Seed and clearing mempool..."
$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
$CLI stop 2>/dev/null || true
sleep 5
pkill -9 bathrond 2>/dev/null || true
sleep 2
rm -f ~/.bathron/testnet5/mempool.dat
echo "Mempool cleared"
REMOTE

# Step 2: Restart daemon
echo "[2/5] Restarting Seed daemon..."
$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
/home/ubuntu/BATHRON-Core/src/bathrond -testnet -daemon -noconnect
sleep 15
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
echo "Height: $($CLI getblockcount)"
echo "Mempool: $($CLI getmempoolinfo | jq '.size')"
REMOTE

# Step 3: Import keys and rescan
echo "[3/5] Importing keys and rescanning..."
$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

# Import burn destination keys
$CLI importprivkey "cTuaDJPC5HvAYD4XzFxWUszUDfVeSmaN47N6qvCxnpaucgeYzxb2" "yJYD2" false 2>/dev/null || true
$CLI importprivkey "cQvp6t3Jz8MQ5FJEVM4ewucabskCfyhy73N1eP9c82xGxgEA71CX" "xyszq" false 2>/dev/null || true

echo "Rescanning blockchain..."
$CLI rescanblockchain 0 2>/dev/null | jq '{stop: .stop_height}'

echo ""
echo "Wallet balance: $($CLI getbalance | jq -r '.total // 0')"
REMOTE

# Step 4: Check 1M UTXOs and register MNs
echo "[4/5] Checking UTXOs and registering MNs..."
$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

# Find 1M UTXOs (collaterals)
MN_UTXOS=$($CLI listunspent 0 9999999 2>/dev/null | jq -c "[.[] | select(.amount == 1000000)]")
MN_COUNT=$(echo "$MN_UTXOS" | jq "length")
echo "1M UTXOs found: $MN_COUNT"

if [ "$MN_COUNT" -eq 0 ]; then
    echo "ERROR: No 1M UTXOs found!"
    echo "Available UTXOs:"
    $CLI listunspent 0 9999999 2>/dev/null | jq -c '.[] | {addr: .address[0:20], amt: .amount}' | head -10
    exit 1
fi

# Check existing MN list
MN_LIST_COUNT=$($CLI protx_list 2>/dev/null | jq "length" 2>/dev/null || echo "0")
echo "Existing MNs: $MN_LIST_COUNT"

if [ "$MN_LIST_COUNT" -gt 0 ]; then
    echo "MNs already registered, generating block to activate..."
    $CLI generatebootstrap 1 2>/dev/null | jq -r '.[0][0:16]'
    echo "New height: $($CLI getblockcount)"
    exit 0
fi

# Generate new operator key
KEYPAIR=$($CLI generateoperatorkeypair)
OP_WIF=$(echo "$KEYPAIR" | jq -r ".secret")
OP_PUB=$(echo "$KEYPAIR" | jq -r ".public")

# Save operator key
mkdir -p ~/.BathronKey
chmod 700 ~/.BathronKey
echo "{\"operator\":{\"wif\":\"$OP_WIF\",\"pubkey\":\"$OP_PUB\",\"mn_count\":$MN_COUNT,\"ip\":\"57.131.33.151\"}}" > ~/.BathronKey/operators.json
echo "Operator key generated"

# Limit to 8 MNs
MAX_MN=8
[ "$MN_COUNT" -gt "$MAX_MN" ] && MN_COUNT=$MAX_MN && MN_UTXOS=$(echo "$MN_UTXOS" | jq -c ".[0:$MAX_MN]")

# Register each MN
MN_REG_OK=0
echo ""
echo "Registering $MN_COUNT MNs..."
for row in $(echo "$MN_UTXOS" | jq -c ".[]"); do
    TXID=$(echo "$row" | jq -r ".txid")
    VOUT=$(echo "$row" | jq -r ".vout")

    # Verify UTXO exists before registration
    UTXO_CHECK=$($CLI gettxout "$TXID" $VOUT 2>/dev/null)
    if [ -z "$UTXO_CHECK" ] || [ "$UTXO_CHECK" = "null" ]; then
        echo "  MN $((MN_REG_OK + 1)): UTXO ${TXID:0:12}:$VOUT does NOT exist - skipping"
        continue
    fi

    OWNER=$($CLI getnewaddress "owner_$MN_REG_OK")
    VOTING=$($CLI getnewaddress "voting_$MN_REG_OK")
    PAYOUT=$($CLI getnewaddress "payout_$MN_REG_OK")

    REG_RESULT=$($CLI protx_register "$TXID" "$VOUT" "57.131.33.151:27171" "$OWNER" "$OP_PUB" "$VOTING" "$PAYOUT" 2>&1) || true

    if echo "$REG_RESULT" | jq -e ".txid" >/dev/null 2>&1; then
        PROTX=$(echo "$REG_RESULT" | jq -r ".txid")
        echo "  MN $((MN_REG_OK + 1)): OK - ${PROTX:0:16}..."
        MN_REG_OK=$((MN_REG_OK + 1))
    else
        echo "  MN $((MN_REG_OK + 1)): FAILED - $REG_RESULT"
    fi
done

echo ""
echo "MNs registered: $MN_REG_OK / $MN_COUNT"

# Generate block to include ProRegTx
if [ "$MN_REG_OK" -gt 0 ]; then
    echo ""
    echo "Generating block with ProRegTx..."
    RESULT=$($CLI generatebootstrap 1 2>&1)
    echo "Result: ${RESULT:0:50}..."
    echo "Height: $($CLI getblockcount)"
    echo "Mempool: $($CLI getmempoolinfo | jq '.size')"
    echo "MN List: $($CLI protx_list 2>/dev/null | jq 'length' 2>/dev/null || echo '0')"
fi
REMOTE

# Step 5: Reconnect to network
echo "[5/5] Reconnecting to network..."
$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

# Add peers
$CLI addnode "162.19.251.75:27171" "add" 2>/dev/null || true
$CLI addnode "51.75.31.44:27171" "add" 2>/dev/null || true
$CLI addnode "57.131.33.152:27171" "add" 2>/dev/null || true
$CLI addnode "57.131.33.214:27171" "add" 2>/dev/null || true

sleep 5
echo "Peers: $($CLI getconnectioncount)"
echo "Height: $($CLI getblockcount)"
echo "MNs: $($CLI protx_list 2>/dev/null | jq 'length' 2>/dev/null || echo '0')"
REMOTE

echo ""
echo "=== Fix Complete ==="
