# BATHRON Genesis Specification

**Version:** 1.0
**Date:** 2026-02-13
**Status:** CANONICAL
**Consolidates:** 09-TESTNET-GENESIS.md, 12-BTC-BURN-GENESIS.md, GENESIS-SAFE.md

---

## Table of Contents

1. [Principles](#1-principles)
2. [Consensus Boundaries](#2-consensus-boundaries)
3. [Architecture](#3-architecture)
4. [Testnet Genesis (Implemented)](#4-testnet-genesis-implemented)
5. [Mainnet Genesis (Planned)](#5-mainnet-genesis-planned)
6. [Burn Discovery & Minting](#6-burn-discovery--minting)
7. [Key Management](#7-key-management)
8. [Verification & Gates](#8-verification--gates)
9. [Post-Genesis Operations](#9-post-genesis-operations)
10. [Troubleshooting](#10-troubleshooting)
11. [Files Reference](#11-files-reference)
12. [Appendix: Mainnet Data Structures](#appendix-a-mainnet-data-structures)
13. [Appendix: Regulatory Defense](#appendix-b-regulatory-defense)

---

## 1. Principles

### Zero Premint

All M0 originates from SPV-verified BTC burns. No coinbase rewards, no treasury, no hardcoded distribution.

```
A5: M0_total(N) = M0_total(N-1) + BurnClaims
    Coinbase = 0 always (fees only)
    Block reward = 0 always
    Treasury = 0 (none exists)
```

### One Path

Burns on Bitcoin → SPV verification → TX_BURN_CLAIM → K blocks finality → TX_MINT_M0BTC. Same path for genesis and runtime. Testnet and mainnet differ only in timing (pre-launch vs live discovery), not mechanism.

### Deterministic Minting

Every node independently computes the expected TX_MINT_M0BTC. If the block producer's TX doesn't match, the block is rejected. No manual intervention possible.

### Auto-Discovery (Testnet) / Commitment (Mainnet)

| | Testnet | Mainnet |
|---|---------|---------|
| Burns | Auto-discovered from BTC Signet | Pre-collected during burn window |
| Headers | TX_BTC_HEADERS in Block 1 | Committed header chain file |
| K_FINALITY | 20 | 100 |
| K_BTC_CONFS | 6 | 24 |
| Checkpoint | 286000 (Signet) | ~850000 (Mainnet) |

---

## 2. Consensus Boundaries

### What Consensus GUARANTEES

| Guarantee | Description | Enforcement |
|-----------|-------------|-------------|
| **A5** | `M0_total(N) = M0_total(N-1) + BurnClaims` | Block validation |
| **A6** | `M0_vaulted == M1_supply` | TX validation |
| **A9** | `btc_supply(checkpoint) == expected` | Circuit breaker |
| **BTC Burns** | M0 created iff valid BTC burn exists (SPV-verified, K confs, BCS v1.0 format, not duplicate) | Consensus |
| **Lock/Unlock** | M0 ↔ M1 at 1:1, instant, permissionless, reversible | Consensus rule, not price promise |
| **Finality** | HU Finality: 2/3 MN quorum, ~1 minute, cryptographic not probabilistic | BFT consensus |
| **HTLC** | Executes exactly as scripted (claim: preimage+sig, refund: timeout+sig) | Script engine |
| **OP_TEMPLATEVERIFY** | Spending TX must match committed template | Script engine |

### What Consensus DOES NOT DEFINE

Price, peg, stablecoin, token, reserve, backing, collateral ratio, liquidation, issuer, whitelist, blacklist, admin, upgrade authority, treasury, M2, wrapped token, synthetic, derivative.

**If a concept is not listed above, it does not exist at consensus level.**

### What Consensus REFUSES

- Oracle dependency (any external data not verifiable on-chain)
- Economic parameters (interest rates, fees, thresholds, yield)
- Price awareness (no price feed, no target value)
- Privileged actors (no admin keys, no emergency powers)
- Redemption promise (burn is one-way; protocol provides settlement, not redemption)

---

## 3. Architecture

### Network Topology

```
┌──────────┬─────────────────┬──────────┬────────────────────────────────────┐
│ Node     │ IP              │ Role     │ Details                            │
├──────────┼─────────────────┼──────────┼────────────────────────────────────┤
│ Seed     │ 57.131.33.151   │ 8 MNs    │ Block production, SPV daemons      │
│ CoreSDK  │ 162.19.251.75   │ Peer     │ P&A Swap frontend                  │
│ OP1      │ 57.131.33.152   │ Peer     │ LP1 (alice)                        │
│ OP2      │ 57.131.33.214   │ Peer     │ LP2 (dev)                          │
│ OP3      │ 51.75.31.44     │ Peer     │ Fake user (charlie)                │
└──────────┴─────────────────┴──────────┴────────────────────────────────────┘
```

### Consensus Parameters

```cpp
consensus.nDMMBootstrapHeight = 3;        // Blocks 0-2 exempt from signatures
consensus.nStaleChainTimeout = 600;       // 10 min cold start recovery
consensus.nHuLeaderTimeoutSeconds = 45;   // Leader timeout
consensus.nHuFallbackRecoverySeconds = 15;// Fallback window
```

### Block Structure (Testnet)

```
Block 0:  Pure Genesis (empty coinbase, 0 reward)
Block 1:  TX_BTC_HEADERS (~5000+ BTC Signet headers → btcheadersdb)
Block 2-N: Header catch-up + TX_BURN_CLAIM (auto-discovered)
Block N+K: TX_MINT_M0BTC (automatic after K=20 finality blocks)
Block N+K+1..+2: ProReg MNs (8 MNs, single operator)
Block 3+:  DMM active (60s spacing, HU Finality)
```

### Constants

| Constant | Testnet | Mainnet | Purpose |
|----------|---------|---------|---------|
| `BTC_CHECKPOINT` | 286000 (Signet) | ~850000 | SPV starting point |
| `BATHRON_MAGIC` | `42415448524f4e` | Same | "BATHRON" hex in OP_RETURN |
| `K_FINALITY` | 20 | 100 | Blocks before mint eligibility |
| `K_BTC_CONFS` | 6 | 24 | Required BTC confirmations |
| `MIN_BURN_SATS` | 1000 | 1000 | Dust protection |
| `MAX_MINT_CLAIMS_PER_BLOCK` | 100 | 100 | Per-block mint cap |
| `MAX_BURN_CLAIMS_PER_BLOCK` | 50 | 50 | Per-block claim submission cap |
| `nDMMBootstrapHeight` | 3 | 5 | Bootstrap period |

---

## 4. Testnet Genesis (Implemented)

### Orchestration: `deploy_to_vps.sh --genesis`

7-step pipeline with `--resume-from=N` support:

| Step | Function | What It Does |
|------|----------|--------------|
| 1 | `genesis_step_1_spv_prepare` | Sync BTC headers on Seed from Signet, create btcspv backup |
| 2 | `genesis_step_2_create` | Run `genesis_bootstrap_seed.sh` on Seed (isolated, no peers) |
| 3 | `genesis_step_3_configure` | Download operator key, configure Seed as MN, others as peers |
| 4 | `genesis_step_4_distribute` | Package chain data, distribute to all 5 nodes (parallel SCP) |
| 5 | `genesis_step_5_start` | Start bathrond on all nodes |
| 6 | `genesis_step_6_verify` | 3-gate verification (height, BTC headers, consensus hash) |
| 7 | `genesis_step_7_seed_daemons` | Start header daemon + burn claim daemon on Seed |

### Bootstrap Script: `genesis_bootstrap_seed.sh`

Runs on the Seed node in an isolated datadir (`/tmp/bathron_bootstrap`):

```
Phase 0: Setup
  ├── Kill all bathrond, wipe /tmp/bathron_bootstrap
  ├── Restore btcspv LevelDB from backup
  ├── Start bathrond in -noconnect -listen=0
  └── Verify btcspv tip >= 286001

Phase 1: Block 1 (TX_BTC_HEADERS)
  ├── generatebootstrap 1
  └── Verify: type 33 TX present, zero type 31

Phase 2: Header Catch-Up
  └── Loop generatebootstrap until btcheadersdb.tip >= BTC_tip - 6

Phase 3: Burn Discovery
  ├── Scan BTC Signet blocks [286301, safe_height]
  ├── For each OP_RETURN with BATHRON magic → submitburnclaimproof
  └── Set burn scan progress for daemon handoff

Phase 4: K-Finality → Phase 5: Auto-Mint → Phase 6: MN Registration
  ├── 20 finality blocks
  ├── TX_MINT_M0BTC auto-created by block assembler
  ├── 8 MNs registered via protx_register
  └── Operator key saved to ~/.BathronKey/operators.json
```

### Properties

- **Zero hardcoded burns** — all discovered from BTC Signet
- **Idempotent** — safely re-runnable from scratch
- **New burns auto-claimed** — runtime daemon picks up where genesis left off

### Commands

```bash
# Full genesis
./contrib/testnet/deploy_to_vps.sh --genesis

# Resume from step 4
./contrib/testnet/deploy_to_vps.sh --genesis --resume-from=4

# Status
./contrib/testnet/deploy_to_vps.sh --status
```

### Expected State

```bash
$ bathron-cli -testnet getblockcount
252

$ bathron-cli -testnet getbtcheadersstatus | jq '.tip_height'
291289

$ bathron-cli -testnet listburnclaims final 100 | jq 'length'
34
```

---

## 5. Mainnet Genesis (Planned)

### Difference from Testnet

At mainnet launch, there is no chain to submit TX_BURN_CLAIM. Burns are embedded via a **commitment root** in chainparams.cpp.

### Pre-Launch Timeline

```
Day -30: Announce burn procedure, open testnet for testing
Day -7:  Open MAINNET burn window (anyone can burn BTC)
Day -1:  Cutoff block announced (height H), wait K=24 confirmations
         Generate GENESIS_BURNS list, publish for community verification
Day 0:   GENESIS
Day 1+:  New burns via TX_BURN_CLAIM (runtime SPV)
```

### Burn Format (BCS v1.0)

```
OP_RETURN: BATHRON|01|<NET>|<DEST_HASH160>  (29 bytes)
Burn output: P2WSH(OP_FALSE)               (provably unspendable)
P2WSH hash: SHA256(0x00) = 6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d
```

### Commitment Root Approach

```cpp
// chainparams.cpp — one hash, not the full burns array
static const uint256 GENESIS_BURNS_COMMITMENT = uint256("sha256d(sorted burns...)...");
static const uint256 GENESIS_BTC_HEADER_CHAIN_COMMITMENT = uint256("sha256d(headers...)...");

// External files distributed with release:
//   genesis_burns.json         — full burn records with proofs
//   genesis_btc_headers.bin    — header chain (80 bytes/header, height-ascending)
```

At startup:
1. Load external files
2. Hash raw bytes, compare to commitment
3. Parse and verify each burn's merkle proof against BTC headers
4. Create FINAL burn claim records + UTXOs for recipients
5. Initialize SPV with checkpoint as starting tip

**Missing file = FATAL error on mainnet.** Testnet: optional.

### Genesis State Initialization

```
Height 0:
  ├── Genesis coinbase (0 reward)
  ├── Preload BTC header chain into SPV DB
  ├── Process GENESIS_BURNS (verify, create BurnClaimRecords as FINAL)
  ├── Create UTXOs for burn recipients
  └── Set M0BTC_supply = Σ burnedSats

Heights 1-5: Bootstrap (only NORMAL TX type 0 allowed)
Height 6+:  Full protocol (TX_BURN_CLAIM, lock/unlock, settlement)
```

### Security

- Genesis burns are FROZEN at compile time (commitment root)
- No late additions — missed the window → wait for runtime TX_BURN_CLAIM
- Anyone can verify: BTC TXs are public, proofs in genesis_burns.json, commitment in source code
- Founder burns use the same format and rules as public burns

---

## 6. Burn Discovery & Minting

### Discovery (Testnet: Live, Mainnet: Pre-Launch)

**Testnet scan logic** (used by both `genesis_bootstrap_seed.sh` and `btc_burn_claim_daemon.sh`):

```bash
# For each BTC block:
block=$(bitcoin-cli getblock $hash 2)
# Filter TXs with OP_RETURN containing BATHRON magic (6a1d42415448524f4e)
# Submit each via: bathron-cli submitburnclaimproof $raw_tx $merkleblock
```

**Mainnet:** Burns collected during pre-launch window, verified, embedded in genesis_burns.json.

### Minting Pipeline

```
TX_BURN_CLAIM accepted (mempool → block)
    → BurnClaimRecord created: status=PENDING
    → K blocks pass (20 testnet / 100 mainnet)
    → Block producer: CreateMintM0BTC(height)
        → Query all PENDING claims where height > claim_height + K
        → Sort eligible by txid (canonical, deterministic)
        → Cap at MAX_MINT_CLAIMS_PER_BLOCK (100)
        → Create TX_MINT_M0BTC: one P2PKH output per claim
        → nValue = record.burnedSats (1:1)
        → Empty vin (money creation)
    → ALL nodes verify: independently compute expected TX, hash must match
    → BurnClaimRecord updated: status=FINAL
```

### Rejection Codes

| Code | Description |
|------|-------------|
| `burnclaim-btc-header-missing` | BTC header not in btcheadersdb |
| `burnclaim-merkle-invalid` | Merkle proof verification failed |
| `burnclaim-duplicate` | Burn already claimed |
| `burnclaim-amount-zero` | No valid burn output found |

---

## 7. Key Management

### Storage Structure

```
~/.BathronKey/           # drwx------ (700)
├── operators.json       # MN operator key (Seed only, generated at genesis)
├── wallet.json          # Main wallet (1 per VPS)
├── evm.json             # EVM wallet (if applicable)
└── btc.json             # BTC wallet (if applicable)
```

### operators.json

```json
{"operator": {"wif": "cVAUa3mjEm...", "pubkey": "03a1b2c3...", "mn_count": 8}}
```

### Rules

1. **NEVER** commit `~/.BathronKey/` to git
2. **NEVER** hardcode WIFs in scripts
3. **ALWAYS** read keys at runtime
4. Operator key regenerated at each genesis
5. One wallet per VPS — never shared

---

## 8. Verification & Gates

### 3-Gate System (genesis_step_6_verify)

| Gate | Check | Threshold |
|------|-------|-----------|
| **Height** | All nodes at height >= 5 | 3 retries, 10s apart |
| **BTC Headers** | `btcheadersstatus.tip_height >= 286000` on all nodes | First try |
| **Consensus** | Same `getblockhash` at common height | Unanimous |

### Health Check (post-verification)

- Daemon count = 1 per node
- Block heights match
- Headers == blocks (no IBD)
- Peer connectivity >= 4

### Mainnet Startup Verification

```cpp
// FATAL if any check fails:
VerifyGenesisBurnsCommitment()    // File hash matches commitment
PreloadGenesisHeaderChain()       // Header chain valid and linked
VerifyGenesisBurnProof(burn)      // SPV proof + ancestry + format (BCS v1.0)
```

---

## 9. Post-Genesis Operations

### BTC Header Daemon (`btc_header_daemon.sh`)

- Publishes new BTC headers as TX_BTC_HEADERS
- Keeps btcheadersdb in sync with BTC chain
- Required for validating new burn claims

### Burn Claim Daemon (`btc_burn_claim_daemon.sh`)

- Scans BTC every 5 minutes for new burns
- Submits TX_BURN_CLAIM for each new burn found
- Persistent state in settlement DB (reorg-safe)
- Deduplication: `checkburnclaim` + consensus rejection
- SPV-capped: never scans beyond btcheadersdb tip

### New Burn Flow (Fully Automatic)

```
BTC burn (OP_RETURN "BATHRON|01|T|dest_hash")
    → btc_burn_claim_daemon detects
    → TX_BURN_CLAIM submitted
    → Consensus validates (SPV proof, format, uniqueness)
    → K blocks later → TX_MINT_M0BTC automatic
    → M0 credited to destination
```

---

## 10. Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| "btcspv tip too low" | BTC Signet not synced on Seed | Start BTC daemon, wait, re-run step 1 |
| "no burns found" | BTC_CHECKPOINT after all burns | Verify `bitcoin-cli -signet getblockcount` > 286326 |
| "zero mints after K blocks" | Burns not finalized yet | Check debug.log, bootstrap handles automatically |
| "bad-protx-dup-owner" | MN collateral conflict | Full genesis reset (no --resume-from) |
| Fork after genesis | Nodes have different chain data | Re-run steps 4+5 |
| "no MNs found on-chain" | Operator key mismatch | Check `~/.BathronKey/operators.json` |
| 0 peers | `addnode` not in `[test]` section | Fix bathron.conf section placement |
| EvoDB inconsistent | Corrupt state | `bathron-cli stop && bathrond -reindex` |

---

## 11. Files Reference

### Scripts

| File | Purpose |
|------|---------|
| `contrib/testnet/deploy_to_vps.sh` | 7-step genesis orchestrator |
| `contrib/testnet/genesis_bootstrap_seed.sh` | Bootstrap (runs on Seed, isolated) |
| `contrib/testnet/btc_burn_claim_daemon.sh` | Live burn scanner (post-genesis) |
| `contrib/testnet/btc_header_daemon.sh` | BTC header publisher (post-genesis) |

### C++ Consensus

| File | Purpose |
|------|---------|
| `src/blockassembler.cpp` | TX_MINT_M0BTC creation (automatic) |
| `src/burnclaim/burnclaim.cpp` | Burn claim validation + CreateMintM0BTC |
| `src/btcspv/btcspv.cpp` | BTC SPV verification (PoW, merkle, checkpoints) |
| `src/btcheaders/btcheaders.cpp` | TX_BTC_HEADERS validation (R1-R7 rules) |
| `src/masternode/specialtx_validation.cpp` | Per-type TX dispatch (CheckSpecialTx) |
| `src/consensus/tx_verify.cpp` | Generic TX validation |
| `src/chainparams.cpp` | Network parameters, checkpoints |

---

## Appendix A: Mainnet Data Structures

### GenesisBurn (for commitment root)

```cpp
struct GenesisBurn {
    uint256 btcTxid;
    uint256 btcBlockHash;
    uint32_t btcHeight;
    uint64_t burnedSats;
    uint160 bathronDest;              // Hash160 destination
    std::vector<uint256> merkleProof;
    uint32_t txIndex;
    std::vector<uint8_t> rawtx;       // Required on mainnet (BP08 format verify)
};
```

### Commitment Computation

```cpp
// Leaf: SHA256d(btcTxid || btcBlockHash || btcHeight || burnedSats ||
//              bathronDest || txIndex || merkleProofHash || rawtxHash)
// Tree: Binary merkle (SHA256d at each level)
// Sort: by btcTxid ascending before computing
uint256 ComputeBurnsMerkleRoot(const std::vector<GenesisBurn>& burns);
```

### Header Chain File

```
genesis_btc_headers.bin:
  - Each header: exactly 80 bytes (standard Bitcoin header)
  - Concatenated in height-ascending order
  - No length prefix, no separators
  - Commitment = SHA256d(concat(all headers))
  - Height derivation: headers[i] = BTC_GENESIS_HEADERS_START_HEIGHT + i
```

### Startup Sequence

```cpp
1. Load genesis_btc_headers.bin → hash raw bytes → compare to commitment
2. Parse headers → verify chain linkage → verify ends at checkpoint
3. Store in SPV DB with derived heights
4. Load genesis_burns.json → hash → compare to commitment
5. For each burn: verify merkle proof, ancestry, height, format (rawtx)
6. Create BurnClaimRecords (status=FINAL) + UTXOs
7. Set M0BTC_supply, anchor SPV to checkpoint
```

---

## Appendix B: Regulatory Defense

### Canonical Statements

```
TRUE:
  "Bathron verifies BTC burns via SPV"
  "M0 represents burned BTC at 1:1"
  "M1 represents locked M0 at 1:1"
  "The protocol provides ~1 minute finality"
  "The protocol enables trustless atomic swaps"

FALSE (never say these):
  "Bathron is a stablecoin"
  "M1 is pegged to BTC"
  "Bathron guarantees M1 = 1 BTC"
  "Bathron issues tokens"
  "Bathron provides yield"
  "Bathron has reserves"
```

### If Asked

| Question | Answer |
|----------|--------|
| "Is this a stablecoin?" | No. No concept of price stability at consensus level. |
| "Who issues M1?" | No one. M1 is created by consensus when M0 is locked. |
| "Is there a peg?" | No. 1:1 is an accounting identity, not a price target. |
| "Who controls the protocol?" | No one. No admin keys or upgrade authority. |
| "Is there a reserve?" | No. M0 IS the money, not a reserve backing something. |
| "Can users create stablecoins on Bathron?" | Users can create any script. The protocol does not classify them. |

### The Distinction

```
WHAT THE PROTOCOL DOES:           WHAT IT DOES NOT DO:
  Verify BTC burns (SPV)            Promise prices
  Maintain M0/M1 accounting         Issue tokens
  Execute scripts as written         Manage reserves
  Provide finality                   Stabilize anything
                                     Redeem to BTC

THE PROTOCOL IS A SETTLEMENT RAIL. IT IS NOT A MONETARY POLICY.
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-02-13 | Consolidated from 09-TESTNET-GENESIS v3.0, 12-BTC-BURN-GENESIS v1.6, GENESIS-SAFE v1.0 |
