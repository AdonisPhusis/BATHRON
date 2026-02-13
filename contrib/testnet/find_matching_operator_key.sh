#!/usr/bin/env bash
TARGET_PUBKEY="032b4d364d1bdf043bb174a8f719112b9d34ab4d86e1dbae0077fe1f0a5f6105d4"

echo "=== Finding Private Key for Operator Pubkey ==="
echo "Target: $TARGET_PUBKEY"
echo ""

# Extract all private keys from the dump
PRIVKEYS=(
    "cRziVzee2PKFZx282mGUbEKRqw8KUz4z6APB9t3R7hbHAjtdRZaK"
    "cTUtXNfqoF6ozJZyCFgZixtbTkJ1xCK2uSpMSoi2Ww64WL3mFdJa"
    "cQvp6t3Jz8MQ5FJEVM4ewucabskCfyhy73N1eP9c82xGxgEA71CX"
    "cVAUa3mjEm2uWYF9AUyX2rbpVmGTeuqtaEfkD4uniSMagP4LMmjR"
    "cVJBwUcE67QaY4dweZJDQ85Pn2uGsxxQb19geywCnBNU2BaStm7M"
    "cW6KvDfoZGEU5pi5Cdbd4hXX4HbbFrmdspgotuoDYMDvL9sSx656"
    "cNGsZAybYLobTycb4dzC2EXPWYqrUcutfgu5tYJwsjHzzriLr4V2"
    "cPZJb83r85B973wVvvAKWRGB2bxdQ4SshzHjyh92R5MqQBPm55R8"
    "cMpescQ91Z3DTJsVLjASNzw5vg7JmsxYeAjR7ne2cGGZyjPxYp8n"
    "cPfiMCaHZxN8XWCDTpK2boejcicXoZHFUWGJR4nDAzUqT7yR9pcp"
)

LABELS=("op_mn4" "op_mn7" "pilpous" "op_mn1" "op_mn3" "op_mn6" "op_seed_mn" "op_mn5" "op_mn2" "op_mn8")

# Test each key locally
for i in "${!PRIVKEYS[@]}"; do
    WIF="${PRIVKEYS[$i]}"
    LABEL="${LABELS[$i]}"
    
    # Get pubkey from bathron-cli
    PUBKEY=$(./src/bathron-cli -testnet validateaddress "$WIF" 2>/dev/null | jq -r '.pubkey' 2>/dev/null || echo "")
    
    if [ "$PUBKEY" = "$TARGET_PUBKEY" ]; then
        echo "FOUND! Label: $LABEL"
        echo "Private Key: $WIF"
        exit 0
    fi
done

echo "Not found in standard operator keys. Checking if it's a generated operator key..."
echo "The key might have been generated during ProReg and saved separately."
