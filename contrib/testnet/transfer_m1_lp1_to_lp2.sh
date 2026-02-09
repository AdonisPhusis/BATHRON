#!/bin/bash
# Transfer M1 receipt from LP1 (alice, OP1) to LP2 (dev, OP2)
# Usage: ./contrib/testnet/transfer_m1_lp1_to_lp2.sh

set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
OP1="ubuntu@57.131.33.152"
LP2_M1_ADDRESS="y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka"

# Receipt to transfer (~500K M1)
OUTPOINT="e16d6f62fa10402518d4b6597a81ece195142d4c14b6d0637f52a8ed007fe37e:0"

echo "=== Transfer M1 from LP1 (alice) to LP2 (dev) ==="
echo "Outpoint: $OUTPOINT"
echo "To: $LP2_M1_ADDRESS"
echo ""

# Execute transfer on OP1
ssh -i "$SSH_KEY" "$OP1" "\
    /home/ubuntu/bathron-cli -testnet transfer_m1 \
    '$OUTPOINT' \
    '$LP2_M1_ADDRESS'"

echo ""
echo "Done. Wait ~1 min for confirmation, then check:"
echo "  curl -s http://57.131.33.214:8080/api/sdk/m1/balance | python3 -m json.tool"
