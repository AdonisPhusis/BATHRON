# HTLC RPC Improvement Recommendation

## Issue

The `htlc_get` RPC does not return the `claim_address` field, making it difficult to diagnose claim issues.

Current output:
```json
{
  "outpoint": "COutPoint(31ea186b4a, 0)",
  "hashlock": "f19d45f9e61929aee5021a5ec2d389691801c994fd720aa09faabad9488ffe2e",
  "amount": 100000,
  "source_receipt": "COutPoint(1423366468, 0)",
  "create_height": 1504,
  "expiry_height": 1791,
  "status": "active"
}
```

Missing fields:
- `claim_address` - Who can claim with preimage
- `refund_address` - Who can refund after expiry

## Proposed Fix

Add these fields to the output in `/home/ubuntu/BATHRON/src/rpc/settlement_wallet.cpp` at line 1240:

```cpp
// After line 1240 (before return result)
// Add claim and refund addresses
CTxDestination claimDest(htlc.claimKeyID);
CTxDestination refundDest(htlc.refundKeyID);
result.pushKV("claim_address", EncodeDestination(claimDest));
result.pushKV("refund_address", EncodeDestination(refundDest));
```

## Expected Output

```json
{
  "outpoint": "COutPoint(31ea186b4a, 0)",
  "hashlock": "f19d45f9e61929aee5021a5ec2d389691801c994fd720aa09faabad9488ffe2e",
  "amount": 100000,
  "source_receipt": "COutPoint(1423366468, 0)",
  "create_height": 1504,
  "expiry_height": 1791,
  "status": "active",
  "claim_address": "yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe",
  "refund_address": "yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
}
```

## Benefits

1. **Easier debugging** - Immediately see who can claim
2. **Better UX** - Users know if they have the right wallet
3. **Diagnostic tools** - Scripts can verify claim_address matches expected wallet
4. **Documentation** - Self-documenting HTLC state

## Implementation

File: `src/rpc/settlement_wallet.cpp`  
Function: `htlc_get` (lines 1194-1243)  
Insert at: Line 1240 (before `return result;`)

```diff
     if (!htlc.preimage.IsNull()) {
         result.pushKV("preimage", htlc.preimage.GetHex());
     }
+    
+    // Add claim and refund addresses
+    CTxDestination claimDest(htlc.claimKeyID);
+    CTxDestination refundDest(htlc.refundKeyID);
+    result.pushKV("claim_address", EncodeDestination(claimDest));
+    result.pushKV("refund_address", EncodeDestination(refundDest));

     return result;
 }
```

## Testing

After applying the fix:

```bash
# Test htlc_get output
bathron-cli -testnet htlc_get "31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0"

# Should now include:
#   "claim_address": "yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe",
#   "refund_address": "yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo"
```

## Priority

**Medium** - Not critical for functionality, but significantly improves developer experience and debugging.

