# FlowSwap 3-Secrets E2E Proof Report

> **Date:** 2026-02-05T22:13Z
> **Network:** BATHRON testnet5 + BTC Signet + Base Sepolia
> **Protocol:** 3-secret atomic swap (BTC → M1 → USDC)
> **Result: ALL PHASES COMPLETE — ATOMICITY PROVEN**

---

## Cryptographic Commitments

| Role | Hashlock (SHA256) |
|------|-------------------|
| H_user | `7046d373d8702e0167ec2c866aa4d05a83ea86c1e1691e96bb26ff9f134ed6ee` |
| H_lp1  | `0eef9c2569cf2b27e5dbc8676ac2a47a15f16fa17b65c52929aaefbfc1b4be74` |
| H_lp2  | `d2bfbad6f47286f9561b510a7ce24a9457028a20cb8836d183f5cdedb3ee93d0` |

Each HTLC independently verifies all 3 hashlocks. No concatenated hash — 3× `OP_SHA256` on BTC, 3× `sha256()` on EVM/M1.

---

## BTC Leg (Signet)

| Field | Value |
|-------|-------|
| HTLC Address (P2WSH) | `tb1q8n7w3eqnqt7ngqjnspexgu3yfs6teke7eymft54jsgjg836hvs6sfa6rrq` |
| Funding TX | [`30f0248e979f43355d7680f683736b37815a9ed9847dbedb48ba81cc8bd3c6f7`](https://mempool.space/signet/tx/30f0248e979f43355d7680f683736b37815a9ed9847dbedb48ba81cc8bd3c6f7) |
| Claim TX | [`861c9c2446060c6e11bd68c3ef2b597e5fafcf306ad61256728c70dca0f8b462`](https://mempool.space/signet/tx/861c9c2446060c6e11bd68c3ef2b597e5fafcf306ad61256728c70dca0f8b462) |
| Amount | 50,000 sats (0.0005 BTC) |
| Timelock | block 290,289 |
| Script | 3× OP_SHA256 + OP_EQUALVERIFY + OP_CHECKSIG / OP_CLTV refund |

**Claim witness (6-item stack):** `<sig_lp1> <S_lp2> <S_lp1> <S_user> <1> <redeemScript>`
Secrets are public in the BTC blockchain witness data after claim.

---

## M1 Leg (BATHRON testnet5)

| Field | Value |
|-------|-------|
| HTLC3S Create TX | `c91b11499317782992812e3c7b035b42d756ab676fd3f10074f316fcd1f08b22` |
| HTLC Outpoint | `c91b11499317782992812e3c7b035b42d756ab676fd3f10074f316fcd1f08b22:0` |
| Claim TX | `dcbef8e4a7eb956c1306a5de6f1dde04960b0fe796e9de152ae8c983cb03240e` |
| New Receipt | `dcbef8e4a7eb956c1306a5de6f1dde04960b0fe796e9de152ae8c983cb03240e:0` |
| TX Types | Create=43 (HTLC_CREATE_3S), Claim=44 (HTLC_CLAIM_3S) |
| Fee | Exempt (settlement TX) |

---

## EVM Leg (Base Sepolia, chain 84532)

| Field | Value |
|-------|-------|
| Contract | [`0x2493EaaaBa6B129962c8967AaEE6bF11D0277756`](https://sepolia.basescan.org/address/0x2493EaaaBa6B129962c8967AaEE6bF11D0277756) |
| HTLC ID | `0x849295f9c799cf14f6c31e5d214d0a63daf2d42e2583abb090183f035b8d6062` |
| Lock TX | [`bbe90171ad3e8dcfa29a9ed692073b69ae637a996b21584230f40a1049f1e607`](https://sepolia.basescan.org/tx/bbe90171ad3e8dcfa29a9ed692073b69ae637a996b21584230f40a1049f1e607) |
| Claim TX | [`6dfa0b39535577291ca4f5108cfc47d820095c925787300975efca5371667484`](https://sepolia.basescan.org/tx/6dfa0b39535577291ca4f5108cfc47d820095c925787300975efca5371667484) |
| Token | USDC (`0x036CbD53842c5426634e7929541eC2318f3dCF7e`) |
| Amount | 5.0 USDC |
| Sender | `0x170d28a996799E951d5A95d5ACBaA453DEE6c867` (Bob/LP2) |
| Recipient | `0x9f11B03618DeE8f12E7F90e753093B613CeD51D2` (Charlie/User) |
| Claim type | Permissionless (anyone-can-execute, funds go to fixed recipient) |

---

## Actors

| Actor | Role | Chain | Address |
|-------|------|-------|---------|
| Charlie (OP3) | User | BTC | `tb1qkd2kyur0yqxpp6hvtwheukwpfjt2h5atapyhe7` |
| Charlie (OP3) | User | EVM | `0x9f11B03618DeE8f12E7F90e753093B613CeD51D2` |
| Alice (OP1) | LP1 (BTC/M1) | M1 | `yJYD2bfYYBe6qAojSzMKX949H7QoQifNAo` |
| Bob (CoreSDK) | LP2 (M1/USDC) | M1 | `y4eFhNMXEJr3wKKDFvtEP8bv6zQ51scLFk` |
| Bob (CoreSDK) | LP2 (M1/USDC) | EVM | `0x170d28a996799E951d5A95d5ACBaA453DEE6c867` |

---

## Invariants Verified

| # | Invariant | Value | Status |
|---|-----------|-------|--------|
| 1 | Timelock ordering | BTC(3,600s) < M1(7,200s) < USDC(14,400s) | **OK** |
| 2 | SHA256(S_user) == H_user | Verified | **OK** |
| 3 | SHA256(S_lp1) == H_lp1 | Verified | **OK** |
| 4 | SHA256(S_lp2) == H_lp2 | Verified | **OK** |
| 5 | Secret ordering canonical | (S_user, S_lp1, S_lp2) everywhere | **OK** |
| 6 | BTC claim reveals all 3 secrets | Witness extractable on-chain | **PROVEN** |
| 7 | EVM claim permissionless | Anyone calls claim(), recipient fixed | **OK** |
| 8 | M1 HTLC3S fee-exempt | Settlement TX, no fee required | **OK** |

---

## Execution Timeline

| Phase | Time (UTC) | Action | Chain | TX |
|-------|------------|--------|-------|----|
| 1 | ~21:44 | Generate 3 secrets | - | - |
| 2A | ~21:45 | LP2 locks 5 USDC | Base Sepolia | `bbe901...` |
| 2B | ~21:54 | LP1 locks M1 receipt | BATHRON | `c91b11...` |
| 3 | ~21:55 | User funds BTC HTLC | Signet | `30f024...` |
| wait | ~21:59 | BTC confirms (~4 min) | Signet | - |
| 4 | ~22:00 | LP1 claims BTC (**secrets revealed**) | Signet | `861c9c...` |
| 5A | ~22:01 | Claim USDC (permissionless) | Base Sepolia | `6dfa0b...` |
| 5B | ~22:01 | LP2 claims M1 | BATHRON | `dcbef8...` |

**Total swap time: ~17 minutes** (dominated by BTC Signet confirmation)

---

## Bugs Fixed During Test

| Bug | Fix | File |
|-----|-----|------|
| `expiry_blocks` sent as string to RPC | Added `htlc3s_create`/`htlc_create_m1` to `vRPCConvertParams` | `src/rpc/client.cpp` |
| Timelock ordering BTC(12h) > M1(2h) | Reduced BTC to 6 blocks, kept M1 at 120 | `e2e_flowswap_3secrets.sh` |
| BTC amount `.00050000` missing leading zero | Added `format_btc_amount()` helper | `e2e_flowswap_3secrets.sh` |
| Fund error silently swallowed | Capture stderr + show wallet balance | `e2e_flowswap_3secrets.sh` |
