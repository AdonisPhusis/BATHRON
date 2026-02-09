#!/bin/bash
# diagnose_network.sh - Deep diagnostic of BATHRON testnet network
#
# This script investigates why blocks are not being produced

set -e

SSH_KEY="~/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# Node configuration
SEED_IP="57.131.33.151"
SEED_CLI="~/BATHRON-Core/src/bathron-cli -testnet"

MN_IPS=("162.19.251.75" "57.131.33.152" "57.131.33.214" "51.75.31.44")
MN_CLI="~/bathron-cli -testnet"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

section() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} $1"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
}

subsection() {
    echo ""
    echo -e "${BLUE}--- $1 ---${NC}"
}

# ============================================================================
section "1. BASIC NETWORK STATUS"
# ============================================================================

subsection "Block Height and Peers"
echo "Seed ($SEED_IP):"
$SSH ubuntu@$SEED_IP "$SEED_CLI getblockcount && echo 'peers:' && $SEED_CLI getconnectioncount" 2>/dev/null || echo "ERROR"

for ip in "${MN_IPS[@]}"; do
    echo ""
    echo "MN ($ip):"
    $SSH ubuntu@$ip "$MN_CLI getblockcount && echo 'peers:' && $MN_CLI getconnectioncount" 2>/dev/null || echo "ERROR"
done

# ============================================================================
section "2. MASTERNODE LIST STATUS"
# ============================================================================

subsection "Masternode List from Seed"
$SSH ubuntu@$SEED_IP "$SEED_CLI listmasternodes" 2>/dev/null | head -100

# ============================================================================
section "3. DMM SCHEDULER STATUS"
# ============================================================================

subsection "DMM Info from Seed"
$SSH ubuntu@$SEED_IP "$SEED_CLI getdmminfo" 2>/dev/null || echo "getdmminfo not available"

subsection "Next Block Producer (if available)"
$SSH ubuntu@$SEED_IP "$SEED_CLI getnextblockproducer" 2>/dev/null || echo "getnextblockproducer not available"

# ============================================================================
section "4. DEBUG LOGS - DMM/SCHEDULER MESSAGES"
# ============================================================================

subsection "Seed Debug Log (last 100 lines, filtered)"
$SSH ubuntu@$SEED_IP "grep -E '(DMM|SCHEDULER|CreateNewBlock|SignBlock|producer|masternode|MN|IsBlockchainSynced|COLD)' ~/.bathron/testnet5/debug.log 2>/dev/null | tail -50" || echo "No log or no matches"

subsection "MN1 Debug Log (DMM related)"
$SSH ubuntu@${MN_IPS[0]} "grep -E '(DMM|SCHEDULER|CreateNewBlock|SignBlock|producer|IsBlockchainSynced|COLD)' ~/.bathron/testnet5/debug.log 2>/dev/null | tail -30" || echo "No log or no matches"

# ============================================================================
section "5. MASTERNODE OPERATOR KEY CHECK"
# ============================================================================

subsection "Config files - mnoperatorprivatekey presence"
echo "Seed config:"
$SSH ubuntu@$SEED_IP "grep -E '(masternode|mnoperator)' ~/.bathron/bathron.conf 2>/dev/null || grep -E '(masternode|mnoperator)' ~/.bathron/testnet5/bathron.conf 2>/dev/null" || echo "No masternode config"

for ip in "${MN_IPS[@]}"; do
    echo ""
    echo "MN ($ip) config:"
    $SSH ubuntu@$ip "grep -E '(masternode|mnoperator)' ~/.bathron/bathron.conf 2>/dev/null || grep -E '(masternode|mnoperator)' ~/.bathron/testnet5/bathron.conf 2>/dev/null" || echo "No masternode config"
done

# ============================================================================
section "6. BLOCKCHAIN SYNC STATUS"
# ============================================================================

subsection "IsBlockchainSynced Check"
$SSH ubuntu@$SEED_IP "$SEED_CLI mnsync status" 2>/dev/null || echo "mnsync not available"

subsection "Blockchain Info"
$SSH ubuntu@$SEED_IP "$SEED_CLI getblockchaininfo" 2>/dev/null | grep -E "(chain|blocks|headers|bestblockhash|verificationprogress)"

# ============================================================================
section "7. ERROR MESSAGES IN LOGS"
# ============================================================================

subsection "Errors in Seed Log"
$SSH ubuntu@$SEED_IP "grep -iE '(error|fail|reject|invalid)' ~/.bathron/testnet5/debug.log 2>/dev/null | tail -20" || echo "No errors found"

subsection "Errors in MN1 Log"
$SSH ubuntu@${MN_IPS[0]} "grep -iE '(error|fail|reject|invalid)' ~/.bathron/testnet5/debug.log 2>/dev/null | tail -20" || echo "No errors found"

# ============================================================================
section "8. FULL DEBUG LOG (LAST 50 LINES)"
# ============================================================================

subsection "Seed Full Log"
$SSH ubuntu@$SEED_IP "tail -50 ~/.bathron/testnet5/debug.log" 2>/dev/null

echo ""
echo -e "${GREEN}=== DIAGNOSTIC COMPLETE ===${NC}"
