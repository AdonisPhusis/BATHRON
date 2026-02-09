#!/bin/bash
# =============================================================================
# setup_vps_keys.sh - Configure 1 wallet per VPS (simplified structure)
# =============================================================================
#
# RÈGLE: 1 VPS = 1 Wallet dédié
#
# Seed     → pilpous (MN owner - collateral)
# CoreSDK  → bob     (P&A service)
# OP1      → alice   (LP)
# OP2      → dev     (Admin)
# OP3      → charlie (Fake user)
#
# Fichier: ~/.keys/wallet.json (mode 600)
#
# =============================================================================

set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# SSH config
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# VPS IPs
SEED_IP="57.131.33.151"
CORESDK_IP="162.19.251.75"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"
OP3_IP="51.75.31.44"

# =============================================================================
# WALLET DEFINITIONS (1 per VPS)
# =============================================================================

# Seed → pilpous (MN owner - collateral)
PILPOUS_ADDR="xyszqryssGaNw13qpjbxB4PVoRqGat7RPd"
PILPOUS_WIF="cQvp6t3Jz8MQ5FJEVM4ewucabskCfyhy73N1eP9c82xGxgEA71CX"

# CoreSDK → bob (P&A service)
BOB_ADDR="y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk"
BOB_WIF="cNNCM6nSmDydVCL3zqdDzUS44tJ9LGMDck1A22fvKrrUgsYS4eMm"

# OP1 → alice (LP)
ALICE_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
ALICE_WIF="cTuaDJPC5HvAYD4XzFxWUszUDfVeSmaN47N6qvCxnpaucgeYzxb2"

# OP2 → dev (admin ops)
DEV_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"
DEV_WIF="cSNJfpBoKt43ojNuvG7TjkxsUiTdXy6HihcKxBewNgk5jALCXYaa"

# OP3 → charlie (fake user)
CHARLIE_ADDR="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"
CHARLIE_WIF="cPtPSZLkcufXMryYoCTr63zkPDGPtYWxbZ24NGBWzDfzJUuZaEbE"

# MN Operator keys (Seed only)
MN1_OP_WIF="cVAUa3mjEm2uWYF9AUyX2rbpVmGTeuqtaEfkD4uniSMagP4LMmjR"
MN2_OP_WIF="cMpescQ91Z3DTJsVLjASNzw5vg7JmsxYeAjR7ne2cGGZyjPxYp8n"
MN3_OP_WIF="cVJBwUcE67QaY4dweZJDQ85Pn2uGsxxQb19geywCnBNU2BaStm7M"
MN4_OP_WIF="cRziVzee2PKFZx282mGUbEKRqw8KUz4z6APB9t3R7hbHAjtdRZaK"
MN5_OP_WIF="cPZJb83r85B973wVvvAKWRGB2bxdQ4SshzHjyh92R5MqQBPm55R8"
MN6_OP_WIF="cW6KvDfoZGEU5pi5Cdbd4hXX4HbbFrmdspgotuoDYMDvL9sSx656"
MN7_OP_WIF="cTUtXNfqoF6ozJZyCFgZixtbTkJ1xCK2uSpMSoi2Ww64WL3mFdJa"
MN8_OP_WIF="cPfiMCaHZxN8XWCDTpK2boejcicXoZHFUWGJR4nDAzUqT7yR9pcp"
SEED_MN_OP_WIF="cNGsZAybYLobTycb4dzC2EXPWYqrUcutfgu5tYJwsjHzzriLr4V2"

# =============================================================================
# SETUP FUNCTIONS (1 wallet per VPS)
# =============================================================================

setup_seed() {
    log_step "Setting up SEED ($SEED_IP) → wallet: pilpous (MN owner)"

    $SSH ubuntu@$SEED_IP "
        mkdir -p ~/.keys
        chmod 700 ~/.keys

        # Main wallet: pilpous (MN collateral owner)
        cat > ~/.keys/wallet.json << 'EOF'
{
  \"_vps\": \"Seed\",
  \"_role\": \"MN Owner - holds collateral for 8 masternodes\",
  \"name\": \"pilpous\",
  \"address\": \"$PILPOUS_ADDR\",
  \"wif\": \"$PILPOUS_WIF\"
}
EOF

        # MN Operators (separate file)
        cat > ~/.keys/operators.json << 'EOF'
{
  \"_description\": \"MN Operator Keys - Seed manages 8 MNs\",
  \"mn1\": \"$MN1_OP_WIF\",
  \"mn2\": \"$MN2_OP_WIF\",
  \"mn3\": \"$MN3_OP_WIF\",
  \"mn4\": \"$MN4_OP_WIF\",
  \"mn5\": \"$MN5_OP_WIF\",
  \"mn6\": \"$MN6_OP_WIF\",
  \"mn7\": \"$MN7_OP_WIF\",
  \"mn8\": \"$MN8_OP_WIF\",
  \"seed_mn\": \"$SEED_MN_OP_WIF\"
}
EOF

        chmod 600 ~/.keys/*.json
        echo 'Wallet: pilpous (MN owner)'
        echo 'Address: $PILPOUS_ADDR'
    "

    log_ok "Seed configured (wallet: pilpous)"
}

setup_coresdk() {
    log_step "Setting up CoreSDK ($CORESDK_IP) → wallet: bob"

    $SSH ubuntu@$CORESDK_IP "
        mkdir -p ~/.keys
        chmod 700 ~/.keys

        cat > ~/.keys/wallet.json << 'EOF'
{
  \"_vps\": \"CoreSDK\",
  \"_role\": \"P&A Swap Service - fee collection\",
  \"name\": \"bob\",
  \"address\": \"$BOB_ADDR\",
  \"wif\": \"$BOB_WIF\"
}
EOF

        chmod 600 ~/.keys/*.json
        echo 'Wallet: bob'
        echo 'Address: $BOB_ADDR'
    "

    log_ok "CoreSDK configured (wallet: bob)"
}

setup_op1() {
    log_step "Setting up OP1 ($OP1_IP) → wallet: alice (LP)"

    $SSH ubuntu@$OP1_IP "
        mkdir -p ~/.keys
        chmod 700 ~/.keys

        cat > ~/.keys/wallet.json << 'EOF'
{
  \"_vps\": \"OP1\",
  \"_role\": \"Liquidity Provider - M1 + BTC for swaps\",
  \"name\": \"alice\",
  \"address\": \"$ALICE_ADDR\",
  \"wif\": \"$ALICE_WIF\",
  \"btc_wallet\": \"lp_wallet\",
  \"btc_address\": \"tb1qnc742c35fpra5zfnk9rfw7yplvzdxyfkrt4ckt\"
}
EOF

        chmod 600 ~/.keys/*.json
        echo 'Wallet: alice (LP)'
        echo 'Address BATHRON: $ALICE_ADDR'
        echo 'Address BTC: tb1qnc742c35fpra5zfnk9rfw7yplvzdxyfkrt4ckt'
    "

    log_ok "OP1 configured (wallet: alice)"
}

setup_op2() {
    log_step "Setting up OP2 ($OP2_IP) → wallet: dev (Admin)"

    $SSH ubuntu@$OP2_IP "
        mkdir -p ~/.keys
        chmod 700 ~/.keys

        cat > ~/.keys/wallet.json << 'EOF'
{
  \"_vps\": \"OP2\",
  \"_role\": \"Admin/Dev - for testing and admin operations\",
  \"name\": \"dev\",
  \"address\": \"$DEV_ADDR\",
  \"wif\": \"$DEV_WIF\"
}
EOF

        chmod 600 ~/.keys/*.json
        echo 'Wallet: dev (Admin)'
        echo 'Address: $DEV_ADDR'
    "

    log_ok "OP2 configured (wallet: dev)"
}

setup_op3() {
    log_step "Setting up OP3 ($OP3_IP) → wallet: charlie (Fake User)"

    $SSH ubuntu@$OP3_IP "
        mkdir -p ~/.keys
        chmod 700 ~/.keys

        cat > ~/.keys/wallet.json << 'EOF'
{
  \"_vps\": \"OP3\",
  \"_role\": \"Fake User - simulates retail user for swap tests\",
  \"name\": \"charlie\",
  \"address\": \"$CHARLIE_ADDR\",
  \"wif\": \"$CHARLIE_WIF\",
  \"btc_wallet\": \"fake_user\",
  \"btc_address\": \"tb1qkd2kyur0yqxpp6hvtwheukwpfjt2h5atapyhe7\"
}
EOF

        chmod 600 ~/.keys/*.json
        echo 'Wallet: charlie (Fake User)'
        echo 'Address BATHRON: $CHARLIE_ADDR'
        echo 'Address BTC: tb1qkd2kyur0yqxpp6hvtwheukwpfjt2h5atapyhe7'
    "

    log_ok "OP3 configured (wallet: charlie)"
}

show_summary() {
    log_step "VPS Wallet Summary (1 wallet per VPS)"

    echo ""
    echo "┌────────────┬──────────┬─────────────────────────────────────────┐"
    echo "│ VPS        │ Wallet   │ Address                                 │"
    echo "├────────────┼──────────┼─────────────────────────────────────────┤"
    echo "│ Seed (MN)  │ pilpous  │ $PILPOUS_ADDR │"
    echo "│ CoreSDK    │ bob      │ $BOB_ADDR │"
    echo "│ OP1 (LP)   │ alice    │ $ALICE_ADDR │"
    echo "│ OP2 (Admin)│ dev      │ $DEV_ADDR │"
    echo "│ OP3 (User) │ charlie  │ $CHARLIE_ADDR │"
    echo "└────────────┴──────────┴─────────────────────────────────────────┘"
    echo ""
    echo "All keys stored in: ~/.keys/wallet.json (mode 600)"
    echo ""
}

import_keys_to_wallets() {
    log_step "Importing keys to BATHRON wallets"

    # Seed (repo) - pilpous
    echo "Importing on Seed (pilpous)..."
    $SSH ubuntu@$SEED_IP "
        CLI=/home/ubuntu/BATHRON-Core/src/bathron-cli
        \$CLI -testnet importprivkey '$PILPOUS_WIF' 'pilpous' true 2>/dev/null || echo '  Already imported'
    " 2>/dev/null || echo "  Warning: Could not import on Seed"

    # CoreSDK (repo) - bob
    echo "Importing on CoreSDK (bob)..."
    $SSH ubuntu@$CORESDK_IP "
        CLI=/home/ubuntu/BATHRON-Core/src/bathron-cli
        \$CLI -testnet importprivkey '$BOB_WIF' 'bob' true 2>/dev/null || echo '  Already imported'
    " 2>/dev/null || echo "  Warning: Could not import on CoreSDK"

    # OP1 (bin) - alice
    echo "Importing on OP1 (alice)..."
    $SSH ubuntu@$OP1_IP "
        CLI=/home/ubuntu/bathron-cli
        \$CLI -testnet importprivkey '$ALICE_WIF' 'alice' true 2>/dev/null || echo '  Already imported'
    " 2>/dev/null || echo "  Warning: Could not import on OP1"

    # OP2 (bin) - dev
    echo "Importing on OP2 (dev)..."
    $SSH ubuntu@$OP2_IP "
        CLI=/home/ubuntu/bathron-cli
        \$CLI -testnet importprivkey '$DEV_WIF' 'dev' true 2>/dev/null || echo '  Already imported'
    " 2>/dev/null || echo "  Warning: Could not import on OP2"

    # OP3 (bin) - charlie
    echo "Importing on OP3 (charlie)..."
    $SSH ubuntu@$OP3_IP "
        CLI=/home/ubuntu/bathron-cli
        \$CLI -testnet importprivkey '$CHARLIE_WIF' 'charlie' true 2>/dev/null || echo '  Already imported'
    " 2>/dev/null || echo "  Warning: Could not import on OP3"

    log_ok "Keys imported to wallets"
}

verify_setup() {
    log_step "Verifying wallet setup on all VPS"

    echo ""
    for NODE in "$SEED_IP:Seed:repo" "$CORESDK_IP:CoreSDK:repo" "$OP1_IP:OP1:bin" "$OP2_IP:OP2:bin" "$OP3_IP:OP3:bin"; do
        IP=$(echo $NODE | cut -d: -f1)
        NAME=$(echo $NODE | cut -d: -f2)
        TYPE=$(echo $NODE | cut -d: -f3)

        if [ "$TYPE" = "repo" ]; then
            CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
        else
            CLI="/home/ubuntu/bathron-cli -testnet"
        fi

        echo -n "  $NAME ($IP): "
        RESULT=$($SSH ubuntu@$IP "
            if [ -f ~/.keys/wallet.json ]; then
                NAME=\$(cat ~/.keys/wallet.json | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"name\",\"?\"))' 2>/dev/null)
                echo \"wallet=\$NAME\"
            else
                echo 'NO WALLET FILE'
            fi
        " 2>/dev/null) || RESULT="SSH ERROR"
        echo "$RESULT"
    done
    echo ""
}

case "${1:-help}" in
    seed)
        setup_seed
        ;;
    coresdk)
        setup_coresdk
        ;;
    op1|lp)
        setup_op1
        ;;
    op2|admin)
        setup_op2
        ;;
    op3|user)
        setup_op3
        ;;
    all)
        setup_seed
        setup_coresdk
        setup_op1
        setup_op2
        setup_op3
        show_summary
        ;;
    import)
        import_keys_to_wallets
        ;;
    verify)
        verify_setup
        ;;
    full)
        setup_seed
        setup_coresdk
        setup_op1
        setup_op2
        setup_op3
        import_keys_to_wallets
        show_summary
        ;;
    summary)
        show_summary
        ;;
    *)
        echo "Usage: $0 {seed|coresdk|op1|op2|op3|all|import|verify|full|summary}"
        echo ""
        echo "Commands:"
        echo "  seed     - Setup wallet on Seed (pilpous - MN owner)"
        echo "  coresdk  - Setup wallet on CoreSDK (bob - P&A service)"
        echo "  op1      - Setup wallet on OP1 (alice - LP)"
        echo "  op2      - Setup wallet on OP2 (dev - Admin)"
        echo "  op3      - Setup wallet on OP3 (charlie - Fake User)"
        echo "  all      - Setup wallets on all VPS"
        echo "  import   - Import keys to BATHRON wallets"
        echo "  verify   - Verify wallet setup on all VPS"
        echo "  full     - Setup + import all"
        echo "  summary  - Show wallet summary"
        echo ""
        echo "Structure: 1 wallet per VPS"
        echo "  Seed     → pilpous (MN owner)"
        echo "  CoreSDK  → bob (P&A service)"
        echo "  OP1      → alice (LP)"
        echo "  OP2      → dev (Admin)"
        echo "  OP3      → charlie (Fake User)"
        ;;
esac
