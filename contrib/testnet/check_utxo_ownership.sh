#!/bin/bash
# Check WHO owns the UTXOs returned by listunspent on each node
set -uo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

declare -A NAME IP CLI
NAME[1]="LP1 (alice)";    IP[1]="57.131.33.152"; CLI[1]="/home/ubuntu/bathron-cli -testnet"
NAME[2]="LP2 (dev)";      IP[2]="57.131.33.214"; CLI[2]="/home/ubuntu/bathron/bin/bathron-cli -testnet"
NAME[3]="User (charlie)"; IP[3]="51.75.31.44";   CLI[3]="/home/ubuntu/bathron-cli -testnet"
NAME[4]="Seed (pilpous)"; IP[4]="57.131.33.151"; CLI[4]="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

# Suspect addresses from listunspent (same on all nodes)
SUSPECT_ADDRS=("y6Fr8iBG1FyFtUF5eFhTKVhEq5ffGYq2rZ" "yECB6urPGC8kJQTYY9ANnzat16E1jTP3Nm" "xxnkhjeJUwLFeZwQvcEmek9JPh3FxJPJmx" "yExPXqqMskaZvRqtdGWCP3mUy2kbk6hxTM")

echo "============================================================"
echo "  UTXO OWNERSHIP INVESTIGATION"
echo "============================================================"
echo ""

# Check: are the suspect addresses imported keys or in the keypool?
for i in 1 2 3 4; do
    echo "=== ${NAME[$i]} (${IP[$i]}) ==="

    # Check wallet addresses
    WALLET_ADDR=$($SSH ubuntu@${IP[$i]} "cat ~/.BathronKey/wallet.json 2>/dev/null" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address','?'))" 2>/dev/null || echo "?")
    echo "  Primary address: $WALLET_ADDR"

    # Check each suspect address
    for ADDR in "${SUSPECT_ADDRS[@]}"; do
        INFO=$($SSH ubuntu@${IP[$i]} "${CLI[$i]} validateaddress $ADDR 2>/dev/null" || echo '{}')
        IS_MINE=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ismine', '?'))" 2>/dev/null || echo "?")
        IS_WATCH=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('iswatchonly', '?'))" 2>/dev/null || echo "?")
        IS_SCRIPT=$(echo "$INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('isscript', '?'))" 2>/dev/null || echo "?")
        echo "  $ADDR: ismine=$IS_MINE iswatchonly=$IS_WATCH isscript=$IS_SCRIPT"
    done

    # Count total addresses in wallet
    ADDR_LIST=$($SSH ubuntu@${IP[$i]} "${CLI[$i]} getaddressesbyaccount '' 2>/dev/null" || echo '[]')
    ADDR_COUNT=$(echo "$ADDR_LIST" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
    echo "  Total addresses in wallet: $ADDR_COUNT"

    # Show first 5 addresses
    echo "$ADDR_LIST" | python3 -c "
import sys,json
addrs = json.load(sys.stdin)
for a in addrs[:10]:
    print(f'    {a}')
if len(addrs)>10: print(f'    ... +{len(addrs)-10} more')
" 2>/dev/null || echo "    (error)"

    # Check if wallet has imported keys
    DUMP=$($SSH ubuntu@${IP[$i]} "${CLI[$i]} dumpwallet /tmp/wallet_check_$$.txt 2>&1; head -5 /tmp/wallet_check_$$.txt; rm -f /tmp/wallet_check_$$.txt" 2>/dev/null || echo "(error)")
    echo "  Wallet dump header: $(echo "$DUMP" | head -3)"

    echo ""
done

echo "============================================================"
echo "  KEY QUESTION: Are ALL nodes sharing the SAME wallet.dat?"
echo "  Or did setup_bathron_keys.sh import shared keys?"
echo "============================================================"
