#!/bin/bash
# Check if wallet.dat is shared across nodes (same file = same keypool)
set -uo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

declare -A NAME IP CLI
NAME[1]="LP1 (alice)";    IP[1]="57.131.33.152"; CLI[1]="/home/ubuntu/bathron-cli -testnet"
NAME[2]="LP2 (dev)";      IP[2]="57.131.33.214"; CLI[2]="/home/ubuntu/bathron/bin/bathron-cli -testnet"
NAME[3]="User (charlie)"; IP[3]="51.75.31.44";   CLI[3]="/home/ubuntu/bathron-cli -testnet"
NAME[4]="Seed (pilpous)"; IP[4]="57.131.33.151"; CLI[4]="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
NAME[5]="CoreSDK (bob)";  IP[5]="162.19.251.75"; CLI[5]="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "============================================================"
echo "  WALLET.DAT IDENTITY CHECK"
echo "============================================================"
echo ""

echo "--- 1. wallet.dat file hash (SHA256) ---"
for i in 1 2 3 4 5; do
    HASH=$($SSH ubuntu@${IP[$i]} "sha256sum ~/.bathron/testnet5/wallet.dat 2>/dev/null | cut -d' ' -f1" || echo "(not found)")
    SIZE=$($SSH ubuntu@${IP[$i]} "stat -c%s ~/.bathron/testnet5/wallet.dat 2>/dev/null" || echo "?")
    echo "  ${NAME[$i]}: $HASH (${SIZE} bytes)"
done
echo ""

echo "--- 2. Wallet keypoolsize and HD chain ---"
for i in 1 2 3 4 5; do
    INFO=$($SSH ubuntu@${IP[$i]} "${CLI[$i]} getwalletinfo 2>/dev/null" || echo '{}')
    echo "  ${NAME[$i]}:"
    echo "$INFO" | python3 -c "
import sys,json
d = json.load(sys.stdin)
print(f'    keypoolsize: {d.get(\"keypoolsize\", \"?\")}')
print(f'    keypoolsize_hd_internal: {d.get(\"keypoolsize_hd_internal\", \"?\")}')
print(f'    hdmasterkeyid: {d.get(\"hdmasterkeyid\", \"?\")}')
print(f'    keypoololdest: {d.get(\"keypoololdest\", \"?\")}')
" 2>/dev/null || echo "    (parse error)"
done
echo ""

echo "--- 3. HD master key comparison ---"
echo "  If hdmasterkeyid is the SAME on all nodes → SAME wallet seed!"
echo "  If different → different wallets (with imported keys)"
echo ""

echo "--- 4. First 3 keypool addresses ---"
for i in 1 2 3 4 5; do
    echo "  ${NAME[$i]}:"
    for j in 1 2 3; do
        ADDR=$($SSH ubuntu@${IP[$i]} "${CLI[$i]} getnewaddress 'audit_check' 2>/dev/null" || echo "(error)")
        echo "    keypool[$j]: $ADDR"
    done
done
echo ""
echo "  If ALL nodes produce the SAME addresses → SAME wallet.dat / seed"
