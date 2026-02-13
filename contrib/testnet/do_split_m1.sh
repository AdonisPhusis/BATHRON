#!/usr/bin/env bash
# Direct split_m1 - debug version
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

LP1_IP="57.131.33.152"
CLI="/home/ubuntu/bathron-cli -testnet"

RECEIPT="2778640f8925a4c7536455a3b1ab2718ca1618fe73f2a93b9376db234a0a098f:1"
LP1_ADDR="yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
LP2_ADDR="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"

# 7,240,000 total: 30% = 2,172,000 to dev, rest - fee to alice
LP2_SHARE=2172000
FEE=200  # actual ~130 sats, pad for safety
LP1_SHARE=$((7240000 - LP2_SHARE - FEE))

echo "LP1: $LP1_SHARE  LP2: $LP2_SHARE  Fee: $FEE"
echo ""

# Write the command to a temp script on remote to avoid quoting hell
ssh $SSH_OPTS ubuntu@$LP1_IP "cat > /tmp/do_split.sh << 'REMOTEOF'
#!/bin/bash
CLI=\"/home/ubuntu/bathron-cli -testnet\"
RECEIPT=\"$RECEIPT\"
LP1_ADDR=\"$LP1_ADDR\"
LP2_ADDR=\"$LP2_ADDR\"
LP1_SHARE=$LP1_SHARE
LP2_SHARE=$LP2_SHARE

echo \"Executing split_m1...\"
\$CLI split_m1 \"\$RECEIPT\" \"[{\\\"address\\\":\\\"\$LP1_ADDR\\\",\\\"amount\\\":\$LP1_SHARE},{\\\"address\\\":\\\"\$LP2_ADDR\\\",\\\"amount\\\":\$LP2_SHARE}]\" 2>&1
echo \"Exit code: \$?\"
REMOTEOF
chmod +x /tmp/do_split.sh"

echo "=== Running split on OP1 ==="
ssh $SSH_OPTS ubuntu@$LP1_IP "bash /tmp/do_split.sh" 2>&1 || true
