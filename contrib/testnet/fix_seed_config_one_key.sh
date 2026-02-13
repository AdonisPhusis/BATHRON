#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"

echo "=== Fixing Seed Config (ONE operator key only) ==="

$SSH_CMD bash << 'REMOTE'
cd ~/.bathron

# Restore backup if it exists
if [ -f bathron.conf.backup ]; then
    cp bathron.conf.backup bathron.conf
fi

# Ensure only ONE operator key
sed -i '/^mnoperatorprivatekey=/d' bathron.conf
sed -i 's/^#masternode=1/masternode=1/' bathron.conf

# Add first operator key only
KEY1=$(jq -r ".mn1.wif" ~/.BathronKey/operators.json)
if [ "$KEY1" != "null" ]; then
    echo "mnoperatorprivatekey=$KEY1" >> bathron.conf
    echo "[OK] Added MN1 operator key"
fi

# Kill any stuck daemons
pkill -9 bathrond || true
sleep 3

# Start daemon
/home/ubuntu/BATHRON-Core/src/bathrond -testnet -daemon
echo "[OK] Daemon started"
REMOTE

echo ""
echo "Waiting for daemon to be ready..."
sleep 20

echo ""
echo "Checking status..."
./contrib/testnet/deploy_to_vps.sh --status
