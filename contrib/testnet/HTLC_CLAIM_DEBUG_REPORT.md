# HTLC Claim Debug Report

**Date:** 2026-02-04  
**HTLC Outpoint:** `31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0`  
**Preimage:** `8f894b5829fc8f4096a9f177260e7cb46c175f2961ade379b58cdcdd338c36ef`  
**Claim Address:** `yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe` (Charlie)

---

## Problem Identified

Charlie could not claim the HTLC because **the wallet did not have the private key** for the claim address.

### Root Cause

The address `yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe` was present in Charlie's wallet, but marked as `"ismine": false`, meaning:
- The wallet knew about the address (watch-only)
- The wallet did NOT have the private key to sign transactions

### Evidence

From `diagnose_charlie_htlc_claim.sh`:

```json
{
  "address": "yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe",
  "scriptPubKey": "76a9149c917ed22b3212a3435eafc246349c5720d13f3988ac",
  "ismine": false,         // <-- PROBLEM
  "iswatchonly": false
}
```

Error when trying to claim:
```
error code: -4
error message: Wallet does not have the claim key for this HTLC
```

### Technical Details

1. **HTLC extraPayload decode:**
   - Version: 1
   - Hashlock: `f19d45f9e61929aee5021a5ec2d389691801c994fd720aa09faabad9488ffe2e`
   - Expiry Height: 1791
   - **Claim Address Hash160: `9c917ed22b3212a3435eafc246349c5720d13f39`** ✓ Matches Charlie
   - Remaining data (covenant/signature): `0c274bc63de84fc795f563aae6d325c31728781a`

2. **RPC call flow:**
   - `htlc_claim` calls `pwallet->GetKey(htlc.claimKeyID, claimKey)` (line 1561 in `settlement_wallet.cpp`)
   - This returns `false` if the wallet doesn't have the private key
   - Results in error: "Wallet does not have the claim key for this HTLC"

---

## Solution Applied

### Step 1: Verify ~/.BathronKey/wallet.json

```json
{
  "name": "charlie",
  "role": "fake_user",
  "address": "yBFhaDZ4kJxCXioDT5ztqJzDRFh4wmbwMe",
  "wif": "cPtPSZLkcufXMryYoCTr63zkPDGPtYWxbZ24NGBWzDfzJUuZaEbE",
  "btc_address": "tb1qkd2kyur0yqxpp6hvtwheukwpfjt2h5atapyhe7"
}
```

### Step 2: Import Private Key

```bash
bathron-cli -testnet importprivkey "cPtPSZLkcufXMryYoCTr63zkPDGPtYWxbZ24NGBWzDfzJUuZaEbE" "charlie" false
```

### Step 3: Verify Import Success

After import, `getaddressinfo` returned:
```json
{
  "ismine": true  // ✓ SUCCESS
}
```

### Step 4: Claim HTLC

```bash
bathron-cli -testnet htlc_claim "31ea186b4a59f89d99bc93fe57cabe829e3c68e4df00cef74fa36c5a55651063:0" \
  "8f894b5829fc8f4096a9f177260e7cb46c175f2961ade379b58cdcdd338c36ef"
```

**Result:**
```json
{
  "txid": "77f90ce620788d58c172c117f5285921ef49aed151901f852bb58234389cbebe",
  "receipt_outpoint": "77f90ce620788d58c172c117f5285921ef49aed151901f852bb58234389cbebe:0",
  "amount": 100000,
  "preimage": "8f894b5829fc8f4096a9f177260e7cb46c175f2961ade379b58cdcdd338c36ef"
}
```

### Step 5: Wait for Mining

Transaction mined in ~6 seconds with 1 confirmation.

### Final HTLC Status

```json
{
  "status": "claimed",
  "resolve_txid": "77f90ce620788d58c172c117f5285921ef49aed151901f852bb58234389cbebe",
  "preimage": "ef368c33dddc8cb579e3ad61295f176cb47c0e2677f1a996408ffc29584b898f"
}
```

✓ **HTLC successfully claimed!**

---

## Scripts Created

1. **`diagnose_charlie_htlc_claim.sh`** - Full diagnostic of claim issue
2. **`decode_htlc_payload.sh`** - Decode HTLC extraPayload to verify claim address
3. **`verify_charlie_claim_key.sh`** - Check if wallet has the claim key
4. **`fix_charlie_wallet_key.sh`** - Import WIF and fix the wallet
5. **`wait_and_verify_claim.sh`** - Wait for mining and verify success

---

## Key Learnings

### Why This Happened

Charlie's wallet was likely:
1. Restored from a different seed/backup
2. Created fresh without importing the key from `~/.BathronKey/wallet.json`
3. Had the address added watch-only (e.g., via `importaddress` instead of `importprivkey`)

### Prevention

**ALWAYS** ensure wallets are initialized with keys from `~/.BathronKey/wallet.json`:

```bash
# On wallet initialization
WIF=$(cat ~/.BathronKey/wallet.json | jq -r '.wif')
bathron-cli -testnet importprivkey "$WIF" "label" false
```

### Code Analysis

The `htlc_claim` RPC correctly validates:
1. ✓ HTLC exists and is active
2. ✓ Preimage matches hashlock
3. ✓ **Wallet has private key for claim address** (this was the issue)
4. ✓ Creates and signs claim transaction

The check at line 1561 (`src/rpc/settlement_wallet.cpp`) is correct and necessary:
```cpp
if (!pwallet->GetKey(htlc.claimKeyID, claimKey)) {
    throw JSONRPCError(RPC_WALLET_ERROR,
        "Wallet does not have the claim key for this HTLC");
}
```

---

## Status: RESOLVED ✓

Charlie can now claim HTLCs successfully after importing the private key.

---

## Files

- **Scripts:** `/home/ubuntu/BATHRON/contrib/testnet/diagnose_charlie_htlc_claim.sh` (and related)
- **Report:** `/home/ubuntu/BATHRON/contrib/testnet/HTLC_CLAIM_DEBUG_REPORT.md`

