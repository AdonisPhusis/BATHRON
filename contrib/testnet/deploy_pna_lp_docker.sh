#!/bin/bash
# Deploy pna-lp via Docker on LP VPS nodes
# Usage:
#   ./contrib/testnet/deploy_pna_lp_docker.sh setup [lp1|lp2]   # Install Docker + first run
#   ./contrib/testnet/deploy_pna_lp_docker.sh deploy [lp1|lp2]  # Build & restart container
#   ./contrib/testnet/deploy_pna_lp_docker.sh status [lp1|lp2]  # Check status
#   ./contrib/testnet/deploy_pna_lp_docker.sh logs [lp1|lp2]    # View logs

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# LP configurations
declare -A LP_HOST LP_ID LP_NAME
LP_HOST[lp1]="57.131.33.152"
LP_HOST[lp2]="57.131.33.214"
LP_ID[lp1]="lp_pna_01"
LP_ID[lp2]="lp_pna_02"
LP_NAME[lp1]="pna LP"
LP_NAME[lp2]="pna LP 2"

CONTAINER_NAME="pna-lp"
PORT=8080

# Source files (from BATHRON-V2 monorepo)
SRC_DIR="$(cd "$(dirname "$0")/../../contrib/dex/pna-lp" && pwd)"

usage() {
    echo "Usage: $0 {setup|deploy|status|logs} [lp1|lp2]"
    echo "  Default: lp1"
    exit 1
}

CMD="${1:-}"
TARGET="${2:-lp1}"

if [[ -z "$CMD" ]]; then usage; fi
if [[ ! "${LP_HOST[$TARGET]+exists}" ]]; then
    echo "[ERROR] Unknown target: $TARGET (use lp1 or lp2)"
    exit 1
fi

HOST="${LP_HOST[$TARGET]}"
ID="${LP_ID[$TARGET]}"
NAME="${LP_NAME[$TARGET]}"
REMOTE="ubuntu@$HOST"

echo -e "\033[0;34mTarget: $NAME ($ID) @ $HOST\033[0m"

ssh_cmd() {
    ssh $SSH_OPTS "$REMOTE" "$@"
}

case "$CMD" in
    setup)
        echo -e "\033[0;34m[INFO]\033[0m Installing Docker on $HOST..."

        ssh_cmd 'bash -s' <<'SETUP_EOF'
            set -e
            if command -v docker &>/dev/null; then
                echo "Docker already installed: $(docker --version)"
            else
                echo "Installing Docker..."
                curl -fsSL https://get.docker.com | sh
                sudo usermod -aG docker ubuntu
                echo "Docker installed: $(docker --version)"
                echo "NOTE: You may need to re-login for group changes"
            fi

            # Ensure Docker service is running
            sudo systemctl enable docker
            sudo systemctl start docker
            docker info >/dev/null 2>&1 && echo "Docker daemon OK" || echo "WARNING: Docker daemon not responding (try re-login)"
SETUP_EOF

        echo -e "\033[0;32m[OK]\033[0m Docker setup complete on $HOST"
        echo ""
        echo "Next: $0 deploy $TARGET"
        ;;

    deploy)
        echo -e "\033[0;34m[INFO]\033[0m Deploying pna-lp Docker container..."

        # 1. Sync source files
        echo -e "\033[0;34m[INFO]\033[0m Syncing source files..."
        rsync -az --delete \
            --exclude='venv' --exclude='__pycache__' --exclude='.lp_addresses.json' \
            -e "ssh $SSH_OPTS" \
            "$SRC_DIR/" "$REMOTE:~/pna-lp-src/"

        # 2. Build image on VPS
        echo -e "\033[0;34m[INFO]\033[0m Building Docker image on $HOST..."
        ssh_cmd "cd ~/pna-lp-src && docker build -t $CONTAINER_NAME:latest ."

        # 3. Stop old container + old non-Docker process
        echo -e "\033[0;34m[INFO]\033[0m Stopping old container + old processes..."
        ssh_cmd 'bash -s' <<'STOP_EOF' || true
            docker stop pna-lp 2>/dev/null
            docker rm pna-lp 2>/dev/null
            # Kill any python server on port 8080 (old non-Docker deploy)
            PID=$(lsof -ti :8080 2>/dev/null)
            if [ -n "$PID" ]; then
                echo "Killing process on port 8080: PID=$PID"
                kill -9 $PID 2>/dev/null
                sleep 2
            fi
            # Also try pkill as fallback
            pkill -9 -f 'python3.*server.py' 2>/dev/null
            sleep 1
            # Verify port is free
            if lsof -ti :8080 >/dev/null 2>&1; then
                echo "WARNING: Port 8080 still in use!"
                lsof -i :8080 2>/dev/null
            else
                echo "Port 8080 is free"
            fi
STOP_EOF

        # 5. Detect CLI binary paths on remote host
        echo -e "\033[0;34m[INFO]\033[0m Detecting CLI binaries on $HOST..."
        BATHRON_CLI_PATH=$(ssh_cmd 'for p in ~/bathron-cli ~/bathron/bin/bathron-cli ~/BATHRON/src/bathron-cli /usr/local/bin/bathron-cli; do [ -x "$p" ] && echo "$p" && break; done')
        BITCOIN_CLI_PATH=$(ssh_cmd 'for p in ~/bitcoin/bin/bitcoin-cli ~/btc-signet/bin/bitcoin-cli /usr/local/bin/bitcoin-cli; do [ -x "$p" ] && echo "$p" && break; done')

        if [[ -z "$BATHRON_CLI_PATH" ]]; then
            echo -e "\033[0;31m[ERROR]\033[0m bathron-cli not found on $HOST"
            exit 1
        fi
        if [[ -z "$BITCOIN_CLI_PATH" ]]; then
            echo -e "\033[0;31m[ERROR]\033[0m bitcoin-cli not found on $HOST"
            exit 1
        fi
        echo "  bathron-cli: $BATHRON_CLI_PATH"
        echo "  bitcoin-cli: $BITCOIN_CLI_PATH"

        # 6. Create wrapper scripts for CLI binaries (use host libs via LD_LIBRARY_PATH)
        echo -e "\033[0;34m[INFO]\033[0m Setting up CLI wrappers on $HOST..."
        ssh_cmd 'bash -s' <<'WRAPPER_EOF'
            mkdir -p ~/pna-lp-bin
            cat > ~/pna-lp-bin/bathron-cli << 'SCRIPT'
#!/bin/sh
LD_LIBRARY_PATH=/host-libs/lib:/host-libs/usr exec /opt/bathron-cli "$@"
SCRIPT
            cat > ~/pna-lp-bin/bitcoin-cli << 'SCRIPT'
#!/bin/sh
LD_LIBRARY_PATH=/host-libs/lib:/host-libs/usr exec /opt/bitcoin-cli "$@"
SCRIPT
            chmod +x ~/pna-lp-bin/bathron-cli ~/pna-lp-bin/bitcoin-cli
            echo "Wrappers created OK"
WRAPPER_EOF

        # 7. Run new container
        #    LD_LIBRARY_PATH only applies to CLI wrappers, NOT to Python
        echo -e "\033[0;34m[INFO]\033[0m Starting container ($ID)..."
        ssh_cmd "docker run -d \
            --name $CONTAINER_NAME \
            --restart unless-stopped \
            --network host \
            -v \$HOME/.BathronKey:/root/.BathronKey:ro \
            -v \$HOME/.bathron:/root/.bathron \
            -v \$HOME/.bitcoin-signet:/root/.bitcoin-signet:ro \
            -v $BATHRON_CLI_PATH:/opt/bathron-cli:ro \
            -v $BITCOIN_CLI_PATH:/opt/bitcoin-cli:ro \
            -v \$HOME/pna-lp-bin/bathron-cli:/usr/local/bin/bathron-cli:ro \
            -v \$HOME/pna-lp-bin/bitcoin-cli:/usr/local/bin/bitcoin-cli:ro \
            -v /lib/x86_64-linux-gnu:/host-libs/lib:ro \
            -v /usr/lib/x86_64-linux-gnu:/host-libs/usr:ro \
            -e LP_ID=$ID \
            -e LP_NAME='$NAME' \
            -e PORT=$PORT \
            $CONTAINER_NAME:latest"

        # 8. Wait and check
        sleep 3
        if ssh_cmd "curl -sf http://localhost:$PORT/api/status >/dev/null 2>&1"; then
            echo -e "\033[0;32m[OK]\033[0m Container running. http://$HOST:$PORT/"
        else
            echo -e "\033[0;33m[WARN]\033[0m Container started but not responding yet. Check logs:"
            echo "  $0 logs $TARGET"
        fi
        ;;

    status)
        echo -e "\033[0;34m[INFO]\033[0m Docker status on $HOST..."
        echo ""

        # Docker installed?
        ssh_cmd "docker --version 2>/dev/null || echo 'Docker: NOT INSTALLED'"
        echo ""

        # Container running?
        echo "=== Container ==="
        ssh_cmd "docker ps -a --filter name=$CONTAINER_NAME --format 'Status: {{.Status}}\nImage: {{.Image}}\nPorts: {{.Ports}}' 2>/dev/null || echo 'No container found'"
        echo ""

        # API check
        echo "=== API ==="
        ssh_cmd "curl -sf http://localhost:$PORT/api/status 2>/dev/null | python3 -m json.tool 2>/dev/null || echo 'API not responding'"
        ;;

    logs)
        echo -e "\033[0;34m[INFO]\033[0m Container logs ($HOST)..."
        ssh_cmd "docker logs --tail 50 $CONTAINER_NAME 2>&1"
        ;;

    *)
        usage
        ;;
esac
