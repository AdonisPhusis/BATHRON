#!/bin/bash
# Check if getwalletstate returns WALLET-SPECIFIC or GLOBAL data
set -uo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

declare -A NAME IP CLI
NAME[1]="LP1 (alice)";    IP[1]="57.131.33.152"; CLI[1]="/home/ubuntu/bathron-cli -testnet"
NAME[2]="LP2 (dev)";      IP[2]="57.131.33.214"; CLI[2]="/home/ubuntu/bathron/bin/bathron-cli -testnet"
NAME[3]="User (charlie)"; IP[3]="51.75.31.44";   CLI[3]="/home/ubuntu/bathron-cli -testnet"
NAME[4]="CoreSDK (bob)";  IP[4]="162.19.251.75"; CLI[4]="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
NAME[5]="Seed (pilpous)"; IP[5]="57.131.33.151"; CLI[5]="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"

echo "============================================================"
echo "  BATHRON WALLET OWNERSHIP CHECK"
echo "  Is getwalletstate per-wallet or global?"
echo "============================================================"
echo ""

for i in 1 2 3 4 5; do
    echo "=== ${NAME[$i]} (${IP[$i]}) ==="

    # Get wallet address
    WALLET_ADDR=$($SSH ubuntu@${IP[$i]} "cat ~/.BathronKey/wallet.json 2>/dev/null" | python3 -c "import sys,json; print(json.load(sys.stdin).get('address','?'))" 2>/dev/null || echo "?")
    WALLET_NAME=$($SSH ubuntu@${IP[$i]} "cat ~/.BathronKey/wallet.json 2>/dev/null" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name','?'))" 2>/dev/null || echo "?")
    echo "  Wallet: $WALLET_NAME ($WALLET_ADDR)"

    # Raw getwalletstate
    RAW=$($SSH ubuntu@${IP[$i]} "${CLI[$i]} getwalletstate true 2>/dev/null" || echo '{}')

    echo "$RAW" | python3 -c "
import sys, json
d = json.load(sys.stdin)

# M0
m0 = d.get('m0', {})
print(f'  M0 balance: {m0.get(\"balance\", 0)} sats')
print(f'  M0 locked:  {m0.get(\"locked\", 0)} sats')

# M1 receipts
m1 = d.get('m1', {})
receipts = m1.get('receipts', [])
total = m1.get('total', 0)
print(f'  M1 total: {total} sats ({len(receipts)} receipts)')
for r in receipts:
    op = r.get('outpoint', '?')
    amt = r.get('amount', 0)
    unlockable = r.get('unlockable', '?')
    # Check if receipt has owner/address info
    extra_keys = [k for k in r.keys() if k not in ('outpoint', 'amount', 'unlockable')]
    extra = ', '.join(f'{k}={r[k]}' for k in extra_keys) if extra_keys else ''
    print(f'    {op}: {amt} sats (unlockable={unlockable}) {extra}')

# Check if there's wallet-specific info
all_keys = list(d.keys())
print(f'  Top-level keys: {all_keys}')
" 2>/dev/null || echo "  (parse error)"

    # Also try listunspent to compare
    echo "  --- listunspent (wallet-specific UTXO) ---"
    UNSPENT=$($SSH ubuntu@${IP[$i]} "${CLI[$i]} listunspent 0 9999999 2>/dev/null" || echo '[]')
    echo "$UNSPENT" | python3 -c "
import sys, json
utxos = json.load(sys.stdin)
total = sum(u.get('amount',0) for u in utxos)
print(f'  UTXOs: {len(utxos)}, total: {total} (in coin units)')
for u in utxos[:5]:
    addr = u.get('address','?')
    amt = u.get('amount',0)
    print(f'    {u.get(\"txid\",\"?\")[:16]}...: {amt} to {addr}')
if len(utxos) > 5:
    print(f'    ... +{len(utxos)-5} more')
" 2>/dev/null || echo "  (parse error)"

    # Also check getbalance
    BALANCE=$($SSH ubuntu@${IP[$i]} "${CLI[$i]} getbalance 2>/dev/null" || echo "?")
    echo "  getbalance: $BALANCE"

    echo ""
done

echo "============================================================"
echo "  ANALYSIS"
echo "============================================================"
echo ""
echo "If ALL nodes show the SAME M1 receipts → getwalletstate shows GLOBAL state"
echo "If each node shows DIFFERENT M1 receipts → getwalletstate shows WALLET state"
echo "If ALL nodes show SAME M0 balance → likely GLOBAL (not wallet-specific)"
