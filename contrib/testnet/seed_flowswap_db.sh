#!/bin/bash
# Seed the FlowSwap DB on OP1 with the first completed E2E swap
# Usage: ./contrib/testnet/seed_flowswap_db.sh
# NOTE: Run deploy_pna_lp.sh deploy AFTER this script to restart with data loaded
set -euo pipefail

OP1="57.131.33.152"
SSH="ssh -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10 ubuntu@${OP1}"

DB_PATH="/home/ubuntu/.bathron/flowswap_db.json"

echo "=== Seed FlowSwap DB on OP1 ==="

echo "  Writing seed data (first E2E swap)..."
$SSH "mkdir -p /home/ubuntu/.bathron && cat > $DB_PATH" <<'SEED_EOF'
{
  "fs_7bddd0aa9f73467c": {
    "swap_id": "fs_7bddd0aa9f73467c",
    "state": "completed",
    "from_asset": "BTC",
    "to_asset": "USDC",
    "btc_amount_sats": 3000,
    "m1_amount_sats": 0,
    "usdc_amount": 2.09,
    "H_user": "2940376b51e08a8fcbde7e30ac07e4dbf3f2c0822d713fa8ab8b43f3992e2ee1",
    "H_lp1": "",
    "H_lp2": "",
    "btc_htlc_address": "",
    "btc_redeem_script": "",
    "btc_timelock": 0,
    "btc_fund_txid": "305097a9ad6de324c13e0648f455d5ee05940374c6443b3d48f5c66413d88642",
    "btc_claim_txid": "4712a0623fcb10539aaa50555cfa9044243c7010975d5bcff249667d83247776",
    "m1_htlc_outpoint": "",
    "m1_htlc_txid": "38a2cb07045c1782b9484f8772df83be86db6c1316c2d68eabfad0574c8e3331",
    "m1_claim_txid": null,
    "evm_htlc_id": "",
    "evm_lock_txhash": "",
    "evm_claim_txhash": "0x63f0eb9d81b335edb4929e0d61e4682d454846d8a99ae0bbe385a114c21aec0f",
    "user_usdc_address": "0x9f11B03618DeE8f12E7F90e753093B613CeD51D2",
    "user_btc_refund_pubkey": "",
    "created_at": 1738782000,
    "updated_at": 1738782600,
    "completed_at": 1738782600
  }
}
SEED_EOF

echo "  Verifying..."
COUNT=$($SSH "python3 -c 'import json; d=json.load(open(\"$DB_PATH\")); print(len(d))'" 2>/dev/null || echo "error")
echo "  Entries written: $COUNT"
echo ""
echo "=== Now run: ./contrib/testnet/deploy_pna_lp.sh deploy ==="
