#!/bin/bash
# Check actual roles on each VPS

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=== Checking VPS Roles ==="
echo ""

for NODE in "57.131.33.151:Seed" "162.19.251.75:CoreSDK" "57.131.33.152:OP1" "57.131.33.214:OP2" "51.75.31.44:OP3"; do
    IP=$(echo $NODE | cut -d: -f1)
    NAME=$(echo $NODE | cut -d: -f2)

    echo "=== $NAME ($IP) ==="

    # Determine CLI path
    if [ "$IP" = "57.131.33.151" ] || [ "$IP" = "162.19.251.75" ]; then
        CLI="/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet"
    else
        CLI="/home/ubuntu/bathron-cli -testnet"
    fi

    $SSH ubuntu@$IP "
        # Check MN status
        echo 'MN Status:'
        $CLI getactivemnstatus 2>/dev/null | head -5 || echo '  No MN'

        # Check what's running
        echo ''
        echo 'Processes:'
        ps aux | grep -E 'bathrond|python|server.py|daemon' | grep -v grep | awk '{print \"  \" \$11, \$12, \$13}' | head -5

        # Check wallet balance
        echo ''
        echo 'Wallet:'
        $CLI getbalance 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); print(f\"  M0: {d.get(\"m0\",0)}, M1: {d.get(\"m1\",0)}\")' 2>/dev/null || echo '  No wallet'
    " 2>/dev/null

    echo ""
done
