#!/bin/bash
# Fix LP EVM key priority on OP1/OP2.
# Renames ~/.keys/lp_evm.json to .bak so server uses ~/.BathronKey/evm.json
# (which has the funded alice_evm address with USDC).
#
# Usage: ./fix_lp_evm_key.sh [lp1|lp2] [restore]

set -e

LP_TARGET="${1:-lp1}"
ACTION="${2:-fix}"

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

case "$LP_TARGET" in
    lp1) IP="57.131.33.152" ;;
    lp2) IP="57.131.33.214" ;;
    *) echo "Usage: $0 [lp1|lp2] [fix|restore|status]"; exit 1 ;;
esac

echo "=== LP $LP_TARGET ($IP): EVM Key Fix ==="

case "$ACTION" in
    status)
        echo "--- Key files ---"
        $SSH ubuntu@$IP 'ls -la ~/.keys/lp_evm.json* ~/.BathronKey/evm.json 2>/dev/null || echo "(none found)"'
        echo ""
        echo "--- Active EVM address ---"
        $SSH ubuntu@$IP 'python3 -c "
import json, os
for p in [os.path.expanduser(\"~/.keys/lp_evm.json\"), os.path.expanduser(\"~/.BathronKey/evm.json\")]:
    if os.path.exists(p):
        d = json.load(open(p))
        addr = d.get(\"address\", \"(no address field)\")
        print(f\"  {p}: {addr}\")
        print(f\"  ^ THIS IS THE ACTIVE KEY (priority)\")
        break
    else:
        print(f\"  {p}: not found\")
"'
        ;;
    fix)
        echo "--- Renaming ~/.keys/lp_evm.json -> .bak ---"
        $SSH ubuntu@$IP 'if [ -f ~/.keys/lp_evm.json ]; then mv ~/.keys/lp_evm.json ~/.keys/lp_evm.json.bak && echo "OK: renamed"; else echo "SKIP: file not found"; fi'
        echo ""
        echo "--- Verifying active key ---"
        $SSH ubuntu@$IP 'python3 -c "
import json, os
for p in [os.path.expanduser(\"~/.keys/lp_evm.json\"), os.path.expanduser(\"~/.BathronKey/evm.json\")]:
    if os.path.exists(p):
        d = json.load(open(p))
        addr = d.get(\"address\", \"(no address field)\")
        print(f\"  Active key: {p} -> {addr}\")
        break
"'
        echo ""
        echo "--- Restarting LP server ---"
        $SSH ubuntu@$IP 'sudo systemctl restart pna-lp 2>/dev/null || (pkill -f "python.*server.py" && sleep 2 && cd /opt/pna-lp && nohup python3 server.py > /tmp/pna-lp.log 2>&1 &)'
        sleep 3
        echo "--- LP status ---"
        curl -s "http://$IP:8080/api/status" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'  Status: {d.get(\"status\",\"?\")}')" 2>/dev/null || echo "  LP not responding yet"
        ;;
    restore)
        echo "--- Restoring ~/.keys/lp_evm.json from .bak ---"
        $SSH ubuntu@$IP 'if [ -f ~/.keys/lp_evm.json.bak ]; then mv ~/.keys/lp_evm.json.bak ~/.keys/lp_evm.json && echo "OK: restored"; else echo "SKIP: backup not found"; fi'
        ;;
    *)
        echo "Usage: $0 [lp1|lp2] [fix|restore|status]"
        exit 1
        ;;
esac

echo "=== Done ==="
