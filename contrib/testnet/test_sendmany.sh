#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"

ALICE="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
BOB="y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk"

echo "=== Test sendmany ==="

# Method 1: Try direct on server with proper escaping
echo ""
echo "Method 1: Direct command"
ssh $SSH_OPTS "ubuntu@$SEED_IP" "/home/ubuntu/bathron-cli -testnet sendmany \"\" '{\"$ALICE\":100,\"$BOB\":100}'" 2>&1 || true

# Method 2: Using heredoc
echo ""
echo "Method 2: Heredoc"
ssh $SSH_OPTS "ubuntu@$SEED_IP" bash << EOF
/home/ubuntu/bathron-cli -testnet sendmany "" '{"yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo":100,"y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk":100}'
EOF

# Method 3: Smaller amounts (maybe the issue is the amounts are in sats?)
echo ""
echo "Method 3: Smaller amounts (0.0001)"
ssh $SSH_OPTS "ubuntu@$SEED_IP" bash << 'EOF'
/home/ubuntu/bathron-cli -testnet sendmany "" '{"yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo":0.0001,"y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk":0.0001}'
EOF
