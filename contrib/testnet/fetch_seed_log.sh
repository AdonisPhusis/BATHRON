#!/bin/bash
# Fetch genesis bootstrap log + debug info from Seed
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SEED_IP="57.131.33.151"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

case "${1:-log}" in
    log)
        echo "=== Bootstrap Log ==="
        ssh $SSH_OPTS ubuntu@$SEED_IP 'cat /tmp/genesis_bootstrap.log 2>/dev/null || echo "[ERROR] Log not found"'
        ;;
    spv)
        echo "=== SPV Backup Info ==="
        ssh $SSH_OPTS ubuntu@$SEED_IP '
            echo "Backup files:"; ls -lh ~/btcspv_backup_*.tar.gz 2>/dev/null || echo "  None"
            echo ""; echo "Symlink target:"; readlink ~/btcspv_backup_latest.tar.gz 2>/dev/null || echo "  Not a symlink"
            echo ""; echo "Backup size:"; du -sh ~/btcspv_backup_latest.tar.gz 2>/dev/null || echo "  Missing"
            echo ""; echo "Current btcspv/:"; ls -la ~/.bathron/testnet5/btcspv/ 2>/dev/null | head -5 || echo "  Not found"
        '
        ;;
    debug)
        echo "=== Debug Log (last 50 lines) ==="
        ssh $SSH_OPTS ubuntu@$SEED_IP 'tail -50 /tmp/bathron_bootstrap/testnet5/debug.log 2>/dev/null || echo "[ERROR] No debug log"'
        ;;
    *)
        echo "Usage: $0 {log|spv|debug}"
        ;;
esac
