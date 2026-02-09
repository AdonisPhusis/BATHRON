#!/bin/bash
# Deploy wallet viewer to OP3 (fake user VPS)
# Usage: ./deploy_wallet_viewer.sh [deploy|start|stop|status|logs]

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"
SCP="scp -i $SSH_KEY $SSH_OPTS"
OP3_IP="51.75.31.44"
REMOTE_DIR="wallet-viewer"
PORT=8888

ACTION="${1:-status}"

case "$ACTION" in
    deploy)
        echo "=== Deploying Wallet Viewer to OP3 ==="
        echo ""

        # Create remote directory
        $SSH ubuntu@$OP3_IP "mkdir -p ~/$REMOTE_DIR"

        # Copy files
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        $SCP "$SCRIPT_DIR/wallet-viewer/index.html" ubuntu@$OP3_IP:~/$REMOTE_DIR/
        $SCP "$SCRIPT_DIR/wallet-viewer/server.py" ubuntu@$OP3_IP:~/$REMOTE_DIR/

        # Make executable
        $SSH ubuntu@$OP3_IP "chmod +x ~/$REMOTE_DIR/server.py"

        echo "Files deployed to ~/$REMOTE_DIR/"
        echo ""
        echo "Now run: $0 start"
        ;;

    start)
        echo "=== Starting Wallet Viewer ==="

        # Kill existing (ignore errors)
        $SSH ubuntu@$OP3_IP "pkill -f 'wallet-viewer.*server' 2>/dev/null" || true
        sleep 1

        # Start using setsid (creates new session, survives SSH disconnect)
        $SSH ubuntu@$OP3_IP "cd ~/wallet-viewer && setsid python3 server.py >> server.log 2>&1 < /dev/null &"

        sleep 2

        # Verify via HTTP (most reliable)
        if curl -s --max-time 3 "http://$OP3_IP:$PORT/api/status" | grep -q "ok"; then
            echo "Server started!"
            echo ""
            echo "URL: http://$OP3_IP:$PORT/"
        else
            echo "ERROR: Server failed to start"
            echo "Logs:"
            $SSH ubuntu@$OP3_IP "cat ~/wallet-viewer/server.log 2>/dev/null | tail -20" || echo "No logs"
            exit 1
        fi
        ;;

    stop)
        echo "=== Stopping Wallet Viewer ==="
        $SSH ubuntu@$OP3_IP "pkill -f 'server.py' 2>/dev/null || true"
        echo "Stopped"
        ;;

    restart)
        $0 stop
        sleep 1
        $0 start
        ;;

    status)
        echo "=== Wallet Viewer Status ==="
        echo ""

        # Check process
        if $SSH ubuntu@$OP3_IP "pgrep -f 'server.py'" > /dev/null 2>&1; then
            echo "Status:  RUNNING"
            echo "URL:     http://$OP3_IP:$PORT/"
            echo ""

            # Test API
            echo "API Test:"
            curl -s --max-time 5 "http://$OP3_IP:$PORT/api/status" 2>/dev/null | python3 -m json.tool || echo "  (API not responding - firewall?)"
        else
            echo "Status:  STOPPED"
            echo ""
            echo "Run: $0 start"
        fi
        ;;

    logs)
        echo "=== Wallet Viewer Logs ==="
        $SSH ubuntu@$OP3_IP "cat ~/$REMOTE_DIR/server.log 2>/dev/null | tail -50" || echo "No logs"
        ;;

    test-ssh)
        echo "=== Testing SSH to OP3 ==="
        $SSH ubuntu@$OP3_IP "echo 'SSH OK - hostname: $(hostname)'"
        ;;

    *)
        echo "Usage: $0 [deploy|start|stop|restart|status|logs|test-ssh]"
        echo ""
        echo "Commands:"
        echo "  deploy   Copy files to OP3"
        echo "  start    Start the server"
        echo "  stop     Stop the server"
        echo "  restart  Restart the server"
        echo "  status   Check if running"
        echo "  logs     View server logs"
        echo "  test-ssh Test SSH connection"
        ;;
esac
