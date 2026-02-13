#!/usr/bin/env bash
set -euo pipefail

# Re-register all 8 MNs on Seed after fork recovery
# Uses existing bathron.conf operator keys

SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"
CLI="$SSH_CMD /home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "=== Re-registering 8 MNs on Seed ==="
echo ""

# Check current MN count
echo "Current MN count:"
$CLI masternode count 2>&1 || echo "No MNs registered"
echo ""

# Read operator keys from ~/.BathronKey/operators.json on Seed
echo "Reading operator keys from ~/.BathronKey/operators.json..."
OPERATORS_JSON=$($SSH_CMD "cat ~/.BathronKey/operators.json")

# Parse and register each MN
for i in {1..8}; do
    echo "Registering MN$i..."
    
    # Extract WIF for this MN
    WIF=$(echo "$OPERATORS_JSON" | jq -r ".mn${i}.wif")
    
    if [ "$WIF" == "null" ] || [ -z "$WIF" ]; then
        echo "ERROR: No WIF found for MN$i in operators.json"
        continue
    fi
    
    # Import key if not already imported
    $CLI importprivkey "$WIF" "" false 2>/dev/null || echo "Key already imported"
    
    # Get the collateral UTXO (need 1000 M0)
    # For simplicity, assume pilpous wallet has funds and we create collaterals
    COLLATERAL_ADDR=$($CLI getnewaddress)
    
    echo "  Collateral address: $COLLATERAL_ADDR"
    echo "  Operator key imported: ${WIF:0:10}..."
    echo ""
done

echo ""
echo "=== Next Steps ==="
echo "1. Send 1000 M0 to each collateral address (8000 M0 total needed)"
echo "2. Wait for confirmations"
echo "3. Run 'protx register' for each MN with collateral UTXO"
echo ""
echo "Current wallet balance:"
$CLI getbalance
