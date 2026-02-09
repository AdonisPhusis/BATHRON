#!/usr/bin/env bash
set -euo pipefail

SEED_IP="57.131.33.151"
SEED_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "=== SEED BINARY STATUS ==="
echo

# Check binary file
echo "[1] Binary file info:"
ssh -i "$SSH_KEY" "$SEED_USER@$SEED_IP" 'ls -lh ~/BATHRON-Core/src/bathrond' || echo "ERROR: Binary not found"
echo

# Check HTLC support
echo "[2] HTLC_CREATE_M1 string count:"
ssh -i "$SSH_KEY" "$SEED_USER@$SEED_IP" 'strings ~/BATHRON-Core/src/bathrond | grep -c HTLC_CREATE_M1' || echo "0 (not found)"
echo

# Check running process
echo "[3] Running process:"
ssh -i "$SSH_KEY" "$SEED_USER@$SEED_IP" 'pgrep -a bathrond || echo "No bathrond running"'
echo

# Get binary checksum
echo "[4] Binary SHA256:"
ssh -i "$SSH_KEY" "$SEED_USER@$SEED_IP" 'sha256sum ~/BATHRON-Core/src/bathrond | cut -d" " -f1'
echo

echo "=== LOCAL BINARY STATUS ==="
echo

# Local binary info
echo "[1] Local binary file info:"
ls -lh /home/ubuntu/BATHRON/src/bathrond
echo

# Local HTLC support
echo "[2] Local HTLC_CREATE_M1 string count:"
strings /home/ubuntu/BATHRON/src/bathrond | grep -c HTLC_CREATE_M1 || echo "0 (not found)"
echo

# Local binary checksum
echo "[3] Local binary SHA256:"
sha256sum /home/ubuntu/BATHRON/src/bathrond | cut -d" " -f1
echo

echo "=== COMPARISON ==="
SEED_SHA=$(ssh -i "$SSH_KEY" "$SEED_USER@$SEED_IP" 'sha256sum ~/BATHRON-Core/src/bathrond | cut -d" " -f1')
LOCAL_SHA=$(sha256sum /home/ubuntu/BATHRON/src/bathrond | cut -d" " -f1)

if [ "$SEED_SHA" = "$LOCAL_SHA" ]; then
    echo "✓ Binaries MATCH"
else
    echo "✗ Binaries DIFFER - Seed needs update"
fi
