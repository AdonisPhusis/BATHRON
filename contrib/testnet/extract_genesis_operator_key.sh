#!/usr/bin/env bash
SEED_IP="57.131.33.151"
SSH_CMD="ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519_vps ubuntu@$SEED_IP"

echo "=== Extracting Genesis Operator Private Key ==="
echo ""

echo "Target operator public key: 032b4d364d1bdf043bb174a8f719112b9d34ab4d86e1dbae0077fe1f0a5f6105d4"
echo ""

echo "Dumping private key from bootstrap wallet..."
$SSH_CMD bash << 'REMOTE'
cd /tmp/bathron_bootstrap
CLI="/home/ubuntu/bathron-cli -datadir=/tmp/bathron_bootstrap -testnet"

# Start daemon briefly to dump keys
/home/ubuntu/bathrond -datadir=/tmp/bathron_bootstrap -testnet -daemon 2>&1
sleep 10

# Dump the operator key
# The key corresponds to the operator pubkey 032b4d364d1bdf043bb174a8f719112b9d34ab4d86e1dbae0077fe1f0a5f6105d4
# Try to find it in the wallet
$CLI dumpprivkey "032b4d364d1bdf043bb174a8f719112b9d34ab4d86e1dbae0077fe1f0a5f6105d4" 2>&1 || \
$CLI dumpwallet /tmp/genesis_wallet_dump.txt 2>&1

# Stop daemon
$CLI stop 2>&1 || true
sleep 5
pkill -9 bathrond || true

# Show the dump
if [ -f /tmp/genesis_wallet_dump.txt ]; then
    echo "Wallet dump created, searching for operator key..."
    grep -A 2 -B 2 "032b4d364d1bdf043bb174a8f719112b9d34ab4d86e1dbae0077fe1f0a5f6105d4" /tmp/genesis_wallet_dump.txt || \
    echo "Key not found in wallet dump, showing first 20 keys:"
    head -30 /tmp/genesis_wallet_dump.txt
fi
REMOTE
