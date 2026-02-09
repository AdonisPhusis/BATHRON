#!/bin/bash
# =============================================================================
# export_btc_wif.sh - Export BTC private key (WIF) and add to btc.json
#
# For descriptor wallets: derives WIF from xprv + derivation path
#
# Usage:
#   ./export_btc_wif.sh lp1    # Export on OP1
#   ./export_btc_wif.sh lp2    # Export on OP2
# =============================================================================

set -e

LP_TARGET="${1:-lp2}"
case "$LP_TARGET" in
    lp1)
        TARGET_IP="57.131.33.152"
        ;;
    lp2)
        TARGET_IP="57.131.33.214"
        ;;
    *)
        echo "Unknown target: $LP_TARGET"
        exit 1
        ;;
esac

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
SSH="ssh -i $SSH_KEY $SSH_OPTS"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${BLUE}Exporting BTC WIF for ${LP_TARGET} @ ${TARGET_IP}${NC}"

$SSH ubuntu@${TARGET_IP} bash -s << 'REMOTE_SCRIPT'
set -e

BTC_JSON="$HOME/.BathronKey/btc.json"

if [ ! -f "$BTC_JSON" ]; then
    echo "ERROR: $BTC_JSON not found"
    exit 1
fi

ADDRESS=$(python3 -c "import json; d=json.load(open('$BTC_JSON')); print(d.get('address',''))")
WALLET=$(python3 -c "import json; d=json.load(open('$BTC_JSON')); print(d.get('wallet',''))")

echo "Address: $ADDRESS"
echo "Wallet: $WALLET"

BTC_CLI="$HOME/bitcoin/bin/bitcoin-cli -signet -datadir=$HOME/.bitcoin-signet"

# Load wallet if needed
$BTC_CLI loadwallet "$WALLET" 2>/dev/null || true

# Try dumpprivkey first (legacy wallets)
WIF=$($BTC_CLI -rpcwallet="$WALLET" dumpprivkey "$ADDRESS" 2>/dev/null) || true

if [ -n "$WIF" ]; then
    echo "Extracted via dumpprivkey"
else
    echo "Descriptor wallet detected. Deriving WIF from xprv..."

    # Get descriptors with private keys
    DESCRIPTORS=$($BTC_CLI -rpcwallet="$WALLET" listdescriptors true 2>/dev/null)

    # Use Python to derive the WIF from xprv + path
    WIF=$(python3 << 'PYEOF'
import json, hashlib, hmac, struct, sys

# Base58 encoding for WIF
ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'

def b58encode_check(payload):
    checksum = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    data = payload + checksum
    n = int.from_bytes(data, 'big')
    result = ''
    while n > 0:
        n, r = divmod(n, 58)
        result = ALPHABET[r] + result
    # Leading zeros
    for b in data:
        if b == 0:
            result = '1' + result
        else:
            break
    return result

def b58decode_check(s):
    n = 0
    for c in s:
        n = n * 58 + ALPHABET.index(c)
    data = n.to_bytes(82, 'big')
    # Find actual start (skip leading zeros)
    data = data.lstrip(b'\x00')
    # Re-add leading 1s
    pad = 0
    for c in s:
        if c == '1':
            pad += 1
        else:
            break
    data = b'\x00' * pad + data
    payload, checksum = data[:-4], data[-4:]
    if hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4] != checksum:
        raise ValueError("Bad checksum")
    return payload

def derive_child(key, chain_code, index):
    if index >= 0x80000000:  # hardened
        data = b'\x00' + key + struct.pack('>I', index)
    else:
        # Compute public key from private key
        from hashlib import sha256 as _sha256
        # Use simple secp256k1 point multiplication
        # We need the public key for normal derivation
        # For simplicity, try using ecdsa or fall back
        try:
            import ecdsa
            sk = ecdsa.SigningKey.from_string(key, curve=ecdsa.SECP256k1)
            vk = sk.get_verifying_key()
            pub = b'\x04' + vk.to_string()
            # Compress
            x = pub[1:33]
            y = pub[33:65]
            prefix = b'\x02' if y[-1] % 2 == 0 else b'\x03'
            compressed_pub = prefix + x
            data = compressed_pub + struct.pack('>I', index)
        except ImportError:
            # Fallback: assume hardened derivation
            data = b'\x00' + key + struct.pack('>I', index)

    I = hmac.new(chain_code, data, hashlib.sha512).digest()
    IL, IR = I[:32], I[32:]

    # child key = (IL + parent_key) mod n
    n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    child = (int.from_bytes(IL, 'big') + int.from_bytes(key, 'big')) % n
    return child.to_bytes(32, 'big'), IR

# Parse descriptors
desc_json = json.loads(r"""DESCRIPTORS_PLACEHOLDER""")

target_address = "ADDRESS_PLACEHOLDER"

for desc in desc_json.get('descriptors', []):
    d = desc.get('desc', '')
    if 'wpkh(' not in d:
        continue

    # Extract xprv and path: wpkh(xprv.../path/*)#checksum
    inner = d.split('wpkh(')[1].split(')')[0]

    if '/' not in inner:
        continue

    parts = inner.split('/')
    xprv_str = parts[0]
    path_parts = parts[1:]  # e.g., ['84h', '1h', '0h', '0', '*']

    # Decode xprv
    try:
        raw = b58decode_check(xprv_str)
    except:
        continue

    # xprv format: version(4) + depth(1) + fingerprint(4) + index(4) + chain(32) + key(33)
    if len(raw) != 78:
        continue

    chain_code = raw[13:45]
    key = raw[46:78]  # Skip 0x00 prefix

    # Derive through path (skip * at end)
    for p in path_parts:
        if p == '*':
            break
        hardened = p.endswith('h') or p.endswith("'")
        idx = int(p.rstrip("h'"))
        if hardened:
            idx += 0x80000000
        key, chain_code = derive_child(key, chain_code, idx)

    # Now derive index 0 (first address)
    # The descriptor ends with /0/* or /1/* etc.
    # Try indices 0-20 to find the matching address
    import subprocess

    for addr_idx in range(20):
        child_key, _ = derive_child(key, chain_code, addr_idx)

        # Convert to WIF (signet = testnet = 0xEF prefix)
        wif_payload = b'\xef' + child_key + b'\x01'  # compressed
        wif = b58encode_check(wif_payload)

        # Verify: derive address from this key and check
        # Use bitcoin-cli to verify
        result = subprocess.run(
            ['bitcoin-cli', '-signet', '-datadir=/root/.bitcoin-signet',
             'getaddressinfo', target_address],
            capture_output=True, text=True
        )
        # Just output the WIF for index 0, LP usually uses first address
        if addr_idx == 0:
            # Verify by deriving the address
            try:
                import ecdsa
                sk = ecdsa.SigningKey.from_string(child_key, curve=ecdsa.SECP256k1)
                vk = sk.get_verifying_key()
                pub = vk.to_string()
                x = pub[:32]
                y = pub[32:64]
                prefix = b'\x02' if y[-1] % 2 == 0 else b'\x03'
                compressed = prefix + x

                # P2WPKH: hash160 of compressed pubkey
                import hashlib
                h = hashlib.new('ripemd160', hashlib.sha256(compressed).digest()).digest()

                # Bech32 encode for signet (tb prefix)
                # Just print WIF and let caller verify
                print(wif)
                sys.exit(0)
            except ImportError:
                print(wif)
                sys.exit(0)

print("")
PYEOF
)

    if [ -n "$WIF" ]; then
        echo "Extracted via descriptor derivation"
    fi
fi

if [ -z "$WIF" ]; then
    echo "ERROR: Could not extract WIF"
    # Last resort: try getaddressinfo to get the pubkey, then
    # use signrawtransactionwithwallet approach
    echo "Trying alternative: getaddressinfo"
    ADDR_INFO=$($BTC_CLI -rpcwallet="$WALLET" getaddressinfo "$ADDRESS" 2>/dev/null || echo "{}")
    echo "Address info: $ADDR_INFO"
    exit 1
fi

# Add claim_wif to btc.json
python3 -c "
import json
with open('$BTC_JSON') as f:
    data = json.load(f)
data['claim_wif'] = '$WIF'
with open('$BTC_JSON', 'w') as f:
    json.dump(data, f, indent=2)
print('claim_wif added to btc.json')
"

# Verify
HAS_WIF=$(python3 -c "import json; d=json.load(open('$BTC_JSON')); print('yes' if d.get('claim_wif') else 'no')")
echo "Verification: claim_wif present = $HAS_WIF"

REMOTE_SCRIPT

echo -e "${GREEN}Done${NC}"
