#!/bin/bash
# audit_global_invariants.sh - Global invariants audit (A5, A6) + consensus check
# Checks: getstate, balances, block heights, MN status, BTC SPV status
set -euo pipefail

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

echo "=========================================="
echo "  GLOBAL INVARIANTS AUDIT"
echo "  $(date '+%Y-%m-%d %H:%M:%S UTC')"
echo "=========================================="

echo ""
echo "=== 1. Global state (from Seed) ==="
$SSH ubuntu@57.131.33.151 "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getstate" 2>/dev/null || echo "  (error reaching Seed)"

echo ""
echo "=== 2. Global state (from CoreSDK - cross-check) ==="
$SSH ubuntu@162.19.251.75 "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getstate" 2>/dev/null || echo "  (error reaching CoreSDK)"

echo ""
echo "=== 3. All wallet balances ==="
for info in "Seed:57.131.33.151:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" \
            "CoreSDK:162.19.251.75:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" \
            "OP1:57.131.33.152:/home/ubuntu/bathron-cli -testnet" \
            "OP2:57.131.33.214:/home/ubuntu/bathron/bin/bathron-cli -testnet" \
            "OP3:51.75.31.44:/home/ubuntu/bathron-cli -testnet"; do
    IFS=: read label ip cli <<< "$info"
    echo "  $label ($ip):"
    $SSH ubuntu@$ip "$cli getbalance" 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
print(f"    M0={d.get(\"m0\",0)} locked={d.get(\"locked\",0)} M1={d.get(\"m1\",0)}")
' 2>/dev/null || echo "    (error)"
done

echo ""
echo "=== 4. Block heights (consensus check) ==="
ALL_HEIGHTS=""
ALL_HASHES=""
for info in "Seed:57.131.33.151:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" \
            "CoreSDK:162.19.251.75:/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet" \
            "OP1:57.131.33.152:/home/ubuntu/bathron-cli -testnet" \
            "OP2:57.131.33.214:/home/ubuntu/bathron/bin/bathron-cli -testnet" \
            "OP3:51.75.31.44:/home/ubuntu/bathron-cli -testnet"; do
    IFS=: read label ip cli <<< "$info"
    height=$($SSH ubuntu@$ip "$cli getblockcount" 2>/dev/null || echo "ERR")
    hash=$($SSH ubuntu@$ip "$cli getbestblockhash" 2>/dev/null || echo "ERR")
    hash_short=$(echo "$hash" | cut -c1-16)
    ALL_HEIGHTS="$ALL_HEIGHTS $height"
    ALL_HASHES="$ALL_HASHES $hash_short"
    echo "  $label: height=$height hash=${hash_short}..."
done

echo ""
UNIQUE_HEIGHTS=$(echo $ALL_HEIGHTS | tr ' ' '\n' | sort -u | grep -v '^$' | wc -l)
UNIQUE_HASHES=$(echo $ALL_HASHES | tr ' ' '\n' | sort -u | grep -v '^$' | wc -l)
if [ "$UNIQUE_HEIGHTS" -le 1 ] && [ "$UNIQUE_HASHES" -le 1 ]; then
    echo "  [OK] All nodes at same height and hash - CONSENSUS OK"
elif [ "$UNIQUE_HEIGHTS" -le 2 ]; then
    echo "  [WARN] Minor height divergence (likely propagation delay)"
    echo "  Heights: $ALL_HEIGHTS"
else
    echo "  [FAIL] Significant divergence! Possible FORK"
    echo "  Heights: $ALL_HEIGHTS"
    echo "  Hashes:  $ALL_HASHES"
fi

echo ""
echo "=== 5. MN status ==="
$SSH ubuntu@57.131.33.151 "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getactivemnstatus" 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
if isinstance(d, list):
    active = [mn for mn in d if mn.get("status") == "ENABLED"]
    print(f"  Active MNs: {len(active)}/{len(d)}")
    for mn in d:
        h = mn.get("proTxHash","?")[:12]
        s = mn.get("status","?")
        p = mn.get("PoSePenalty",0)
        print(f"    {h}... status={s} pose={p}")
elif isinstance(d, dict):
    h = d.get("proTxHash","?")[:16]
    s = d.get("status","?")
    print(f"  Status: {s} proTxHash={h}...")
else:
    print(f"  Raw: {d}")
' 2>/dev/null || echo "  (error reading MN status)"

echo ""
echo "=== 6. BTC SPV status ==="
$SSH ubuntu@57.131.33.151 "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getbtcheadersstatus" 2>/dev/null || echo "  (error reading BTC headers status)"

echo ""
echo "=== 7. Invariant Verification ==="
STATE=$($SSH ubuntu@57.131.33.151 "/home/ubuntu/BATHRON-Core/src/bathron-cli -testnet getstate" 2>/dev/null || echo "")
if [ -n "$STATE" ]; then
    echo "$STATE" | python3 << 'PYEOF'
import sys, json

raw = sys.stdin.read()
d = json.loads(raw)

print("  --- A5: M0_total from BurnClaims only ---")
# Look for various field names
for key in ["m0_supply", "m0_total", "total_supply", "supply"]:
    if key in d:
        print(f"  {key}: {d[key]}")

print("")
print("  --- A6: M0_vaulted == M1_supply ---")
m0_vaulted = None
m1_supply = None
for key in ["m0_vaulted", "locked_supply", "locked", "vaulted"]:
    if key in d:
        m0_vaulted = d[key]
        print(f"  M0 vaulted ({key}): {m0_vaulted}")
        break
for key in ["m1_supply", "m1_total", "m1"]:
    if key in d:
        m1_supply = d[key]
        print(f"  M1 supply ({key}): {m1_supply}")
        break

if m0_vaulted is not None and m1_supply is not None:
    try:
        v = float(m0_vaulted)
        m = float(m1_supply)
        if abs(v - m) < 0.00001:
            print(f"  [OK] A6 INTACT: M0_vaulted ({v}) == M1_supply ({m})")
        else:
            print(f"  [FAIL] A6 VIOLATED: M0_vaulted ({v}) != M1_supply ({m}) -- DELTA={v-m}")
    except Exception as e:
        print(f"  [WARN] Could not parse: {e}")
else:
    print("  [INFO] Fields not found directly; check getstate output above for manual verification")

print("")
print("  --- Coinbase = fees only (no block reward) ---")
for key in ["block_reward", "coinbase_reward", "subsidy"]:
    if key in d:
        print(f"  {key}: {d[key]}")
PYEOF
else
    echo "  (could not fetch state from Seed)"
fi

echo ""
echo "=========================================="
echo "  AUDIT COMPLETE"
echo "=========================================="
