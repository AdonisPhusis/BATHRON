#!/bin/bash
# ==============================================================================
# register_lps_onchain.sh - Register LPs on-chain via OP_RETURN TXs
# ==============================================================================
#
# Tier 1 = TX signed by MN operator (sent from operator-derived address).
# The registry verifies: lp.address == HASH160(operatorPubKey).
# One LP per unique operator key.
#
# Usage:
#   ./register_lps_onchain.sh register    # Register LP from operator address
#   ./register_lps_onchain.sh status      # Show registry status
#   ./register_lps_onchain.sh derive-addr # Show operator-derived address
# ==============================================================================

set -uo pipefail

SSH="ssh -i $HOME/.ssh/id_ed25519_vps -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCP="scp -i $HOME/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

REGISTER_SCRIPT="$HOME/BATHRON/contrib/dex/pna-lp/register_lp.py"

SEED_IP="57.131.33.151"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"

CLI="/home/ubuntu/bathron-cli -testnet"

REGISTRY_URL="http://162.19.251.75:3003"

CMD="${1:-status}"

# ---------------------------------------------------------------------------
# Helper: get operator pubkey from protx_list on Seed
# ---------------------------------------------------------------------------
get_operator_pubkey() {
    # All 8 MNs use the same operator key (MULTI-MN).
    # Get the operatorPubKey from the first MN in protx_list.
    $SSH ubuntu@$SEED_IP "$CLI protx_list 2>/dev/null" 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data:
    state = data[0].get('dmnstate') or data[0].get('state') or {}
    print(state.get('operatorPubKey', ''))
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: derive P2PKH address from operator pubkey
# ---------------------------------------------------------------------------
derive_operator_address() {
    local PUBKEY="$1"
    python3 -c "
import hashlib
_B58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
def b58(data):
    n = int.from_bytes(data, 'big')
    r = ''
    while n > 0:
        n, rem = divmod(n, 58)
        r = _B58[rem] + r
    for b in data:
        if b == 0: r = _B58[0] + r
        else: break
    return r
pk = bytes.fromhex('$PUBKEY')
h160 = hashlib.new('ripemd160', hashlib.sha256(pk).digest()).digest()
v = bytes([139]) + h160
ck = hashlib.sha256(hashlib.sha256(v).digest()).digest()[:4]
print(b58(v + ck))
"
}

# ---------------------------------------------------------------------------
# Helper: display registry LPs
# ---------------------------------------------------------------------------
show_registry() {
    curl -s "$REGISTRY_URL/api/registry/lps" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f\"Total: {data.get('count', '?')} LPs\")
for lp in data.get('lps', []):
    tier = 'Tier 1 (Operator)' if lp.get('tier') == 1 else 'Tier 2 (Community)'
    status = lp.get('status', '?')
    print(f\"  {lp.get('endpoint', '?')}  [{tier}]  status={status}  addr={lp.get('address', '?')[:20]}...\")
" 2>/dev/null || echo "Registry unreachable"
}

case "$CMD" in
register)
    echo "=== Register LP from Operator Address (Tier 1) ==="
    echo ""

    # Step 1: Get operator pubkey + private key from Seed
    echo "[1/6] Getting operator key from Seed..."
    OP_PUBKEY=$(get_operator_pubkey)
    if [ -z "$OP_PUBKEY" ] || [ ${#OP_PUBKEY} -ne 66 ]; then
        echo "  ERROR: Could not get operator pubkey (got: '$OP_PUBKEY')"
        exit 1
    fi
    echo "  Operator pubkey: $OP_PUBKEY"

    OP_ADDR=$(derive_operator_address "$OP_PUBKEY")
    echo "  Operator address: $OP_ADDR"
    echo ""

    # Step 2: Import operator private key into Seed wallet
    # The WIF key is in ~/.BathronKey/operators.json (used by bathrond for block signing)
    # but NOT imported into the wallet. We need it in the wallet to spend from the
    # operator-derived address.
    echo "[2/6] Importing operator key into Seed wallet..."
    OP_WIF=$($SSH ubuntu@$SEED_IP "python3 -c \"
import json
d = json.load(open('/home/ubuntu/.BathronKey/operators.json'))
print(d.get('operator', {}).get('wif') or d.get('operators', {}).get('pilpous', {}).get('wif', ''))
\" 2>/dev/null" 2>/dev/null)
    if [ -z "$OP_WIF" ]; then
        echo "  ERROR: Could not read operator WIF from ~/.BathronKey/operators.json"
        exit 1
    fi
    echo "  WIF key found (${#OP_WIF} chars)"

    IMPORT_RESULT=$($SSH ubuntu@$SEED_IP "$CLI importprivkey '$OP_WIF' 'operator' false 2>&1" 2>/dev/null)
    if echo "$IMPORT_RESULT" | grep -qi "error"; then
        # "already in the wallet" is not an error
        if echo "$IMPORT_RESULT" | grep -qi "already"; then
            echo "  Key already in wallet"
        else
            echo "  Import result: $IMPORT_RESULT"
        fi
    else
        echo "  Key imported (label: operator)"
    fi
    echo ""

    # Step 3: Check if operator address has UTXOs
    echo "[3/6] Checking operator address balance on Seed..."
    OP_BALANCE=$($SSH ubuntu@$SEED_IP "$CLI listunspent 0 9999999 '[\"$OP_ADDR\"]' 2>/dev/null | python3 -c 'import sys,json; data=json.load(sys.stdin); print(sum(int(u[\"amount\"]) for u in data))'" 2>/dev/null)
    echo "  Operator address balance: ${OP_BALANCE:-0} sats"

    if [ "${OP_BALANCE:-0}" -lt 100 ] 2>/dev/null; then
        echo "  Funding operator address from Seed wallet..."
        FUND_TX=$($SSH ubuntu@$SEED_IP "$CLI sendmany '' '{\"$OP_ADDR\":5000}' 2>&1" 2>/dev/null)
        echo "  Fund TX: $FUND_TX"
        echo "  Waiting for confirmation (60s)..."
        sleep 60
    fi
    echo ""

    # Step 4: Upload register_lp.py
    LP_ENDPOINT="${2:-http://$OP1_IP:8080}"
    echo "[4/6] Uploading register_lp.py to Seed..."
    $SCP "$REGISTER_SCRIPT" ubuntu@$SEED_IP:/tmp/register_lp.py 2>/dev/null
    echo "  Done."
    echo ""

    # Step 5: Register LP from operator address
    echo "[5/6] Registering LP ($LP_ENDPOINT) from operator address..."
    RESULT=$($SSH ubuntu@$SEED_IP "python3 /tmp/register_lp.py --endpoint '$LP_ENDPOINT' --operator-pubkey '$OP_PUBKEY' 2>&1" 2>/dev/null)
    echo "$RESULT"
    echo ""

    # Step 6: Wait for confirmation + registry scan
    echo "[6/6] Waiting for block confirmation + registry scan (90s)..."
    sleep 90

    echo ""
    echo "=== Registry Status ==="
    show_registry
    ;;

derive-addr)
    echo "=== Derive Operator Address ==="
    OP_PUBKEY=$(get_operator_pubkey)
    if [ -z "$OP_PUBKEY" ]; then
        echo "ERROR: Could not get operator pubkey"
        exit 1
    fi
    echo "Operator pubkey: $OP_PUBKEY"
    OP_ADDR=$(derive_operator_address "$OP_PUBKEY")
    echo "Operator address: $OP_ADDR"
    echo ""
    echo "To register a Tier 1 LP:"
    echo "  1. Fund this address: bathron-cli sendmany '' '{\"$OP_ADDR\":5000}'"
    echo "  2. Register: python3 register_lp.py --endpoint <url> --operator-pubkey $OP_PUBKEY"
    ;;

status)
    echo "=== Registry Status ==="
    curl -s "$REGISTRY_URL/api/registry/status" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "Registry unreachable"
    echo ""
    echo "=== Registered LPs ==="
    show_registry
    ;;

*)
    echo "Usage: $0 [register [endpoint_url]|derive-addr|status]"
    echo ""
    echo "Commands:"
    echo "  register [url]  Register LP from operator address (Tier 1)"
    echo "  derive-addr     Show operator-derived address"
    echo "  status          Show registry status"
    exit 1
    ;;
esac
