#!/bin/bash
# Check why swap returns 404 despite being in DB

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

BLUE='\033[0;34m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

SWAP_ID="fs_59f554fb4eef4dbd"

echo -e "${YELLOW}=== Why does ${SWAP_ID} return 404? ===${NC}\n"

echo "1. Testing API right now:"
curl -s "http://57.131.33.152:8080/api/flowswap/${SWAP_ID}" | python3 -m json.tool 2>&1 | head -20

echo ""
echo "2. Checking if swap exists in DB on server:"
$SSH ubuntu@57.131.33.152 "python3 << 'PYEND'
import json
db_path = '/home/ubuntu/.bathron/flowswap_db_lp_pna_01.json'
try:
    with open(db_path) as f:
        db = json.load(f)
    swap = db.get('$SWAP_ID')
    if swap:
        print('FOUND in DB:')
        print(f'  State: {swap[\"state\"]}')
        print(f'  Created: {swap.get(\"created_at\")}')
        print(f'  Plan expires: {swap.get(\"plan_expires_at\")}')
        print(f'  LP locked at: {swap.get(\"lp_locked_at\")}')
    else:
        print('NOT in DB')
        print(f'Total swaps in DB: {len(db)}')
        print(f'Recent swap IDs: {list(db.keys())[-5:]}')
except Exception as e:
    print(f'Error: {e}')
PYEND
"

echo ""
echo "3. Checking server memory (in-RAM flowswap_db):"
echo "   (Server loads DB from file on startup, may be out of sync)"
echo ""
echo -e "${BLUE}Hypothesis:${NC}"
echo "The swap exists in the DB file but server was restarted AFTER it was created."
echo "New server instance loaded fresh DB which might not include this swap."
echo "OR: Swap was cleaned up by auto-cleanup logic (expired plans)."
