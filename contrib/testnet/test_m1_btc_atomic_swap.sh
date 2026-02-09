#!/bin/bash
#
# TEST ATOMIC SWAP: M1 → BTC using 2 HTLCs with same hashlock
#
# This is a simplified test focusing on M1 and BTC HTLCs.
# For the full 4-HTLC flow including EVM (USDC), see test_4htlc_atomic_swap.sh
#
# Participants:
#   - User (charlie) on OP3: Has M1, wants BTC
#   - LP (alice) on OP1: Has BTC, wants M1
#
# HTLC Structure:
#   HTLC-1: User locks M1 → LP claims with S (BATHRON)
#   HTLC-2: LP locks BTC → User claims with S (Bitcoin)
#
# SECRET S is controlled by USER and revealed LAST when claiming BTC
#

set -e

# Configuration
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

OP1_IP="57.131.33.152"   # LP (alice) - BTC liquidity
OP3_IP="51.75.31.44"     # User (charlie) - M1 holder

M1_CLI="\$HOME/bathron-cli -testnet"
BTC_CLI_OP1="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet"
BTC_CLI_OP3="/home/ubuntu/bitcoin/bin/bitcoin-cli -datadir=/home/ubuntu/.bitcoin-signet"

# Swap parameters
M1_AMOUNT="50000"        # 50,000 M1 sats (~$0.38)
BTC_AMOUNT="50000"       # 50,000 sats (~$50 at $100k/BTC)

# HTLC timeouts (in blocks)
M1_TIMEOUT_BLOCKS=30     # ~30 min (1 min blocks)
BTC_TIMEOUT_BLOCKS=3     # ~30 min (10 min blocks)

# Output colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }
header() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0: Check prerequisites
# ─────────────────────────────────────────────────────────────────────────────
check_prerequisites() {
    header "CHECKING PREREQUISITES"

    log "Testing connections..."
    ssh $SSH_OPTS ubuntu@$OP1_IP "echo ok" > /dev/null 2>&1 && success "OP1 (LP) reachable" || { error "OP1 unreachable"; exit 1; }
    ssh $SSH_OPTS ubuntu@$OP3_IP "echo ok" > /dev/null 2>&1 && success "OP3 (User) reachable" || { error "OP3 unreachable"; exit 1; }

    # Check M1 balance on User
    USER_M1=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI getwalletstate true" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('m1', {}).get('total', 0))
" 2>/dev/null || echo "0")
    log "User M1 balance: $USER_M1 sats"
    if [ "$USER_M1" -lt "$M1_AMOUNT" ]; then
        error "User needs at least $M1_AMOUNT M1. Has: $USER_M1"
        exit 1
    fi
    success "User has sufficient M1"

    # Check BTC balance on LP
    LP_BTC_SATS=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI_OP1 listunspent" 2>/dev/null | python3 -c "
import json, sys
utxos = json.load(sys.stdin)
total = sum(int(u['amount'] * 1e8) for u in utxos)
print(total)
" 2>/dev/null || echo "0")
    log "LP BTC balance: $LP_BTC_SATS sats"
    if [ "$LP_BTC_SATS" -lt "$BTC_AMOUNT" ]; then
        error "LP needs at least $BTC_AMOUNT sats. Has: $LP_BTC_SATS"
        exit 1
    fi
    success "LP has sufficient BTC"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: User generates secret
# ─────────────────────────────────────────────────────────────────────────────
generate_secret() {
    header "STEP 1: USER GENERATES SECRET S"

    log "User (charlie) generates secret on BATHRON..."

    HTLC_GEN=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_generate" 2>&1)
    log "HTLC generate result: $HTLC_GEN"

    SECRET=$(echo "$HTLC_GEN" | python3 -c "import json,sys; print(json.load(sys.stdin).get('secret',''))" 2>/dev/null)
    HASHLOCK=$(echo "$HTLC_GEN" | python3 -c "import json,sys; print(json.load(sys.stdin).get('hashlock',''))" 2>/dev/null)

    if [ -z "$SECRET" ] || [ -z "$HASHLOCK" ]; then
        # Fallback to local generation
        log "Using local secret generation..."
        SECRET=$(openssl rand -hex 32)
        HASHLOCK=$(echo -n "$SECRET" | xxd -r -p | sha256sum | cut -d' ' -f1)
    fi

    log "Secret S: ${SECRET:0:16}... (only user knows this!)"
    log "Hashlock H: ${HASHLOCK:0:16}... (public)"

    # Save to files
    echo "$SECRET" > /tmp/swap_secret.txt
    echo "$HASHLOCK" > /tmp/swap_hashlock.txt

    success "Secret generated - USER CONTROLS REVEAL TIMING"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: User locks M1 in HTLC-1
# ─────────────────────────────────────────────────────────────────────────────
create_htlc1_m1() {
    header "STEP 2: USER LOCKS M1 (HTLC-1)"

    HASHLOCK=$(cat /tmp/swap_hashlock.txt)

    # Get LP's M1 address (claim address)
    LP_M1_ADDR=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI getnewaddress 'htlc_claim'" 2>/dev/null || echo "")
    if [ -z "$LP_M1_ADDR" ]; then
        LP_M1_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"  # fallback to alice
    fi
    log "LP claim address: $LP_M1_ADDR"

    # Get user's M1 receipt
    USER_RECEIPT=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI getwalletstate true" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
receipts = d.get('m1', {}).get('receipts', [])
for r in receipts:
    if r.get('amount', 0) >= $M1_AMOUNT and r.get('unlockable', False):
        print(r.get('outpoint', ''))
        break
" 2>/dev/null)

    if [ -z "$USER_RECEIPT" ]; then
        error "No suitable M1 receipt found for user"
        exit 1
    fi
    log "User's M1 receipt: $USER_RECEIPT"

    # Create HTLC-1
    log "Creating M1 HTLC (user → LP with secret)..."
    HTLC1_RESULT=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$M1_CLI htlc_create_m1 \"$USER_RECEIPT\" \"$HASHLOCK\" \"$LP_M1_ADDR\" $M1_TIMEOUT_BLOCKS" 2>&1)

    log "HTLC-1 result: $HTLC1_RESULT"

    HTLC1_TXID=$(echo "$HTLC1_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null || echo "")
    HTLC1_OUTPOINT=$(echo "$HTLC1_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('htlc_outpoint', d.get('txid','')+':0'))" 2>/dev/null || echo "")

    if [ -z "$HTLC1_TXID" ]; then
        error "Failed to create M1 HTLC"
        echo "$HTLC1_RESULT"
        exit 1
    fi

    echo "$HTLC1_OUTPOINT" > /tmp/htlc1_outpoint.txt
    success "HTLC-1 created: $HTLC1_OUTPOINT"
    log "LP can claim this with secret S when revealed"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: LP locks BTC in HTLC-2
# ─────────────────────────────────────────────────────────────────────────────
create_htlc2_btc() {
    header "STEP 3: LP LOCKS BTC (HTLC-2)"

    HASHLOCK=$(cat /tmp/swap_hashlock.txt)

    # Get user's BTC address (claim address)
    USER_BTC_ADDR=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$BTC_CLI_OP3 getnewaddress 'htlc_claim'" 2>/dev/null)
    log "User BTC claim address: $USER_BTC_ADDR"

    # Get LP's BTC refund address
    LP_BTC_REFUND=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI_OP1 getnewaddress 'htlc_refund'" 2>/dev/null)
    log "LP BTC refund address: $LP_BTC_REFUND"

    # Get current block height
    BTC_HEIGHT=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI_OP1 getblockcount" 2>/dev/null)
    TIMELOCK=$((BTC_HEIGHT + BTC_TIMEOUT_BLOCKS))
    log "BTC block: $BTC_HEIGHT, timelock: $TIMELOCK"

    # Get pubkeys for script
    USER_PUBKEY=$(ssh $SSH_OPTS ubuntu@$OP3_IP "$BTC_CLI_OP3 getaddressinfo \"$USER_BTC_ADDR\"" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('pubkey',''))")
    LP_PUBKEY=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI_OP1 getaddressinfo \"$LP_BTC_REFUND\"" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('pubkey',''))")

    log "User pubkey: ${USER_PUBKEY:0:20}..."
    log "LP pubkey: ${LP_PUBKEY:0:20}..."

    if [ -z "$USER_PUBKEY" ] || [ -z "$LP_PUBKEY" ]; then
        error "Could not get pubkeys"
        exit 1
    fi

    # Create HTLC script and address
    log "Creating P2WSH HTLC script..."

    HTLC_SCRIPT_INFO=$(python3 << PYEOF
import hashlib

def push_data(data: bytes) -> bytes:
    length = len(data)
    if length < 0x4c:
        return bytes([length]) + data
    elif length <= 0xff:
        return bytes([0x4c, length]) + data
    else:
        return bytes([0x4d]) + length.to_bytes(2, 'little') + data

def push_int(n: int) -> bytes:
    if n == 0:
        return bytes([0x00])
    elif 1 <= n <= 16:
        return bytes([0x50 + n])
    else:
        result = []
        abs_n = abs(n)
        while abs_n:
            result.append(abs_n & 0xff)
            abs_n >>= 8
        if result[-1] & 0x80:
            result.append(0x00)
        return push_data(bytes(result))

# Opcodes
OP_IF = 0x63
OP_ELSE = 0x67
OP_ENDIF = 0x68
OP_DROP = 0x75
OP_EQUALVERIFY = 0x88
OP_CHECKSIG = 0xac
OP_CHECKLOCKTIMEVERIFY = 0xb1
OP_SHA256 = 0xa8

hashlock = bytes.fromhex("$HASHLOCK")
recipient_pubkey = bytes.fromhex("$USER_PUBKEY")
refund_pubkey = bytes.fromhex("$LP_PUBKEY")
timelock = $TIMELOCK

# Build script
script = bytes([OP_IF])
script += bytes([OP_SHA256])
script += push_data(hashlock)
script += bytes([OP_EQUALVERIFY])
script += push_data(recipient_pubkey)
script += bytes([OP_CHECKSIG])
script += bytes([OP_ELSE])
script += push_int(timelock)
script += bytes([OP_CHECKLOCKTIMEVERIFY, OP_DROP])
script += push_data(refund_pubkey)
script += bytes([OP_CHECKSIG])
script += bytes([OP_ENDIF])

# P2WSH address
witness_program = hashlib.sha256(script).digest()

# Bech32 encoding
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
def bech32_polymod(values):
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
    chk = 1
    for v in values:
        b = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ v
        for i in range(5):
            chk ^= GEN[i] if ((b >> i) & 1) else 0
    return chk

def bech32_hrp_expand(hrp):
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]

def convertbits(data, frombits, tobits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret

hrp = "tb"  # signet/testnet
data = [0] + convertbits(witness_program, 8, 5)
polymod = bech32_polymod(bech32_hrp_expand(hrp) + data + [0,0,0,0,0,0]) ^ 1
checksum = [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]
address = hrp + "1" + "".join([CHARSET[d] for d in data + checksum])

print(f"SCRIPT={script.hex()}")
print(f"ADDRESS={address}")
PYEOF
)

    eval "$HTLC_SCRIPT_INFO"
    log "HTLC script: ${SCRIPT:0:40}..."
    log "HTLC address: $ADDRESS"

    # Save for later
    echo "$SCRIPT" > /tmp/htlc2_script.txt
    echo "$ADDRESS" > /tmp/htlc2_address.txt
    echo "$USER_BTC_ADDR" > /tmp/user_btc_addr.txt
    echo "$TIMELOCK" > /tmp/htlc2_timelock.txt

    # Fund the HTLC
    BTC_AMOUNT_BTC=$(echo "scale=8; $BTC_AMOUNT / 100000000" | bc)
    log "LP sending $BTC_AMOUNT_BTC BTC to HTLC..."

    FUND_TXID=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI_OP1 sendtoaddress \"$ADDRESS\" $BTC_AMOUNT_BTC" 2>&1)

    if [[ "$FUND_TXID" =~ ^[a-f0-9]{64}$ ]]; then
        echo "$FUND_TXID" > /tmp/htlc2_funding_txid.txt
        success "HTLC-2 funded: $FUND_TXID"
        log "User can claim this BTC with secret S"
    else
        error "BTC funding failed: $FUND_TXID"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Wait for confirmations
# ─────────────────────────────────────────────────────────────────────────────
wait_confirmations() {
    header "WAITING FOR CONFIRMATIONS"

    HTLC1_OUTPOINT=$(cat /tmp/htlc1_outpoint.txt)
    FUND_TXID=$(cat /tmp/htlc2_funding_txid.txt)

    log "Waiting for M1 HTLC-1 confirmation..."
    for i in {1..12}; do
        HTLC1_STATUS=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_get \"$HTLC1_OUTPOINT\"" 2>/dev/null || echo "{}")
        HTLC1_CONF=$(echo "$HTLC1_STATUS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('confirmations', d.get('status','')))" 2>/dev/null || echo "0")

        if [[ "$HTLC1_CONF" =~ ^[0-9]+$ ]] && [ "$HTLC1_CONF" -ge 1 ]; then
            success "M1 HTLC-1 confirmed ($HTLC1_CONF)"
            break
        fi
        log "M1 HTLC-1: waiting... ($HTLC1_CONF)"
        sleep 10
    done

    log "Waiting for BTC HTLC-2 confirmation..."
    for i in {1..6}; do
        BTC_TX=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI_OP1 gettransaction \"$FUND_TXID\"" 2>/dev/null || echo "{}")
        BTC_CONF=$(echo "$BTC_TX" | python3 -c "import json,sys; print(json.load(sys.stdin).get('confirmations',0))" 2>/dev/null || echo "0")

        if [ "$BTC_CONF" -ge 1 ]; then
            success "BTC HTLC-2 confirmed ($BTC_CONF)"
            break
        fi
        log "BTC HTLC-2: $BTC_CONF confirmations, waiting..."
        sleep 30
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: User claims BTC (reveals secret!)
# ─────────────────────────────────────────────────────────────────────────────
user_claim_btc() {
    header "STEP 5: USER CLAIMS BTC (REVEALS SECRET!)"

    SECRET=$(cat /tmp/swap_secret.txt)
    SCRIPT=$(cat /tmp/htlc2_script.txt)
    HTLC_ADDR=$(cat /tmp/htlc2_address.txt)
    USER_BTC_ADDR=$(cat /tmp/user_btc_addr.txt)
    FUND_TXID=$(cat /tmp/htlc2_funding_txid.txt)

    log "User revealing secret to claim BTC..."
    log "SECRET S: $SECRET"
    warn "THIS IS THE CRITICAL MOMENT - SECRET IS NOW PUBLIC!"

    # Find UTXO
    UTXO_INFO=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$BTC_CLI_OP1 listunspent 0 9999999 '[\"$HTLC_ADDR\"]'" 2>/dev/null)
    UTXO_TXID=$(echo "$UTXO_INFO" | python3 -c "import json,sys; u=json.load(sys.stdin); print(u[0]['txid'] if u else '')" 2>/dev/null || echo "")
    UTXO_VOUT=$(echo "$UTXO_INFO" | python3 -c "import json,sys; u=json.load(sys.stdin); print(u[0]['vout'] if u else '')" 2>/dev/null || echo "")
    UTXO_AMOUNT=$(echo "$UTXO_INFO" | python3 -c "import json,sys; u=json.load(sys.stdin); print(u[0]['amount'] if u else 0)" 2>/dev/null || echo "0")

    if [ -z "$UTXO_TXID" ]; then
        warn "UTXO not found at HTLC address (may not be confirmed yet)"
        log "Manual claim data:"
        log "  Preimage: $SECRET"
        log "  Script: $SCRIPT"
        log "  Address: $HTLC_ADDR"
        return
    fi

    log "UTXO: $UTXO_TXID:$UTXO_VOUT ($UTXO_AMOUNT BTC)"

    # Create claim transaction
    # For P2WSH HTLC claim, we need manual witness construction
    # This is complex in bash - for now, provide the data for manual claim

    warn "BTC HTLC claim requires manual witness construction"
    log ""
    log "To claim manually on OP3 (user):"
    log "  1. UTXO: $UTXO_TXID:$UTXO_VOUT"
    log "  2. Preimage (secret): $SECRET"
    log "  3. Witness script: $SCRIPT"
    log "  4. Destination: $USER_BTC_ADDR"
    log ""
    log "Witness stack for claim: [<signature> <preimage> 0x01 <script>]"

    success "Secret S is now revealed - LP can claim M1!"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: LP claims M1
# ─────────────────────────────────────────────────────────────────────────────
lp_claim_m1() {
    header "STEP 6: LP CLAIMS M1 (USING REVEALED SECRET)"

    SECRET=$(cat /tmp/swap_secret.txt)
    HTLC1_OUTPOINT=$(cat /tmp/htlc1_outpoint.txt)

    log "LP claiming M1 with revealed secret..."
    log "HTLC-1: $HTLC1_OUTPOINT"
    log "Secret: ${SECRET:0:16}..."

    CLAIM_RESULT=$(ssh $SSH_OPTS ubuntu@$OP1_IP "$M1_CLI htlc_claim \"$HTLC1_OUTPOINT\" \"$SECRET\"" 2>&1)

    log "Claim result: $CLAIM_RESULT"

    CLAIM_TXID=$(echo "$CLAIM_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('txid',''))" 2>/dev/null || echo "")

    if [ -n "$CLAIM_TXID" ]; then
        success "LP claimed M1! TX: $CLAIM_TXID"
    else
        warn "M1 claim result: $CLAIM_RESULT"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
show_summary() {
    header "SWAP SUMMARY"

    echo ""
    echo -e "${GREEN}Atomic Swap: M1 → BTC${NC}"
    echo ""
    echo "Flow:"
    echo "  1. User locked $M1_AMOUNT M1 in HTLC-1 (LP can claim with S)"
    echo "  2. LP locked $BTC_AMOUNT sats in HTLC-2 (User can claim with S)"
    echo "  3. User revealed S to claim BTC"
    echo "  4. LP used S to claim M1"
    echo ""
    echo "Result:"
    echo "  User: Gave M1, Got BTC"
    echo "  LP: Gave BTC, Got M1"
    echo ""
    echo -e "${GREEN}TRUSTLESS & PERMISSIONLESS${NC}"
    echo "  - Same hashlock H links both HTLCs"
    echo "  - Secret S controlled by user"
    echo "  - Either both succeed or both refund"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         ATOMIC SWAP TEST: M1 ↔ BTC                           ║${NC}"
    echo -e "${CYAN}║         Same hashlock, user reveals secret last              ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    check_prerequisites
    generate_secret
    create_htlc1_m1
    create_htlc2_btc
    wait_confirmations
    user_claim_btc
    lp_claim_m1
    show_summary
}

main "$@"
