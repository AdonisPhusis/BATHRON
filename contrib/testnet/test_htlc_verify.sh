#!/bin/bash
# Quick test of htlc_verify after byte order fix

SSH_KEY=~/.ssh/id_ed25519_vps
OP1_IP="57.131.33.152"

# Test values (from /tmp/atomic_*.txt)
PREIMAGE="53dda021db232a7063a1f3fe77e9e4627eccdd00f344188d494a34cad12efb4e"
HASHLOCK="01896bec29c0719e99294db65365dcbe492c15c6050a29300df959c47c1f8298"

echo "=== Testing htlc_verify on OP1 ==="
echo "Preimage: $PREIMAGE"
echo "Hashlock: $HASHLOCK"
echo ""

# Test with original (correct) hashlock
echo "Test 1: Original hashlock (should be valid=true after fix)"
ssh -i $SSH_KEY ubuntu@$OP1_IP "~/bathron-cli -testnet htlc_verify $PREIMAGE $HASHLOCK" 2>&1

echo ""
echo "Test 2: Python verification (ground truth)"
python3 -c "
import hashlib
preimage = bytes.fromhex('$PREIMAGE')
expected_hash = hashlib.sha256(preimage).hexdigest()
print(f'SHA256({\"$PREIMAGE\"[:16]}...) = {expected_hash}')
print(f'Expected hashlock:  {expected_hash}')
print(f'Provided hashlock:  $HASHLOCK')
print(f'Match: {expected_hash == \"$HASHLOCK\"}')"
