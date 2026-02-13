#!/bin/bash
# =============================================================================
# register_lps.sh - Register existing LPs on-chain via OP_RETURN
# =============================================================================

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# BATHRON CLI paths per VPS
OP1_CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet"
OP2_CLI="/home/ubuntu/bathron/bin/bathron-cli -testnet"

CMD="${1:-register}"

fund_wallet() {
    local IP=$1
    local CLI=$2
    local NAME=$3
    local AMOUNT=300  # 300 sats M0 (unlock from M1, needs +145 fee_backing)

    echo -e "${YELLOW}[$NAME]${NC} Checking M0 balance..."
    local BALANCE=$($SSH ubuntu@$IP "$CLI getbalance" 2>/dev/null)
    local M0=$(echo "$BALANCE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('m0', 0))" 2>/dev/null)

    if [ -z "$M0" ] || [ "$M0" -lt 100 ] 2>/dev/null; then
        echo -e "${YELLOW}[$NAME]${NC} M0 balance too low ($M0 sats). Unlocking $AMOUNT M1 -> M0..."
        $SSH ubuntu@$IP "$CLI unlock $AMOUNT" 2>&1
        echo -e "${YELLOW}[$NAME]${NC} Waiting for TX to confirm..."
        sleep 5
    else
        echo -e "${GREEN}[$NAME]${NC} M0 balance OK ($M0 sats)"
    fi
}

case "$CMD" in
    register)
        # Ensure wallets have M0 for fees
        fund_wallet "57.131.33.152" "$OP1_CLI" "LP1"
        echo ""
        fund_wallet "57.131.33.214" "$OP2_CLI" "LP2"
        echo ""

        # Wait for unlock TXs to confirm (1 block ~60s)
        echo -e "${BLUE}Waiting for unlock TXs to confirm...${NC}"
        sleep 65
        echo ""

        echo -e "${BLUE}[LP1]${NC} Registering LP1 (OP1) on-chain..."
        $SSH ubuntu@57.131.33.152 "cd ~/pna-sdk && source venv/bin/activate 2>/dev/null; python3 register_lp.py --endpoint 'http://57.131.33.152:8080'"
        echo ""

        echo -e "${BLUE}[LP2]${NC} Registering LP2 (OP2) on-chain..."
        $SSH ubuntu@57.131.33.214 "cd ~/pna-sdk && source venv/bin/activate 2>/dev/null; python3 register_lp.py --endpoint 'http://57.131.33.214:8080'"
        echo ""

        echo -e "${GREEN}Done.${NC} Wait ~60s for registry to scan new blocks."
        ;;
    status)
        echo -e "${BLUE}[LP1]${NC} LP1 wallet status..."
        $SSH ubuntu@57.131.33.152 "cd ~/pna-sdk && source venv/bin/activate 2>/dev/null; python3 register_lp.py --status"
        echo ""
        echo -e "${YELLOW}[LP1]${NC} Wallet state:"
        $SSH ubuntu@57.131.33.152 "$OP1_CLI getwalletstate true" 2>&1
        echo ""

        echo -e "${BLUE}[LP2]${NC} LP2 wallet status..."
        $SSH ubuntu@57.131.33.214 "cd ~/pna-sdk && source venv/bin/activate 2>/dev/null; python3 register_lp.py --status"
        echo ""
        echo -e "${YELLOW}[LP2]${NC} Wallet state:"
        $SSH ubuntu@57.131.33.214 "$OP2_CLI getwalletstate true" 2>&1
        ;;
    fund)
        # Fund LP2 + OP3 from LP1 (which has M0 from genesis burns)
        LP2_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"
        OP3_ADDR="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"

        echo -e "${BLUE}=== Funding LP2 + OP3 from LP1 ===${NC}"
        echo ""

        echo -e "${YELLOW}[LP1→LP2]${NC} Sending 500000 M0 to LP2..."
        $SSH ubuntu@57.131.33.152 "$OP1_CLI sendmany '' '{\"$LP2_ADDR\": 500000}'" 2>&1

        echo -e "${YELLOW}[LP1→OP3]${NC} Sending 100000 M0 to OP3..."
        $SSH ubuntu@57.131.33.152 "$OP1_CLI sendmany '' '{\"$OP3_ADDR\": 100000}'" 2>&1

        echo -e "${BLUE}Waiting for confirms (65s)...${NC}"
        sleep 65

        # Lock M0→M1 on both LPs for swap operations
        echo -e "${YELLOW}[LP1]${NC} Locking 1000000 M0 -> M1..."
        $SSH ubuntu@57.131.33.152 "$OP1_CLI lock 1000000" 2>&1

        echo -e "${YELLOW}[LP2]${NC} Locking 400000 M0 -> M1..."
        $SSH ubuntu@57.131.33.214 "$OP2_CLI lock 400000" 2>&1

        echo -e "${BLUE}Waiting for confirms (65s)...${NC}"
        sleep 65

        echo -e "${GREEN}=== Final Balances ===${NC}"
        $0 balances
        ;;
    register-lp2)
        echo -e "${BLUE}[LP2]${NC} Registering LP2 (OP2) on-chain..."
        $SSH ubuntu@57.131.33.214 "cd ~/pna-sdk && source venv/bin/activate 2>/dev/null; python3 register_lp.py --endpoint 'http://57.131.33.214:8080'"
        ;;
    balances)
        # Check all wallet balances to find spendable M0
        SEED_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
        CORESDK_CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

        echo -e "${BLUE}=== All Wallet Balances ===${NC}"
        echo ""
        echo -e "${YELLOW}[SEED]${NC} 57.131.33.151 (pilpous)"
        $SSH ubuntu@57.131.33.151 "$SEED_CLI getbalance" 2>/dev/null
        echo ""
        echo -e "${YELLOW}[CoreSDK]${NC} 162.19.251.75 (bob)"
        $SSH ubuntu@162.19.251.75 "$CORESDK_CLI getbalance" 2>/dev/null
        echo ""
        echo -e "${YELLOW}[LP1/OP1]${NC} 57.131.33.152 (alice)"
        $SSH ubuntu@57.131.33.152 "$OP1_CLI getbalance" 2>/dev/null
        echo ""
        echo -e "${YELLOW}[LP2/OP2]${NC} 57.131.33.214 (dev)"
        $SSH ubuntu@57.131.33.214 "$OP2_CLI getbalance" 2>/dev/null
        echo ""
        echo -e "${YELLOW}[OP3]${NC} 51.75.31.44 (charlie)"
        $SSH ubuntu@51.75.31.44 "/home/ubuntu/bathron-cli -testnet getbalance" 2>/dev/null
        ;;
    *)
        echo "Usage: $0 {register|status|fund|balances}"
        exit 1
        ;;
esac
