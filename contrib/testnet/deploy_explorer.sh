#!/bin/bash
# ============================================================================
# deploy_explorer.sh - Deploy and manage BATHRON Explorer on Seed node
# ============================================================================
# v8.0 (2025-01-27): Auto-backup, restore, protection marker, fixed paths
# ============================================================================

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS ubuntu@$SEED_IP"
SCP="scp -i $SSH_KEY $SSH_OPTS"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="$(cd "$SCRIPT_DIR/../explorer" && pwd)"
REMOTE_DIR="/home/ubuntu/explorer"

R='\033[0;31m'
G='\033[0;32m'
B='\033[0;34m'
Y='\033[1;33m'
N='\033[0m'

log() { echo -e "${B}[$(date +%H:%M:%S)]${N} $1"; }
ok()  { echo -e "${G}[$(date +%H:%M:%S)]${N} $1"; }
err() { echo -e "${R}[$(date +%H:%M:%S)] ERROR:${N} $1"; }
warn(){ echo -e "${Y}[$(date +%H:%M:%S)] WARN:${N} $1"; }

# ---------------------------------------------------------------------------
# Backup: keep last 5 timestamped copies on the VPS
# ---------------------------------------------------------------------------
remote_backup() {
    $SSH 'mkdir -p ~/explorer/backups
if [ -f ~/explorer/index.php ]; then
    cp ~/explorer/index.php ~/explorer/backups/index.php.$(date +%Y%m%d_%H%M%S)
    # keep only last 5 backups
    cd ~/explorer/backups && ls -1t index.php.* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null
    echo "OK"
else
    echo "SKIP"
fi'
}

# ---------------------------------------------------------------------------
# Protection marker: warns humans not to rm -rf ~/explorer
# ---------------------------------------------------------------------------
ensure_protection() {
    $SSH 'cat > ~/explorer/.explorer_protect << "PEOF"
# ============================================================
# DO NOT DELETE ~/explorer — this is the BATHRON block explorer
# Source of truth: git repo BATHRON/contrib/explorer/
# Redeploy: ./contrib/testnet/deploy_explorer.sh all
# ============================================================
PEOF'
}

# ---------------------------------------------------------------------------
# Start script on VPS
# ---------------------------------------------------------------------------
ensure_start_script() {
    $SSH 'cat > /tmp/start_explorer.sh << "EOF"
#!/bin/bash
cd ~/explorer
pkill -9 -f "php.*3001" 2>/dev/null
sleep 0.3
nohup php -S 0.0.0.0:3001 >> /tmp/explorer.log 2>&1 &
EOF
chmod +x /tmp/start_explorer.sh'
}

case "${1:-help}" in
    deploy)
        log "Backing up remote..."
        BK=$(remote_backup)
        [ "$BK" = "OK" ] && ok "Backup done" || warn "No previous index.php to back up"
        log "Deploying..."
        $SCP "$LOCAL_DIR/bathron-explorer.php" ubuntu@$SEED_IP:$REMOTE_DIR/index.php
        # Also deploy genesis_burns.json for TX_BURN_COUNT
        log "Copying genesis_burns.json..."
        $SCP "$SCRIPT_DIR/genesis_burns.json" ubuntu@$SEED_IP:$REMOTE_DIR/genesis_burns.json || warn "Failed to copy genesis_burns.json"
        ensure_start_script
        $SSH '/tmp/start_explorer.sh'
        ok "Done: http://$SEED_IP:3001/"
        ;;
    all)
        log "Backing up remote..."
        BK=$(remote_backup)
        [ "$BK" = "OK" ] && ok "Backup done" || warn "No previous index.php to back up"
        log "Full deploy..."
        $SSH "pkill -9 -f 'php.*3001' 2>/dev/null; mkdir -p $REMOTE_DIR" 2>/dev/null
        $SCP "$LOCAL_DIR/bathron-explorer.php" ubuntu@$SEED_IP:$REMOTE_DIR/index.php
        $SCP "$LOCAL_DIR/easybitcoin.php" "$LOCAL_DIR/logo.png" "$LOCAL_DIR/favicon.png" "$LOCAL_DIR/favicon-64.png" ubuntu@$SEED_IP:$REMOTE_DIR/ 2>/dev/null
        ensure_protection
        ensure_start_script
        $SSH '/tmp/start_explorer.sh'
        ok "Done: http://$SEED_IP:3001/"
        ;;
    start)
        ensure_start_script
        $SSH '/tmp/start_explorer.sh'
        ok "Started: http://$SEED_IP:3001/"
        ;;
    stop)
        $SSH "pkill -9 -f 'php.*3001'" 2>/dev/null
        ok "Stopped"
        ;;
    restart)
        ensure_start_script
        $SSH '/tmp/start_explorer.sh'
        ok "Restarted: http://$SEED_IP:3001/"
        ;;
    status)
        HTTP=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" "http://$SEED_IP:3001/")
        if [ "$HTTP" = "200" ]; then
            ok "HTTP $HTTP - http://$SEED_IP:3001/"
        else
            err "HTTP $HTTP - http://$SEED_IP:3001/"
        fi
        $SSH 'ls -1t ~/explorer/backups/index.php.* 2>/dev/null | head -3 | sed "s/^/  backup: /"' 2>/dev/null
        ;;
    backup)
        log "Creating backup..."
        BK=$(remote_backup)
        [ "$BK" = "OK" ] && ok "Backup created" || err "Nothing to back up"
        $SSH 'ls -1t ~/explorer/backups/index.php.* 2>/dev/null | sed "s/^/  /"'
        ;;
    restore)
        LATEST=$($SSH 'ls -1t ~/explorer/backups/index.php.* 2>/dev/null | head -1')
        if [ -z "$LATEST" ]; then
            err "No backups found"
            exit 1
        fi
        log "Restoring $LATEST..."
        $SSH "cp $LATEST ~/explorer/index.php"
        ensure_start_script
        $SSH '/tmp/start_explorer.sh'
        ok "Restored and restarted"
        ;;
    logs)
        $SSH "tail -30 /tmp/explorer.log"
        ;;
    *)
        echo "BATHRON Explorer - http://$SEED_IP:3001/"
        echo ""
        echo "  deploy   - Deploy PHP + auto-backup + restart"
        echo "  all      - Deploy all files + protection marker"
        echo "  start/stop/restart"
        echo "  status   - HTTP check + list backups"
        echo "  backup   - Manual backup on VPS"
        echo "  restore  - Restore latest backup"
        echo "  logs     - View logs"
        ;;
esac
