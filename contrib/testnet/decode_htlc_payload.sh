#!/bin/bash
# Decode HTLC extraPayload to extract claim_address

EXTRA_PAYLOAD="01f19d45f9e61929aee5021a5ec2d389691801c994fd720aa09faabad9488ffe2eff0600009c917ed22b3212a3435eafc246349c5720d13f390c274bc63de84fc795f563aae6d325c31728781a"

echo "=== Decoding HTLC extraPayload ==="
echo "Raw: $EXTRA_PAYLOAD"
echo ""

python3 << 'PYTHON_EOF'
import binascii

payload = "01f19d45f9e61929aee5021a5ec2d389691801c994fd720aa09faabad9488ffe2eff0600009c917ed22b3212a3435eafc246349c5720d13f390c274bc63de84fc795f563aae6d325c31728781a"
data = bytes.fromhex(payload)

print(f"Total length: {len(data)} bytes")
print()

# Parse HTLC extraPayload structure
offset = 0

# Version (1 byte)
version = data[offset]
print(f"Version: {version}")
offset += 1

# Hashlock (32 bytes)
hashlock = data[offset:offset+32].hex()
print(f"Hashlock: {hashlock}")
offset += 32

# Expiry height (4 bytes, little-endian)
expiry = int.from_bytes(data[offset:offset+4], 'little')
print(f"Expiry Height: {expiry}")
offset += 4

# Claim address (20 bytes) - THIS IS THE KEY FIELD
claim_addr_hash = data[offset:offset+20].hex()
print(f"Claim Address Hash160: {claim_addr_hash}")
print(f"  Expected Charlie's hash160: 9c917ed22b3212a3435eafc246349c5720d13f39")
print(f"  Match: {claim_addr_hash == '9c917ed22b3212a3435eafc246349c5720d13f39'}")
offset += 20

# Remaining data (likely signature or covenant data)
remaining = data[offset:].hex()
print(f"Remaining data: {remaining}")
print(f"  Length: {len(data[offset:])} bytes")

PYTHON_EOF
