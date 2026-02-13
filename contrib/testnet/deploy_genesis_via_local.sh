#!/usr/bin/env bash
set -euo pipefail

SEED_IP="57.131.33.151"
NODES=("162.19.251.75" "57.131.33.152" "57.131.33.214" "51.75.31.44")
SSH_KEY="~/.ssh/id_ed25519_vps"
BOOTSTRAP_TAR="/tmp/genesis_bootstrap.tar.gz"

echo "=== Deploying Genesis via Local Machine ==="
echo ""

echo "Step 1: Downloading bootstrap from Seed..."
scp -i $SSH_KEY -o StrictHostKeyChecking=no \
    ubuntu@$SEED_IP:/tmp/genesis_bootstrap.tar.gz \
    $BOOTSTRAP_TAR
echo "[OK] Downloaded to local: $BOOTSTRAP_TAR"

echo ""
echo "Step 2: Stopping all daemons..."
for IP in $SEED_IP "${NODES[@]}"; do
    ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$IP \
        'pkill -9 bathrond 2>/dev/null || true' &
done
wait
sleep 5

echo ""
echo "Step 3: Wiping data on all nodes..."
for IP in $SEED_IP "${NODES[@]}"; do
    echo "  Wiping $IP..."
    ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$IP << 'REMOTE' &
rm -rf ~/.bathron/testnet5/{blocks,chainstate,evodb,llmq,btcheadersdb,settlementdb,burnclaimdb}
rm -f ~/.bathron/testnet5/{peers.dat,banlist.dat,mempool.dat,.lock,mncache.dat,mnmetacache.dat}
REMOTE
done
wait

echo ""
echo "Step 4: Uploading bootstrap to all nodes..."
for IP in $SEED_IP "${NODES[@]}"; do
    echo "  Uploading to $IP..."
    scp -i $SSH_KEY -o StrictHostKeyChecking=no \
        $BOOTSTRAP_TAR ubuntu@$IP:/tmp/ &
done
wait

echo ""
echo "Step 5: Extracting bootstrap on all nodes..."
for IP in $SEED_IP "${NODES[@]}"; do
    echo "  Extracting on $IP..."
    ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$IP << 'REMOTE' &
cd ~/.bathron/testnet5
tar xzf /tmp/genesis_bootstrap.tar.gz
rm /tmp/genesis_bootstrap.tar.gz
echo "[OK] Extracted"
REMOTE
done
wait

echo ""
echo "Step 6: Starting all daemons..."
sleep 2
for IP in $SEED_IP "${NODES[@]}"; do
    echo "  Starting $IP..."
    if [ "$IP" = "57.131.33.151" ] || [ "$IP" = "162.19.251.75" ]; then
        ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$IP \
            '/home/ubuntu/BATHRON-Core/src/bathrond -testnet -daemon 2>&1' &
    else
        ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$IP \
            '/home/ubuntu/bathrond -testnet -daemon 2>&1' &
    fi
done
wait
sleep 20

echo ""
echo "=== Genesis Deployment Complete! ==="
echo ""
echo "Checking status..."
./contrib/testnet/deploy_to_vps.sh --status
