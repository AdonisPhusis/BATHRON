#!/bin/bash
# fix_seed_resync.sh - Resync Seed from network (wipe chain, keep config)

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SEED_IP="57.131.33.151"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "=== Fix Seed Resync ==="
echo "Seed is at height 1, network is at height 58"
echo "Wiping Seed chain data and resyncing from network"
echo ""

# Step 1: Stop Seed daemon
echo "[1/4] Stopping Seed daemon..."
$SSH ubuntu@$SEED_IP 'pkill -9 bathrond 2>/dev/null || true; sleep 3'

# Step 2: Wipe chain data but KEEP wallet and config
echo "[2/4] Wiping chain data (keeping wallet, config, btcspv)..."
$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
DAT=~/.bathron/testnet5
echo "Before wipe:"
ls -la $DAT/ 2>/dev/null | head -10

# Keep: wallet.dat, bathron.conf, btcspv/
# Wipe: blocks, chainstate, evodb, etc.
rm -rf $DAT/blocks $DAT/chainstate $DAT/index
rm -rf $DAT/evodb $DAT/llmq $DAT/settlementdb $DAT/burnclaimdb
rm -rf $DAT/hu_finality $DAT/khu $DAT/sporks
rm -f $DAT/peers.dat $DAT/banlist.dat $DAT/mempool.dat
rm -f $DAT/mncache.dat $DAT/mnmetacache.dat
rm -f $DAT/.lock

# Keep btcspv and btcheadersdb if they exist (SPV data)
# Keep wallet.dat

echo ""
echo "After wipe:"
ls -la $DAT/ 2>/dev/null | head -10
REMOTE

# Step 3: Restart with addnode to connect to other nodes
echo "[3/4] Restarting Seed with explicit addnodes..."
$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
DAEMON=~/bathrond
CLI="~/bathron-cli -testnet"
DAT=~/.bathron/testnet5

# Ensure addnodes are in config
grep -q "addnode=162.19.251.75" $DAT/../bathron.conf 2>/dev/null || {
    echo "Adding addnode entries to config..."
    cat >> $DAT/../bathron.conf << EOF
addnode=162.19.251.75:27171
addnode=51.75.31.44:27171
addnode=57.131.33.152:27171
addnode=57.131.33.214:27171
EOF
}

# Start daemon
$DAEMON -testnet -daemon
sleep 10

# Check status
echo ""
echo "Height: $($CLI getblockcount 2>/dev/null || echo 'starting...')"
echo "Peers: $($CLI getconnectioncount 2>/dev/null || echo '?')"
REMOTE

# Step 4: Wait for sync
echo "[4/4] Waiting for Seed to sync (target: height 58)..."
for i in {1..30}; do
    sleep 5
    HEIGHT=$($SSH ubuntu@$SEED_IP '~/bathron-cli -testnet getblockcount 2>/dev/null || echo 0')
    PEERS=$($SSH ubuntu@$SEED_IP '~/bathron-cli -testnet getconnectioncount 2>/dev/null || echo 0')
    echo "  Attempt $i: height=$HEIGHT, peers=$PEERS"

    if [ "$HEIGHT" -ge 58 ] 2>/dev/null; then
        echo ""
        echo "=== SUCCESS: Seed synced to height $HEIGHT ==="
        break
    fi
done

# Final status
echo ""
echo "=== Final Status ==="
$SSH ubuntu@$SEED_IP '~/bathron-cli -testnet getblockchaininfo 2>/dev/null | jq "{blocks, headers, bestblockhash: .bestblockhash[0:16]}"'
