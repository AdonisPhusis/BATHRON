#!/bin/bash
# Check server restart time vs swap creation time

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

BLUE='\033[0;34m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

echo -e "${BLUE}=== Server Restart vs Swap Timeline ===${NC}\n"

echo "Current time (server):"
$SSH ubuntu@57.131.33.152 "date"

echo ""
echo "Swap timestamps:"
echo "  Created: 1770865480 = $(date -d @1770865480)"
echo "  Expires: 1770866380 = $(date -d @1770866380)"
echo "  Plan duration: 900 seconds (15 minutes)"

echo ""
echo "Server process start time:"
$SSH ubuntu@57.131.33.152 "ps aux | grep 'uvicorn.*server' | grep -v grep | awk '{print \$2}' | head -1 | xargs ps -o lstart= -p"

echo ""
echo "Server uptime:"
$SSH ubuntu@57.131.33.152 "ps aux | grep 'uvicorn.*server' | grep -v grep | awk '{print \$2}' | head -1 | xargs ps -o etime= -p"

echo ""
echo "Checking startup log for DB load:"
$SSH ubuntu@57.131.33.152 "grep 'Loaded.*FlowSwap' /tmp/pna-sdk.log 2>/dev/null | tail -3"

echo ""
echo -e "${YELLOW}Analysis:${NC}"
NOW=$(date +%s)
CREATED=1770865480
EXPIRES=1770866380
echo "  Now: $NOW"
echo "  Swap created: $CREATED"
echo "  Swap expires: $EXPIRES"

if [ $NOW -gt $EXPIRES ]; then
    echo -e "  ${GREEN}Swap is EXPIRED (auto-cleaned from memory)${NC}"
else
    echo "  Swap should still be active"
fi
