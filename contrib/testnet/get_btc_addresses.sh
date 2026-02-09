#!/bin/bash
# =============================================================================
# get_btc_addresses.sh - Get/create fixed BTC addresses for LP and Fake User
# =============================================================================

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

OP1_IP="57.131.33.152"
OP3_IP="51.75.31.44"

BTC_CLI="/home/ubuntu/bitcoin/bin/bitcoin-cli -signet -datadir=/home/ubuntu/.bitcoin-signet"

echo "=== BTC Addresses (Fixed) ==="
echo ""

# OP1 (LP)
echo "OP1 (LP - alice):"
OP1_ADDR=$($SSH ubuntu@$OP1_IP "$BTC_CLI -rpcwallet=lp_wallet getnewaddress 'lp_fixed' 'bech32' 2>/dev/null" || echo "")
if [ -z "$OP1_ADDR" ]; then
    # Try to get existing address
    OP1_ADDR=$($SSH ubuntu@$OP1_IP "$BTC_CLI -rpcwallet=lp_wallet listreceivedbyaddress 0 true 2>/dev/null | python3 -c \"import sys,json; addrs=json.load(sys.stdin); print(addrs[0]['address'] if addrs else '')\"" 2>/dev/null || echo "N/A")
fi
echo "  BTC: $OP1_ADDR"

# OP3 (Fake User)
echo ""
echo "OP3 (Fake User - charlie):"
OP3_ADDR=$($SSH ubuntu@$OP3_IP "$BTC_CLI -rpcwallet=fake_user getnewaddress 'user_fixed' 'bech32' 2>/dev/null" || echo "")
if [ -z "$OP3_ADDR" ]; then
    OP3_ADDR=$($SSH ubuntu@$OP3_IP "$BTC_CLI -rpcwallet=fake_user listreceivedbyaddress 0 true 2>/dev/null | python3 -c \"import sys,json; addrs=json.load(sys.stdin); print(addrs[0]['address'] if addrs else '')\"" 2>/dev/null || echo "N/A")
fi
echo "  BTC: $OP3_ADDR"

echo ""
echo "=== Summary ==="
echo "OP1_BTC=$OP1_ADDR"
echo "OP3_BTC=$OP3_ADDR"
