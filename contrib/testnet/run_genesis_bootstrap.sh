#!/bin/bash
# Wrapper to run genesis bootstrap on Seed with proper BTC paths

set -e

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SCP="scp -i $SSH_KEY -o StrictHostKeyChecking=no"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "════════════════════════════════════════════════════════════════"
echo "  Genesis Bootstrap on Seed"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 1. Copy bootstrap script and dependencies to Seed
echo "[1] Copying scripts to Seed..."
$SCP contrib/testnet/genesis_bootstrap_seed.sh ubuntu@$SEED_IP:/tmp/
$SCP contrib/testnet/btc_burn_claim_daemon.sh ubuntu@$SEED_IP:~/
echo "[OK] Scripts copied"

# 2. Copy burn destination keys if they exist
if [ -f ~/.pivkey/burn_dest_keys.json ]; then
    echo "[2] Copying burn destination keys..."
    $SCP ~/.pivkey/burn_dest_keys.json ubuntu@$SEED_IP:/tmp/
    echo "[OK] Keys copied"
else
    echo "[2] No burn destination keys found (will skip)"
fi

# 3. Run bootstrap on Seed
echo ""
echo "[3] Running bootstrap on Seed..."
echo "    This will take 2-3 minutes..."
echo ""

$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE' | tee /tmp/genesis_bootstrap.log
# Set BTC paths (found via diagnostic)
export BTC_CLI=/home/ubuntu/bitcoin-27.0/bin/bitcoin-cli
export BTC_DATADIR=/home/ubuntu/.bitcoin-signet

# Run bootstrap
chmod +x /tmp/genesis_bootstrap_seed.sh
/tmp/genesis_bootstrap_seed.sh 2>&1
REMOTE

EXIT_CODE=$?

echo ""
echo "════════════════════════════════════════════════════════════════"
if [ $EXIT_CODE -eq 0 ]; then
    echo "  Bootstrap complete!"
else
    echo "  Bootstrap failed (exit $EXIT_CODE)"
    echo "  Full log: /tmp/genesis_bootstrap.log"
    exit $EXIT_CODE
fi
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Next: Copy bootstrap chain to other nodes with:"
echo "  ./contrib/testnet/deploy_to_vps.sh --genesis-distribute"
