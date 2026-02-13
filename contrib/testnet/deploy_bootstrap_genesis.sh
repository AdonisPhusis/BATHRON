#!/usr/bin/env bash
set -euo pipefail

SEED_IP="57.131.33.151"
NODES=("162.19.251.75" "57.131.33.152" "57.131.33.214" "51.75.31.44")
SSH_KEY="~/.ssh/id_ed25519_vps"

echo "=== Deploying Bootstrap Genesis from Seed to All Nodes ==="
echo ""

# Step 1: Package bootstrap on Seed
echo "Step 1: Packaging bootstrap data on Seed..."
ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$SEED_IP << 'REMOTE'
cd /tmp/bathron_bootstrap/testnet5
tar czf /tmp/genesis_bootstrap.tar.gz blocks chainstate evodb llmq btcheadersdb settlementdb burnclaimdb
echo "[OK] Packaged: /tmp/genesis_bootstrap.tar.gz"
REMOTE

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
rm -f ~/.bathron/testnet5/{peers.dat,banlist.dat,mempool.dat,.lock}
echo "[OK] Wiped"
REMOTE
done
wait

echo ""
echo "Step 4: Copying bootstrap to all nodes..."
for IP in "${NODES[@]}"; do
    echo "  Copying to $IP..."
    ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$SEED_IP \
        "scp -i ~/.ssh/id_rsa /tmp/genesis_bootstrap.tar.gz ubuntu@$IP:/tmp/" &
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
for IP in $SEED_IP "${NODES[@]}"; do
    echo "  Starting $IP..."
    if [ "$IP" = "57.131.33.151" ] || [ "$IP" = "162.19.251.75" ]; then
        # Seed and CoreSDK use BATHRON-Core/src/
        ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$IP \
            '/home/ubuntu/BATHRON-Core/src/bathrond -testnet -daemon' &
    else
        # Others use ~/bathrond
        ssh -i $SSH_KEY -o StrictHostKeyChecking=no ubuntu@$IP \
            '/home/ubuntu/bathrond -testnet -daemon' &
    fi
done
wait
sleep 15

echo ""
echo "=== Bootstrap Deployment Complete! ==="
echo ""
echo "Checking status..."
./contrib/testnet/deploy_to_vps.sh --status
