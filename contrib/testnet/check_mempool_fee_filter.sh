#!/usr/bin/env bash
set -euo pipefail

KEY="~/.ssh/id_ed25519_vps"

echo "=== Mempool Fee Filter Check ==="
echo ""

echo "[Core - 162.19.251.75]"
ssh -i $KEY ubuntu@162.19.251.75 "~/BATHRON-Core/src/bathron-cli -testnet getmempoolinfo | jq '{size, bytes, mempoolminfee, minrelaytxfee}'"

echo ""
echo "[Seed - 57.131.33.151]"
ssh -i $KEY ubuntu@57.131.33.151 "~/BATHRON-Core/src/bathron-cli -testnet getmempoolinfo | jq '{size, bytes, mempoolminfee, minrelaytxfee}'"

echo ""
echo "[OP1 - 57.131.33.152]"
ssh -i $KEY ubuntu@57.131.33.152 "~/bathron-cli -testnet getmempoolinfo | jq '{size, bytes, mempoolminfee, minrelaytxfee}'"

echo ""
echo "[OP2 - 57.131.33.214]"
ssh -i $KEY ubuntu@57.131.33.214 "~/bathron-cli -testnet getmempoolinfo | jq '{size, bytes, mempoolminfee, minrelaytxfee}'"

echo ""
echo "[OP3 - 51.75.31.44]"
ssh -i $KEY ubuntu@51.75.31.44 "~/bathron-cli -testnet getmempoolinfo | jq '{size, bytes, mempoolminfee, minrelaytxfee}'"
