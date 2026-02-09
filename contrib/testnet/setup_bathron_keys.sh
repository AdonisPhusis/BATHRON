#!/bin/bash
# =============================================================================
# setup_bathron_keys.sh - Initialize secure key storage (~/.BathronKey/)
# =============================================================================
#
# Creates the secure key directory structure on all VPS nodes.
# Keys are stored in JSON format with mode 600.
#
# Structure:
#   ~/.BathronKey/
#   ├── wallet.json      # Main wallet (1 per VPS)
#   ├── operators.json   # MN operator keys (Seed only)
#   ├── evm.json         # EVM wallet (if applicable)
#   └── btc.json         # BTC wallet credentials (if applicable)
#
# NEVER commit ~/.BathronKey/ to git!
# =============================================================================

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"

# VPS IPs
SEED_IP="57.131.33.151"
CORESDK_IP="162.19.251.75"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"
OP3_IP="51.75.31.44"

# Colors
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

log() { echo -e "${B}[INFO]${N} $1"; }
ok() { echo -e "${G}[OK]${N} $1"; }
warn() { echo -e "${Y}[WARN]${N} $1"; }
err() { echo -e "${R}[ERROR]${N} $1"; }

# =============================================================================
# KEY DEFINITIONS (will be written to secure files, then removed from here)
# =============================================================================

# These keys should be loaded from environment or secure prompt
# For initial setup only - after setup, keys live ONLY in ~/.BathronKey/

setup_seed_keys() {
    local IP=$SEED_IP
    log "Setting up Seed ($IP)..."

    ssh $SSH_OPTS ubuntu@$IP 'bash -s' << 'EOF'
mkdir -p ~/.BathronKey
chmod 700 ~/.BathronKey

# Main wallet (pilpous)
cat > ~/.BathronKey/wallet.json << 'WALLET'
{
  "name": "pilpous",
  "role": "mn_owner",
  "address": "xyszqryssGaNw13qpjbxB4PVoRqGat7RPd",
  "wif": "cQvp6t3Jz8MQ5FJEVM4ewucabskCfyhy73N1eP9c82xGxgEA71CX"
}
WALLET

# MN Operator keys (8 MNs)
cat > ~/.BathronKey/operators.json << 'OPERATORS'
{
  "mn1": {"wif": "cVAUa3mjEm2uWYF9AUyX2rbpVmGTeuqtaEfkD4uniSMagP4LMmjR"},
  "mn2": {"wif": "cMpescQ91Z3DTJsVLjASNzw5vg7JmsxYeAjR7ne2cGGZyjPxYp8n"},
  "mn3": {"wif": "cVJBwUcE67QaY4dweZJDQ85Pn2uGsxxQb19geywCnBNU2BaStm7M"},
  "mn4": {"wif": "cRziVzee2PKFZx282mGUbEKRqw8KUz4z6APB9t3R7hbHAjtdRZaK"},
  "mn5": {"wif": "cPZJb83r85B973wVvvAKWRGB2bxdQ4SshzHjyh92R5MqQBPm55R8"},
  "mn6": {"wif": "cW6KvDfoZGEU5pi5Cdbd4hXX4HbbFrmdspgotuoDYMDvL9sSx656"},
  "mn7": {"wif": "cTUtXNfqoF6ozJZyCFgZixtbTkJ1xCK2uSpMSoi2Ww64WL3mFdJa"},
  "mn8": {"wif": "cPfiMCaHZxN8XWCDTpK2boejcicXoZHFUWGJR4nDAzUqT7yR9pcp"},
  "seed_mn": {"wif": "cNGsZAybYLobTycb4dzC2EXPWYqrUcutfgu5tYJwsjHzzriLr4V2"}
}
OPERATORS

chmod 600 ~/.BathronKey/*.json
echo "Seed keys configured"
EOF
    ok "Seed"
}

setup_coresdk_keys() {
    local IP=$CORESDK_IP
    log "Setting up CoreSDK ($IP)..."

    ssh $SSH_OPTS ubuntu@$IP 'bash -s' << 'EOF'
mkdir -p ~/.BathronKey
chmod 700 ~/.BathronKey

cat > ~/.BathronKey/wallet.json << 'WALLET'
{
  "name": "bob",
  "role": "pna_service",
  "address": "y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk",
  "wif": "cNNCM6nSmDydVCL3zqdDzUS44tJ9LGMDck1A22fvKrrUgsYS4eMm"
}
WALLET

chmod 600 ~/.BathronKey/*.json
echo "CoreSDK keys configured"
EOF
    ok "CoreSDK"
}

setup_op1_keys() {
    local IP=$OP1_IP
    log "Setting up OP1 - LP ($IP)..."

    ssh $SSH_OPTS ubuntu@$IP 'bash -s' << 'EOF'
mkdir -p ~/.BathronKey
chmod 700 ~/.BathronKey

cat > ~/.BathronKey/wallet.json << 'WALLET'
{
  "name": "alice",
  "role": "liquidity_provider",
  "address": "yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo",
  "wif": "cTuaDJPC5HvAYD4XzFxWUszUDfVeSmaN47N6qvCxnpaucgeYzxb2",
  "btc_address": "tb1qnc742c35fpra5zfnk9rfw7yplvzdxyfkrt4ckt"
}
WALLET

# BTC credentials (from ~/.bitcoin-signet/.lp_credentials if exists)
if [ -f ~/.bitcoin-signet/.lp_credentials ]; then
    cp ~/.bitcoin-signet/.lp_credentials ~/.BathronKey/btc.json
fi

chmod 600 ~/.BathronKey/*.json
echo "OP1 (LP) keys configured"
EOF
    ok "OP1 (LP)"
}

setup_op2_keys() {
    local IP=$OP2_IP
    log "Setting up OP2 - Dev ($IP)..."

    ssh $SSH_OPTS ubuntu@$IP 'bash -s' << 'EOF'
mkdir -p ~/.BathronKey
chmod 700 ~/.BathronKey

cat > ~/.BathronKey/wallet.json << 'WALLET'
{
  "name": "dev",
  "role": "admin_ops",
  "address": "y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka",
  "wif": "cSNJfpBoKt43ojNuvG7TjkxsUiTdXy6HihcKxBewNgk5jALCXYaa"
}
WALLET

chmod 600 ~/.BathronKey/*.json
echo "OP2 (Dev) keys configured"
EOF
    ok "OP2 (Dev)"
}

setup_op3_keys() {
    local IP=$OP3_IP
    log "Setting up OP3 - Fake User ($IP)..."

    ssh $SSH_OPTS ubuntu@$IP 'bash -s' << 'EOF'
mkdir -p ~/.BathronKey
chmod 700 ~/.BathronKey

cat > ~/.BathronKey/wallet.json << 'WALLET'
{
  "name": "charlie",
  "role": "fake_user",
  "address": "yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe",
  "wif": "cPtPSZLkcufXMryYoCTr63zkPDGPtYWxbZ24NGBWzDfzJUuZaEbE",
  "btc_address": "tb1qkd2kyur0yqxpp6hvtwheukwpfjt2h5atapyhe7"
}
WALLET

chmod 600 ~/.BathronKey/*.json
echo "OP3 (Fake User) keys configured"
EOF
    ok "OP3 (Fake User)"
}

verify_keys() {
    echo ""
    log "Verifying key setup on all VPS..."
    echo ""

    for VPS in "Seed:$SEED_IP" "CoreSDK:$CORESDK_IP" "OP1:$OP1_IP" "OP2:$OP2_IP" "OP3:$OP3_IP"; do
        NAME=$(echo $VPS | cut -d: -f1)
        IP=$(echo $VPS | cut -d: -f2)

        RESULT=$(ssh $SSH_OPTS ubuntu@$IP 'ls -la ~/.BathronKey/ 2>/dev/null && cat ~/.BathronKey/wallet.json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d.get(\"name\")}: {d.get(\"address\")}\")" 2>/dev/null || echo "NOT CONFIGURED"')

        if [[ "$RESULT" == *"NOT CONFIGURED"* ]]; then
            err "$NAME ($IP): Not configured"
        else
            ok "$NAME ($IP): $RESULT"
        fi
    done
}

show_status() {
    echo ""
    echo "=== ~/.BathronKey/ Status ==="
    echo ""

    for VPS in "Seed:$SEED_IP" "CoreSDK:$CORESDK_IP" "OP1:$OP1_IP" "OP2:$OP2_IP" "OP3:$OP3_IP"; do
        NAME=$(echo $VPS | cut -d: -f1)
        IP=$(echo $VPS | cut -d: -f2)

        echo "$NAME ($IP):"
        ssh $SSH_OPTS ubuntu@$IP 'ls -la ~/.BathronKey/ 2>/dev/null || echo "  Directory not found"' | sed 's/^/  /'
        echo ""
    done
}

# =============================================================================
# MAIN
# =============================================================================

case "${1:-}" in
    seed)
        setup_seed_keys
        ;;
    coresdk)
        setup_coresdk_keys
        ;;
    op1)
        setup_op1_keys
        ;;
    op2)
        setup_op2_keys
        ;;
    op3)
        setup_op3_keys
        ;;
    all)
        setup_seed_keys
        setup_coresdk_keys
        setup_op1_keys
        setup_op2_keys
        setup_op3_keys
        verify_keys
        ;;
    verify)
        verify_keys
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: $0 {seed|coresdk|op1|op2|op3|all|verify|status}"
        echo ""
        echo "Commands:"
        echo "  seed     - Setup keys on Seed VPS"
        echo "  coresdk  - Setup keys on CoreSDK VPS"
        echo "  op1      - Setup keys on OP1 (LP) VPS"
        echo "  op2      - Setup keys on OP2 (Dev) VPS"
        echo "  op3      - Setup keys on OP3 (Fake User) VPS"
        echo "  all      - Setup all VPS"
        echo "  verify   - Verify key setup"
        echo "  status   - Show ~/.BathronKey/ status"
        exit 1
        ;;
esac
