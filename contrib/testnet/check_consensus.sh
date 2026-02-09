#!/bin/bash
# Check if all nodes are on same chain

SEED_IP="57.131.33.151"
CORESDK_IP="162.19.251.75"
OP1_IP="57.131.33.152"
OP2_IP="57.131.33.214"
OP3_IP="51.75.31.44"

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "════════════════════════════════════════════════════════════════"
echo "  Consensus Check - Block Hashes"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Get a recent block height to check
HEIGHT=5276

echo "Checking block $HEIGHT hash on all nodes:"
echo ""

for NAME_IP in "Seed:$SEED_IP" "Core+SDK:$CORESDK_IP" "OP1:$OP1_IP" "OP2:$OP2_IP" "OP3:$OP3_IP"; do
    NAME="${NAME_IP%%:*}"
    IP="${NAME_IP##*:}"
    
    HASH=$($SSH ubuntu@$IP "~/bathron-cli -testnet getblockhash $HEIGHT 2>/dev/null || echo 'ERROR'")
    printf "%-12s %s\n" "$NAME:" "${HASH:0:16}..."
done

echo ""
echo "If all hashes match → network is in consensus"
echo "If hashes differ → FORK detected"
