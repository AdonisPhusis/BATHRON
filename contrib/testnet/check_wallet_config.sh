#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
BATHRON_CLI="/home/ubuntu/bathron-cli -testnet"

for VPS in "Seed:57.131.33.151" "CoreSDK:162.19.251.75" "OP1:57.131.33.152" "OP2:57.131.33.214" "OP3:51.75.31.44"; do
    NAME=$(echo $VPS | cut -d: -f1)
    IP=$(echo $VPS | cut -d: -f2)

    echo "=== $NAME ($IP) ==="

    # Check wallet.dat location
    ssh $SSH_OPTS "ubuntu@$IP" "ls -la ~/.bathron/testnet5/wallet.dat 2>/dev/null" || echo "  wallet.dat not found"

    # Get wallet info
    ssh $SSH_OPTS "ubuntu@$IP" "$BATHRON_CLI getwalletinfo 2>/dev/null | head -5" || echo "  getwalletinfo failed"

    # Check if addresses are imported
    echo "  Checking address ownership..."
    ssh $SSH_OPTS "ubuntu@$IP" "$BATHRON_CLI getaddressinfo yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(f'    alice addr ismine: {d.get(\\\"ismine\\\", False)}')\"" || echo "    error"
    ssh $SSH_OPTS "ubuntu@$IP" "$BATHRON_CLI getaddressinfo y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk 2>/dev/null | python3 -c \"import sys,json; d=json.load(sys.stdin); print(f'    bob addr ismine: {d.get(\\\"ismine\\\", False)}')\"" || echo "    error"

    echo ""
done
