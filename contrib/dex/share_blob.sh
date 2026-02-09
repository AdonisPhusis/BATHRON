#!/bin/bash
#
# BATHRON DEX - Share LOT blob with MNs
#
# Usage: ./share_blob.sh <LOT_OUTPOINT>
#
# This script:
# 1. Exports redeemScript and conditions_blob from local node
# 2. Sends to all MN VPS via SSH
# 3. MNs import the blob so they can attest
#

set -e

# ============ CONFIGURATION ============
BATHRON_CLI="$HOME/BATHRON-Core/src/bathron-cli"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

# MN VPS IPs and their CLI paths
declare -A MN_NODES=(
    ["VPS1"]="162.19.251.75:~/bathron-cli"
    ["VPS2"]="57.131.33.152:~/bathron-cli"
    ["VPS3"]="57.131.33.214:~/bathron-cli"
    ["VPS4"]="51.75.31.44:~/bathron-cli"
)

# ============ COLORS ============
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ============ MAIN ============

if [ -z "$1" ]; then
    echo "Usage: $0 <LOT_OUTPOINT>"
    echo ""
    echo "Example: $0 53ab831a7faef59d1c3e079060bf5a15e3233b7bfb5b38674db921a4bca5f15e:0"
    exit 1
fi

LOT_OUTPOINT="$1"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║          BATHRON DEX - Share LOT Blob with MNs                ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Export blob from local node
log_info "Exporting blob for LOT: $LOT_OUTPOINT"

EXPORT_RESULT=$($BATHRON_CLI -testnet lot_export_blob "$LOT_OUTPOINT" 2>&1)

if echo "$EXPORT_RESULT" | grep -q "error"; then
    log_err "Failed to export blob:"
    echo "$EXPORT_RESULT"
    exit 1
fi

# Parse JSON result
REDEEM_HEX=$(echo "$EXPORT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('redeem_script_hex',''))")
CONDITIONS_HEX=$(echo "$EXPORT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('conditions_blob_hex',''))")
REDEEM_HASH=$(echo "$EXPORT_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('redeem_hash',''))")

if [ -z "$REDEEM_HEX" ]; then
    log_err "RedeemScript not found locally. Are you running this on the LOT creator node?"
    exit 1
fi

log_ok "Exported redeemScript (hash: ${REDEEM_HASH:0:16}...)"
echo "   Script size: ${#REDEEM_HEX} hex chars"

# Step 2: Send to all MN nodes
echo ""
log_info "Sending blob to MN nodes..."

SUCCESS_COUNT=0
FAIL_COUNT=0

for NODE_NAME in "${!MN_NODES[@]}"; do
    NODE_INFO="${MN_NODES[$NODE_NAME]}"
    IP="${NODE_INFO%%:*}"
    CLI_PATH="${NODE_INFO#*:}"

    echo -n "   $NODE_NAME ($IP): "

    # Build import command
    if [ -n "$CONDITIONS_HEX" ]; then
        IMPORT_CMD="$CLI_PATH -testnet lot_import_blob '$REDEEM_HEX' '$CONDITIONS_HEX'"
    else
        IMPORT_CMD="$CLI_PATH -testnet lot_import_blob '$REDEEM_HEX'"
    fi

    # Execute via SSH
    RESULT=$(ssh -i "$SSH_KEY" $SSH_OPTS "ubuntu@$IP" "$IMPORT_CMD" 2>&1)

    if echo "$RESULT" | grep -q '"imported": true'; then
        echo -e "${GREEN}✓ Imported${NC}"
        ((SUCCESS_COUNT++))
    else
        echo -e "${RED}✗ Failed${NC}"
        log_warn "   $RESULT"
        ((FAIL_COUNT++))
    fi
done

# Step 3: Summary
echo ""
echo "════════════════════════════════════════════════════════════"
echo "Summary: $SUCCESS_COUNT/$((SUCCESS_COUNT + FAIL_COUNT)) nodes imported successfully"

if [ $SUCCESS_COUNT -ge 6 ]; then
    log_ok "Quorum possible (6+ nodes have the script)"
else
    log_warn "Not enough nodes for quorum (need 6, have $SUCCESS_COUNT)"
fi

echo ""
echo "Next steps:"
echo "  1. Taker sends payment on quote chain (Polygon/BTC/DASH)"
echo "  2. Call: bathron-cli -testnet lot_take \"$LOT_OUTPOINT\" \"USDC\" \"<taker_addr>\" \"<tx_hash>\""
echo "  3. MNs verify and attest automatically (or manually via lot_attest)"
echo "  4. When quorum reached: bathron-cli -testnet lot_try_release \"$LOT_OUTPOINT\""
echo ""
