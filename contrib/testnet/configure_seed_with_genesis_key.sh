#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"
OPERATOR_WIF="cURUVCNEJDLWrX5jK7eQcAjTbXhBtNdRxCPqLCbcj5jyvLatBg56"

echo "=== Configuring Seed with Genesis Operator Key ==="
echo "WIF: $OPERATOR_WIF"
echo ""

$SSH_CMD bash << REMOTE
# Update bathron.conf
cd ~/.bathron
cp bathron.conf bathron.conf.bak
sed -i '/^mnoperatorprivatekey=/d' bathron.conf
echo "mnoperatorprivatekey=$OPERATOR_WIF" >> bathron.conf

# Restart daemon
pkill -9 bathrond
sleep 3
/home/ubuntu/BATHRON-Core/src/bathrond -testnet -daemon
echo "[OK] Daemon restarted with genesis operator key"
REMOTE

echo ""
echo "Waiting for daemon to be ready..."
sleep 20

echo ""
echo "Checking MN status..."
$SSH_CMD "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getactivemnstatus"

echo ""
echo "=== Configuration Complete ==="
