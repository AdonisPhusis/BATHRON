#!/usr/bin/env bash
set -euo pipefail

SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"

echo "=== Configuring Seed with 8 MN Operator Keys ==="
echo ""

# Get operators.json from Seed
echo "Reading ~/.BathronKey/operators.json..."
OPERATORS=$($SSH_CMD "cat ~/.BathronKey/operators.json 2>/dev/null" || echo "{}")

if [ "$OPERATORS" = "{}" ]; then
    echo "ERROR: No operators.json found on Seed!"
    exit 1
fi

echo "Found operators.json, updating bathron.conf..."

# Update bathron.conf on Seed
$SSH_CMD bash << 'REMOTE_UPDATE'
cd ~/.bathron

# Backup existing config
cp bathron.conf bathron.conf.backup

# Remove old MN keys
sed -i '/^mnoperatorprivatekey=/d' bathron.conf
sed -i 's/^#masternode=1/masternode=1/' bathron.conf

# Add all 8 operator keys
for i in {1..8}; do
    KEY=$(jq -r ".mn${i}.wif" ~/.BathronKey/operators.json)
    if [ "$KEY" != "null" ]; then
        echo "mnoperatorprivatekey=$KEY" >> bathron.conf
    fi
done

echo "[OK] Updated bathron.conf with 8 operator keys"
REMOTE_UPDATE

echo ""
echo "Restarting Seed daemon..."
$SSH_CMD "pkill -9 bathrond; sleep 3; /home/ubuntu/BATHRON-Core/src/bathrond -testnet -daemon"
sleep 15

echo ""
echo "Checking MN status..."
$SSH_CMD "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getactivemnstatus" || echo "Not ready yet"

echo ""
echo "=== Configuration Complete ==="
