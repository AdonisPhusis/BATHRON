#!/bin/bash
# Fix LP BTC addresses: ensure wallet.json, btc.json, and Bitcoin Core wallet are consistent.
# Also documents the current state of all LP addresses.
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

# LP configurations
declare -A LP_NAME LP_IP LP_BTC_CLI LP_BTC_DATADIR LP_BTC_WALLET
LP_NAME[1]="LP1 (alice)"
LP_IP[1]="57.131.33.152"
LP_BTC_CLI[1]="/home/ubuntu/bitcoin/bin/bitcoin-cli"
LP_BTC_DATADIR[1]="/home/ubuntu/.bitcoin-signet"
LP_BTC_WALLET[1]="alice_lp"

LP_NAME[2]="LP2 (dev)"
LP_IP[2]="57.131.33.214"
LP_BTC_CLI[2]="/home/ubuntu/bitcoin/bin/bitcoin-cli"
LP_BTC_DATADIR[2]="/home/ubuntu/.bitcoin-signet"
LP_BTC_WALLET[2]="lp2_wallet"

ACTION="${1:-status}"

for i in 1 2; do
    echo ""
    echo "============================================================"
    echo "  ${LP_NAME[$i]} — ${LP_IP[$i]}"
    echo "============================================================"
    IP="${LP_IP[$i]}"
    BTC_CLI="${LP_BTC_CLI[$i]}"
    BTC_DATADIR="${LP_BTC_DATADIR[$i]}"
    BTC_WALLET="${LP_BTC_WALLET[$i]}"

    echo ""
    echo "--- 1. ~/.BathronKey/wallet.json ---"
    WALLET_JSON=$($SSH ubuntu@${IP} "cat ~/.BathronKey/wallet.json 2>/dev/null || echo '{}'")
    WALLET_BTC=$(echo "$WALLET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc_address','(not set)'))" 2>/dev/null || echo "(parse error)")
    WALLET_M1=$(echo "$WALLET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address','(not set)'))" 2>/dev/null || echo "(parse error)")
    WALLET_NAME=$(echo "$WALLET_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','(not set)'))" 2>/dev/null || echo "(parse error)")
    echo "  name:        $WALLET_NAME"
    echo "  btc_address: $WALLET_BTC"
    echo "  m1_address:  $WALLET_M1"

    echo ""
    echo "--- 2. ~/.BathronKey/btc.json ---"
    BTC_JSON=$($SSH ubuntu@${IP} "cat ~/.BathronKey/btc.json 2>/dev/null || echo '{}'")
    BTC_JSON_ADDR=$(echo "$BTC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address','(not set)'))" 2>/dev/null || echo "(parse error)")
    BTC_JSON_PUBKEY=$(echo "$BTC_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pubkey','(not set)'))" 2>/dev/null || echo "(parse error)")
    BTC_JSON_CLAIM_WIF=$(echo "$BTC_JSON" | python3 -c "import sys,json; w=json.load(sys.stdin).get('claim_wif','(not set)'); print(w[:8]+'...' if len(w)>8 else w)" 2>/dev/null || echo "(parse error)")
    echo "  address:   $BTC_JSON_ADDR"
    echo "  pubkey:    $BTC_JSON_PUBKEY"
    echo "  claim_wif: $BTC_JSON_CLAIM_WIF"

    echo ""
    echo "--- 3. ~/.BathronKey/evm.json ---"
    EVM_JSON=$($SSH ubuntu@${IP} "cat ~/.BathronKey/evm.json 2>/dev/null || echo '{}'")
    EVM_ADDR=$(echo "$EVM_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address','(not set)'))" 2>/dev/null || echo "(parse error)")
    echo "  address: $EVM_ADDR"

    echo ""
    echo "--- 4. Bitcoin Core wallet ($BTC_WALLET) ---"
    BC_ADDR=$($SSH ubuntu@${IP} "$BTC_CLI -signet -datadir=$BTC_DATADIR -rpcwallet=$BTC_WALLET getnewaddress 'lp_check' bech32 2>/dev/null" || echo "(wallet not found)")
    BC_BALANCE=$($SSH ubuntu@${IP} "$BTC_CLI -signet -datadir=$BTC_DATADIR -rpcwallet=$BTC_WALLET getbalance 2>/dev/null" || echo "(error)")
    BC_LISTADDR=$($SSH ubuntu@${IP} "$BTC_CLI -signet -datadir=$BTC_DATADIR -rpcwallet=$BTC_WALLET listreceivedbyaddress 0 true 2>/dev/null | python3 -c \"import sys,json; [print(f'  {a[\\\"address\\\"]}: {a[\\\"amount\\\"]} BTC') for a in json.load(sys.stdin)]\"" 2>/dev/null || echo "  (error listing)")
    echo "  balance:   $BC_BALANCE BTC"
    echo "  addresses with funds:"
    echo "$BC_LISTADDR"

    echo ""
    echo "--- 5. LP server reported address ---"
    LP_URL="http://${IP}:8080"
    LP_WALLETS=$(curl -s "${LP_URL}/api/wallets" 2>/dev/null || echo '{}')
    LP_BTC_ADDR=$(echo "$LP_WALLETS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc',{}).get('address','(not set)'))" 2>/dev/null || echo "(error)")
    LP_BTC_BAL=$(echo "$LP_WALLETS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('btc',{}).get('balance',0))" 2>/dev/null || echo "(error)")
    echo "  address: $LP_BTC_ADDR"
    echo "  balance: $LP_BTC_BAL BTC"

    echo ""
    echo "--- 6. Consistency check ---"
    if [ "$WALLET_BTC" = "$BTC_JSON_ADDR" ] && [ "$WALLET_BTC" = "$LP_BTC_ADDR" ]; then
        echo "  ✓ All BTC addresses match: $WALLET_BTC"
    else
        echo "  ✗ MISMATCH detected:"
        echo "    wallet.json:  $WALLET_BTC"
        echo "    btc.json:     $BTC_JSON_ADDR"
        echo "    LP server:    $LP_BTC_ADDR"
        echo ""
        if [ "$ACTION" = "fix" ]; then
            echo "  → Fixing: using btc.json address ($BTC_JSON_ADDR) as source of truth"
            echo "    (btc.json has the private key for HTLC claims)"

            # Update wallet.json btc_address to match btc.json
            if [ "$WALLET_BTC" != "$BTC_JSON_ADDR" ] && [ "$BTC_JSON_ADDR" != "(not set)" ]; then
                echo "  → Updating wallet.json btc_address..."
                $SSH ubuntu@${IP} "python3 -c \"
import json
with open('/home/ubuntu/.BathronKey/wallet.json') as f:
    w = json.load(f)
w['btc_address'] = '$BTC_JSON_ADDR'
with open('/home/ubuntu/.BathronKey/wallet.json', 'w') as f:
    json.dump(w, f, indent=2)
print('Updated wallet.json btc_address to $BTC_JSON_ADDR')
\""
            fi

            echo "  → Restart LP server to pick up changes"
        else
            echo "  Run with 'fix' to update wallet.json to match btc.json"
        fi
    fi

    # Also check scantxoutset for the btc.json address
    if [ "$BTC_JSON_ADDR" != "(not set)" ] && [ "$BTC_JSON_ADDR" != "$LP_BTC_ADDR" ]; then
        echo ""
        echo "--- 7. Scan UTXO for btc.json address ---"
        SCAN=$($SSH ubuntu@${IP} "$BTC_CLI -signet -datadir=$BTC_DATADIR scantxoutset start '[\"addr($BTC_JSON_ADDR)\"]' 2>/dev/null" || echo '{}')
        SCAN_TOTAL=$(echo "$SCAN" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_amount',0))" 2>/dev/null || echo "0")
        echo "  btc.json addr ($BTC_JSON_ADDR): $SCAN_TOTAL BTC"

        SCAN2=$($SSH ubuntu@${IP} "$BTC_CLI -signet -datadir=$BTC_DATADIR scantxoutset start '[\"addr($LP_BTC_ADDR)\"]' 2>/dev/null" || echo '{}')
        SCAN2_TOTAL=$(echo "$SCAN2" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_amount',0))" 2>/dev/null || echo "0")
        echo "  LP server addr ($LP_BTC_ADDR): $SCAN2_TOTAL BTC"
    fi
done

echo ""
echo "============================================================"
echo "  DOCUMENTED ADDRESSES (CLAUDE.md)"
echo "============================================================"
echo "  LP1 alice_btc: tb1qc4ayevq4g7j4de52x8lkcxeffe3kqms6etvcrl"
echo "  LP2 dev_btc:   tb1qg964rs32wn4msnzzfcks5knd9fy9tp7jt7urhh"
echo ""
echo "  LP1 alice_evm: 0x78F5e39850C222742Ac06a304893080883F1270c"
echo "  LP2 dev_evm:   0xd6Fc9ED2b3530aCc4a9e4966Ca92Ed0Cf5D2D80f"
echo ""
echo "Done."
