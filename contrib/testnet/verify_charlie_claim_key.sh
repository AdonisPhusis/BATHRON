#!/bin/bash
# Verify why Charlie cannot claim the HTLC

set -e

SSH_KEY=~/.ssh/id_ed25519_vps
OP3_IP="51.75.31.44"    # charlie

CHARLIE_ADDR="yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"
HTLC_CLAIM_HASH="9c917ed22b3212a3435eafc246349c5720d13f39"

echo "==== Verify Charlie's Claim Key ===="
echo "Charlie's address: $CHARLIE_ADDR"
echo "HTLC claim hash160: $HTLC_CLAIM_HASH"
echo ""

echo "=== 1. Get Charlie's address info ==="
ADDR_INFO=$(ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet getaddressinfo \"$CHARLIE_ADDR\"")
echo "$ADDR_INFO"
echo ""

echo "=== 2. Extract scriptPubKey and check if address is in wallet ==="
SCRIPT_PUBKEY=$(echo "$ADDR_INFO" | python3 -c "import sys, json; print(json.load(sys.stdin).get('scriptPubKey', ''))")
IS_MINE=$(echo "$ADDR_INFO" | python3 -c "import sys, json; print(json.load(sys.stdin).get('ismine', False))")
HAS_KEY=$(echo "$ADDR_INFO" | python3 -c "import sys, json; print(json.load(sys.stdin).get('ismine', False))")

echo "ScriptPubKey: $SCRIPT_PUBKEY"
echo "Is Mine: $IS_MINE"
echo ""

echo "=== 3. Decode scriptPubKey to get hash160 ==="
python3 << PYTHON_EOF
script = "$SCRIPT_PUBKEY"
if len(script) == 50 and script[:6] == "76a914" and script[-4:] == "88ac":
    hash160 = script[6:-4]
    print(f"Charlie's hash160 from scriptPubKey: {hash160}")
    print(f"HTLC claim hash160:                  $HTLC_CLAIM_HASH")
    print(f"Match: {hash160 == '$HTLC_CLAIM_HASH'}")
else:
    print(f"Unexpected scriptPubKey format: {script}")
PYTHON_EOF
echo ""

echo "=== 4. Check if wallet has this key ==="
echo "Problem: ismine = $IS_MINE (should be true)"
echo ""

echo "=== 5. List all addresses in Charlie's wallet ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "/home/ubuntu/bathron-cli -testnet listreceivedbyaddress 0 true" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('Addresses in wallet:')
for entry in data:
    addr = entry.get('address', '')
    print(f\"  - {addr}\")
    if addr == '$CHARLIE_ADDR':
        print('    ^ THIS IS CHARLIE (claim address)')
"
echo ""

echo "=== 6. Check wallet.dat file ==="
ssh -i $SSH_KEY ubuntu@$OP3_IP "ls -lh ~/.bathron/testnet5/wallets/wallet.dat" || echo "Wallet file not found"
echo ""

echo "=== DIAGNOSIS ==="
if [ "$IS_MINE" = "True" ] || [ "$IS_MINE" = "true" ]; then
    echo "✓ Charlie's wallet HAS the claim key"
    echo "  This should work! Check if there's another issue."
else
    echo "✗ Charlie's wallet DOES NOT have the claim key"
    echo ""
    echo "PROBLEM IDENTIFIED:"
    echo "  The address $CHARLIE_ADDR is in the wallet, but marked as 'ismine: false'"
    echo "  This means the wallet does not have the PRIVATE KEY for this address."
    echo ""
    echo "POSSIBLE CAUSES:"
    echo "  1. Address was imported watch-only (without private key)"
    echo "  2. Wallet was restored from different seed/keys"
    echo "  3. Address belongs to different wallet"
    echo ""
    echo "SOLUTION:"
    echo "  Check ~/.BathronKey/wallet.json on OP3 and verify charlie's WIF"
    echo "  The WIF should correspond to address $CHARLIE_ADDR"
fi
