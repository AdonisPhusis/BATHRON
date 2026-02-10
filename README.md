# BATHRON — Deep Dive

> *"The system does not rely on believers. It relies on arbitrageurs.*
> *And arbitrageurs don't believe — they execute."*

This document goes deeper than the [README](README.md). Read that first.

---

## Why BATHRON Exists

**The problem:** BTC has 60-minute finality. USDC has 1-second finality. Swapping between them creates **Herstatt Risk** — one side settles before the other, and the counterparty can default.

**The solution:** An internal settlement token (M1) with ~1 minute finality that bridges the gap. Users never see it. LPs use it as their competitive edge.

This is exactly how CLS solved Herstatt Risk in forex — with internal clearing accounts that end users never touch. CLS has processed $6 trillion/day for 22 years using this model.

---

## Who Is This For

### Retail Users (via PNA-Swap)

```
Open browser → Enter amount → Send BTC → Receive USDC
No account. No KYC. No custody. No M1.
```

The user experience is a simple swap. M1 is invisible. The price is locked at click time — BTC confirmation is backend settlement, not user-facing friction. Same model as a credit card: merchant confirms instantly, Visa settles in 2 days.

### Liquidity Providers (via PNA-LP)

LPs are the market makers. They:
- Burn BTC to create M0, lock M0 to get M1
- Use M1 for fast settlement (~1 min vs BTC's 60 min)
- Earn spreads on every swap
- Set their own prices, manage their own risk
- Join and leave without permission

**LP business model:**
```
LP Capital: $100K
Daily Volume: $50K (at scale)
Spread: 1.0-1.5%
Gross Revenue: $500-750/day
```

### Altcoin Communities

Any chain can be added permissionlessly. PIVX, Dash, Zcash — all route through M1:

```
BTC/M1, USDC/M1, PIVX/M1, DASH/M1, ZEC/M1 ...
```

Each new chain creates new pairs, adds volume to M1, attracts more LPs, tightens spreads. This is the flywheel.

---

## Why M0/M1 = 1 Is Not a Peg

The equality M0/M1 = 1 is often misunderstood as a "peg". It is not.

**It is an internal accounting identity.**

M0 and M1 form a closed settlement system:

- M0 is created only via BTC burn
- M1 is created only by locking M0
- Every M1 is always backed by exactly 1 M0
- There is no circular path to increase supply

This means:

- No internal arbitrage loop
- No reflexivity
- No leverage
- No inflation
- No bank run inside the system

**M0/M1 = 1 is not defended by markets or promises. It is enforced by construction.**

All price discovery happens **outside** the rail (M1/BTC), never inside it.

---

## The M1 Price Mechanism

### Floor (Mechanical)

```
Cost to create 1 M1 = 1 BTC (burned, irrecoverable)
→ M1 cannot be created below cost
→ Supply strictly limited
→ No inflation possible (A5 invariant)
```

### Ceiling (Arbitrage)

```
If M1 > 1 BTC: Burn BTC → sell M1 → profit (instant correction)
If M1 < 1 BTC: Cheap entry for new LPs (self-correcting)
```

### Sub-Parity Is the Bootstrap Mechanism

If M1 trades at 0.90 BTC:

```
New LP burns 1 BTC → gets 1 M0 → locks 1 M1
    → M1 "cost" them 1 BTC but market says 0.90
    → BUT: they don't sell M1 on the market
    → They USE M1 for settlement → earn spreads in BTC/USDC
    → Net profit = spreads earned > entry discount
    → More LPs enter (attracted by discount)
    → More demand for M1 → price recovers
```

**The discount IS the incentive.** Lower M1 = cheaper entry = more LPs = more volume = M1 recovers. This is self-correcting by design.

### The Triangle of Fast Markets

M1 is not priced in isolation. It exists inside a triangle:

```
    BTC ←→ M1 ←→ USDC
     \____________↗
```

- **BTC/M1** (HTLC, atomic swap, OTC)
- **M1/USDC** (CEX, DEX, OTC)
- **BTC/USDC** (global reference market)

These three markets enforce consistency without any protocol intervention.

### Arbitrage Example

Assume:
- BTC/USDC = 50,000
- M1/USDC = 50,200
- M1/BTC = 1.004

An arbitrageur can:
1. Burn 1 BTC → mint 1 M1
2. Sell 1 M1 for 50,200 USDC
3. Buy back BTC on BTC/USDC

**Risk-free profit**, minus execution costs. This pushes M1 back toward BTC. Requires no belief in M1 — just math.

### Why This Is Not Reflexive

- You cannot mint M1 using M1
- You cannot exit without the market
- You cannot lever the system
- You cannot create circular arbitrage
- Every loop references external BTC liquidity

This prevents death spirals, reflexive inflation, and self-referential leverage.

---

## The Competitive Moat

### Why No One Will Build a Competitor

```
BATHRON:
  - 0 token created (M0 = burned BTC, not emitted)
  - 0 dilution
  - 0 ICO / 0 VC
  - 0 governance token
  - 0 protocol treasury
  - 0 block reward
```

To build a competing settlement rail, you need:
- Capital to develop → but no token to sell investors
- Marketing budget → but no token to incentivize
- Governance → but no token to govern with

**The absence of a token is the moat.** No VC will fund a project where the only way to profit is providing real liquidity. No fork can capture value because there is no value to capture except operational profit.

This is the same reason no one has successfully competed with Bitcoin: the value comes from the network and real cost (proof of work / burns), not from speculation or governance.

### Why BATHRON Must Inspire Confidence, Not Speculation

BATHRON is a CLS — a clearing house. Clearing houses don't have governance tokens. They don't have yield farming. They don't have VCs. They have:

- **Rules** (invariants, enforced by code)
- **Neutrality** (no privileged actors)
- **Reliability** (uptime, correctness)

That's it. Arbitrageurs need to trust the mechanism, not believe in a vision.

---

## 4-HTLC Settlement Flow

```
User (BTC) ──HTLC-1──► LP
         ◄──HTLC-2─── LP (M1 + covenant)
              │
              └──HTLC-3──► LP (M1 returns, invisible)
         ◄──HTLC-4─── LP (USDC)

M1 makes round-trip. User never touches it.
Covenants (OP_TEMPLATEVERIFY) force M1 back to LP.
```

**Why 4 HTLCs instead of 2?**

Classic 2-HTLC atomic swaps break when BTC is congested — timeouts expire before confirmation. The 4-HTLC model inserts M1 as a progression checkpoint:

1. HTLC-1: User locks BTC → LP
2. HTLC-2: LP locks M1 → User (with covenant forcing HTLC-3)
3. HTLC-3: M1 returns to LP (covenant-enforced, invisible to user)
4. HTLC-4: LP sends USDC → User

BTC slowness only affects step 1. Steps 2-4 settle on fast chains (~1 min). The swap progresses even if BTC is slow.

---

## Rail Neutrality

BATHRON is designed as a **neutral rail**:

- **No inflation** — supply strictly limited by BTC burned
- **No monetary policy** — no discretionary issuance
- **No native yield** — no protocol-level rewards
- **No privileged actors** — no favoritism
- **No governance** — pure protocol, rules enforced by code

Any compensation comes exclusively from market spreads and services provided outside consensus.

This neutrality is intentional. A settlement rail must be boring to be trusted.

---

## Comparison (Detailed)

| Solution | Finality | Trustless | Large Amounts | Custody | Dilution | Governance |
|----------|----------|-----------|---------------|---------|----------|------------|
| CEX (Binance) | Instant | No | Yes | Yes | BNB | Corporate |
| THORChain | ~1 min | Partial (validators) | Yes | No | RUNE | Token vote |
| wBTC | Instant | No | Yes | BitGo | No | BitGo DAO |
| tBTC | ~1 hr | Partial (threshold) | Medium | No | T token | Token vote |
| Lightning | Instant | Yes | Hard | No | No | None |
| **BATHRON** | **~1 min** | **Yes** | **Yes** | **No** | **No** | **None** |

### vs Lightning

Lightning solves micropayments. BATHRON solves settlement.

- Lightning requires channel management, routing, inbound capacity
- BATHRON: burn BTC, get M1, settle. No channels.
- Lightning is better for $5 coffee
- BATHRON is better for $50K swap

If BATHRON scales, M1 makes Lightning less necessary for cross-chain settlement.

### vs THORChain

Both solve cross-chain swaps. Different trust models:

- THORChain: validator set (can collude), RUNE dilution, IL risk for LPs
- BATHRON: no validators for swaps (HTLCs), no dilution, no IL (LP sets spreads)

THORChain proved the market exists. BATHRON removes the trust assumptions.

---

## Technical Details

### Consensus

| Component | Description |
|-----------|-------------|
| DMM | Deterministic Masternode Mining, 60s blocks |
| HU Finality | ECDSA BFT quorum (2/3), ~1 min |
| Crypto | ECDSA (secp256k1), RedJubjub (Sapling) |
| SPV | BTC headers via consensus TX (TX_BTC_HEADERS) |
| Supply | Burns only, coinbase = fees, block reward = 0 |

### Transaction Types

| Type | ID | Fee | Description |
|------|-----|-----|-------------|
| TX_LOCK | 20 | ~16 sat | M0 → vault + M1 receipt |
| TX_UNLOCK | 21 | ~40 sat | M1 + vault → M0 |
| TX_TRANSFER_M1 | 22 | ~23 sat | Transfer M1 |
| TX_BURN_CLAIM | 31 | 0 | Claim M0 from BTC burn proof |
| TX_MINT_M0BTC | 32 | 0 | Internal: create M0BTC |
| TX_BTC_HEADERS | 33 | 0 | Publish BTC headers on-chain |

### Invariants

```
A5: M0_total(N) = M0_total(N-1) + BurnClaims
A6: M0_vaulted == M1_supply
A9: btc_supply(checkpoint) == expected_supply
```

These are checked at every block. Violation = block rejected. No exceptions.

---

## Further Reading

| Document | Description |
|----------|-------------|
| [09-SETTLEMENT-RAIL-CLS.md](doc/09-SETTLEMENT-RAIL-CLS.md) | Full CLS analogy |
| [06-INFRASTRUCTURE-VISION.md](doc/06-INFRASTRUCTURE-VISION.md) | LP business model |
| [05-SETTLEMENT-RAIL.md](doc/05-SETTLEMENT-RAIL.md) | 4-HTLC technical spec |
| [flowswap.md](doc/flowswap.md) | FlowSwap 3-secret protocol |
| [00-NOMENCLATURE.md](doc/00-NOMENCLATURE.md) | M0/M1 definitions |
| [AUDIT-FEB2026.md](AUDIT-FEB2026.md) | Audit report, Feb 2026 |

---

## License

MIT License — See [COPYING](COPYING)
