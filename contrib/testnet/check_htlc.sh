#!/usr/bin/env bash
set -euo pipefail

CORESDK_IP="162.19.251.75"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
HTLC_TX_HEX="03002800017a7c3aabce49a3f76f9763312b992ee662aa53608a30fa86c7c44ea264fb7ff6010000006946304302204633fca73e700ed4e3376ee665dbd2d0f589e130458f1e61603a3fce6468af7a021f24c884e3b76399436d07548223f47a870668db6332fd4b7f9720a1ef8dbf4601210254b196e85741429833c045cdd405c275846fcf74de43345a657ac697131befccffffffff01fc2600000000000017a914d9a6ecd5a7ba01880575e12f4542be7a33db7d1e870000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"

echo "[$(date +%H:%M:%S)] Checking HTLC status on Core+SDK node ($CORESDK_IP)"
echo ""

echo "1. Checking if bathrond is running..."
$SSH ubuntu@$CORESDK_IP 'pgrep -a bathrond || echo "No bathrond process found"'
echo ""

echo "2. Checking recent HTLC entries in debug.log..."
$SSH ubuntu@$CORESDK_IP 'grep -i htlc ~/.bathron/testnet5/debug.log 2>/dev/null | tail -20 || echo "No HTLC entries found in debug.log"'
echo ""

echo "3. Checking mempool..."
$SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getrawmempool'
echo ""

echo "4. Attempting to broadcast HTLC transaction..."
$SSH ubuntu@$CORESDK_IP "~/bathron-cli -testnet sendrawtransaction '$HTLC_TX_HEX'" || true
echo ""

echo "5. Checking block height and finality status..."
$SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getblockcount'
$SSH ubuntu@$CORESDK_IP '~/bathron-cli -testnet getfinalitystatus' || true
echo ""

echo "[$(date +%H:%M:%S)] HTLC diagnostic complete"
