#!/bin/bash
# diagnose_mn_failure.sh - Diagnose why MN registration failed
# v2.0 - Deep diagnosis of collateral UTXO issues

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"
SEED_IP="57.131.33.151"

echo "=== MN Registration Deep Diagnostic v2.0 ==="
echo ""

$SSH ubuntu@$SEED_IP 'bash -s' << 'REMOTE'
CLI="/home/ubuntu/bathron-cli -datadir=/home/ubuntu/.bathron -testnet"

echo "=== 1. Chain State ==="
HEIGHT=$($CLI getblockcount 2>/dev/null)
echo "Height: $HEIGHT"
echo "Best block: $($CLI getbestblockhash 2>/dev/null | cut -c1-16)..."

echo ""
echo "=== 2. Burn Claims Status ==="
CLAIMS=$($CLI listburnclaims 2>/dev/null)
TOTAL=$(echo "$CLAIMS" | jq 'length' 2>/dev/null || echo "0")
FINAL=$(echo "$CLAIMS" | jq '[.[] | select(.db_status=="final")] | length' 2>/dev/null || echo "0")
TOTAL_1M=$(echo "$CLAIMS" | jq '[.[] | select(.burned_sats==1000000)] | length' 2>/dev/null || echo "0")
echo "Total claims: $TOTAL (finalized: $FINAL, 1M burns: $TOTAL_1M)"

# Show 1M burns with destinations
echo "1M burns:"
echo "$CLAIMS" | jq -r '.[] | select(.burned_sats==1000000) | "  \(.btc_txid[0:16])... -> \(.bathron_dest[0:20])... (\(.db_status))"' 2>/dev/null

echo ""
echo "=== 3. Wallet Keys ==="
# Check if burn destination keys are imported
echo "Checking key for xyszqryssGaNw13qpjbxB4PVoRqGat7RPd:"
$CLI getaddressinfo "xyszqryssGaNw13qpjbxB4PVoRqGat7RPd" 2>/dev/null | jq '{ismine, iswatchonly, solvable}' 2>/dev/null || echo "  Not in wallet"

echo ""
echo "=== 4. All UTXOs (raw amounts) ==="
$CLI listunspent 0 9999999 2>/dev/null | jq -c '.[] | {txid: .txid[0:16], vout, amount, conf: .confirmations, addr: .address[0:20]}' 2>/dev/null | head -15

echo ""
echo "=== 5. UTXOs exactly 1000000 sats ==="
$CLI listunspent 0 9999999 2>/dev/null | jq '[.[] | select(.amount == 1000000)] | length' 2>/dev/null
echo "found (amount == 1000000)"

echo ""
echo "=== 6. Check UTXO amount units ==="
echo "First 3 raw amounts:"
$CLI listunspent 0 9999999 2>/dev/null | jq '.[0:3] | .[].amount' 2>/dev/null

echo ""
echo "=== 7. Mempool ProRegTx Details ==="
$CLI getrawmempool 2>/dev/null | jq -r '.[]' 2>/dev/null | while read txid; do
    TX=$($CLI getrawtransaction "$txid" 1 2>/dev/null)
    TYPE=$(echo "$TX" | jq -r '.type // 0' 2>/dev/null)
    if [ "$TYPE" = "1" ]; then
        echo "ProRegTx: $txid"
        # Get collateral outpoint from proRegTx payload
        PAYLOAD=$(echo "$TX" | jq -r '.proRegTx // empty' 2>/dev/null)
        if [ -n "$PAYLOAD" ]; then
            COLL_HASH=$(echo "$PAYLOAD" | jq -r '.collateralHash // "internal"' 2>/dev/null)
            COLL_IDX=$(echo "$PAYLOAD" | jq -r '.collateralIndex // 0' 2>/dev/null)
            echo "  Collateral: $COLL_HASH:$COLL_IDX"

            # Check if collateral UTXO exists
            if [ "$COLL_HASH" != "internal" ] && [ "$COLL_HASH" != "null" ] && [ "$COLL_HASH" != "0000000000000000000000000000000000000000000000000000000000000000" ]; then
                UTXO_EXISTS=$($CLI gettxout "$COLL_HASH" "$COLL_IDX" 2>/dev/null)
                if [ -n "$UTXO_EXISTS" ]; then
                    UTXO_AMT=$(echo "$UTXO_EXISTS" | jq -r '.value' 2>/dev/null)
                    echo "  UTXO exists: YES (amount: $UTXO_AMT)"
                else
                    echo "  UTXO exists: NO (spent or never existed!)"
                fi
            else
                echo "  Internal collateral (in same tx)"
            fi
        fi
    fi
done

echo ""
echo "=== 8. Recent bad-protx errors ==="
grep "bad-protx" ~/.bathron/testnet5/debug.log 2>/dev/null | tail -10
REMOTE
