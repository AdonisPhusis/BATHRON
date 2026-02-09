#!/bin/bash
#
# Find where M0 is located in the network
#

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"
BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Finding M0 Owners                               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo "=== Known Addresses ==="
echo "  pilpous: xyszqryssGaNw13qpjbxB4PVoRqGat7RPd"
echo "  bob:     y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk"
echo "  alice:   yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
echo "  dev:     y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"
echo "  charlie: yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe"
echo ""

echo "=== Check settlement getstate (detailed) ==="
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI getstate" 2>/dev/null || echo "Error getting state"

echo ""
echo "=== Check pilpous address balance (via listunspent) ==="
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI listunspent 0 9999999 '[\"xyszqryssGaNw13qpjbxB4PVoRqGat7RPd\"]'" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
total = sum(u['amount'] for u in d)
print(f'  Total UTXOs: {len(d)}')
print(f'  Total amount: {total:.8f} BATH ({int(total * 100000000):,} sats)')
for u in d[:5]:
    print(f'    - {u[\"txid\"][:16]}...: {u[\"amount\"]:.8f}')
if len(d) > 5:
    print(f'    ... and {len(d) - 5} more')
" 2>/dev/null || echo "  Error"

echo ""
echo "=== Check M1 receipts (via RPC) ==="
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI getm1receiptsbyowner xyszqryssGaNw13qpjbxB4PVoRqGat7RPd" 2>/dev/null | head -20 || echo "  Command not available"

echo ""
echo "=== Wallet info on Seed ==="
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI getwalletinfo" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'  Wallet: {d.get(\"walletname\", \"default\")}')
print(f'  Balance: {d.get(\"balance\", 0):.8f} BATH')
print(f'  Unconfirmed: {d.get(\"unconfirmed_balance\", 0):.8f}')
print(f'  Immature: {d.get(\"immature_balance\", 0):.8f}')
" || echo "  Error"

echo ""
echo "=== listreceivedbyaddress (all addresses with balance) ==="
ssh $SSH_OPTS "ubuntu@$SEED_IP" "$BATHRON_CLI listreceivedbyaddress 0 true" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
d_with_balance = [x for x in d if x.get('amount', 0) > 0]
print(f'  Addresses with balance: {len(d_with_balance)}')
for addr in d_with_balance[:10]:
    print(f'    {addr[\"address\"]}: {addr[\"amount\"]:.8f} BATH')
" || echo "  Error"
