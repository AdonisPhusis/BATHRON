# M0/M1 Settlement Rail - Technical Documentation

> *"M1 doesn't need a perfect peg. It needs a reason to exist."*

This document provides detailed technical documentation for the BATHRON
settlement rail. For a quick overview, see the [README](../README.md).

---

## Table of Contents

1. [What BATHRON Is](#what-bathron-is)
2. [Architecture](#architecture)
3. [Rail Neutrality](#rail-neutrality)
4. [Why M0/M1 = 1 Is Not a Peg](#why-m0m1--1-is-not-a-peg)
5. [Why Not a Stablecoin](#why-not-a-stablecoin)
6. [The Price Mechanism](#the-price-mechanism)
7. [Arbitrage Dynamics](#why-btc-burns-are-not-a-one-way-bet)
8. [Comparison with Alternatives](#comparison)
9. [What Is Not Yet Implemented](#what-is-not-yet-implemented)
10. [FAQ](#faq)

---

## What BATHRON Is

A **settlement infrastructure**, not a stablecoin.

The value proposition is not "M1 = 1 BTC" but rather:
> **"1-minute BTC finality without custodians"**

- Trustless entry via SPV burn proof
- ~1 minute deterministic finality
- No channel management
- Arbitrarily large amounts
- Permissionless and non-custodial

**M1 is a settlement asset, not a retail currency.**

### What BATHRON Is NOT

- Not a stablecoin
- Not a peg promise
- Not a guaranteed BTC exit
- Not a wrapped BTC
- Not a bridge back to Bitcoin
- No yield, no treasury, no governance token

If M1 trades at a discount, that's the **cost of the service**, not a failure.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    BITCOIN (signet/testnet)                 │
│                      (Security Layer)                       │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ BTC Burn (SPV-verified, ~1h)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                          M0                                 │
│               (Base Money - 1:1 with burned BTC)            │
│                   Transparent, auditable                    │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ Lock/Unlock (instant, free)
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                          M1                                 │
│                   (Settlement Token)                        │
│             Transferable, 1-minute finality                 │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ HTLC / Atomic Swap
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    BITCOIN (mainnet)                        │
│                    (Exit via market)                        │
└─────────────────────────────────────────────────────────────┘
```

| Property | Value |
|----------|-------|
| **Entry** | Trustless (SPV burn proof) |
| **Internal Transfer** | ~1 minute finality |
| **Exit** | Market-based (HTLC, OTC) |
| **Custodian** | None |
| **Governance** | None (pure protocol) |
| **Backing** | 1 M0 = 1 BTC burned (verifiable on-chain) |

### Why Two Assets (M0 and M1)?

**M0** is the base unit minted from BTC burns (audit anchor).
**M1** is the liquid settlement asset used for transfers and HTLC flows.

Separating them makes the system:
- **Auditable** - M0 tracks burns transparently
- **Neutral** - M1 supply always equals vaulted M0
- **Upgrade-friendly** - settlement features evolve without changing the audit anchor

---

## Rail Neutrality

BATHRON is designed as a **neutral rail**:

- **No inflation** - supply strictly limited by BTC burned
- **No monetary policy** - no discretionary issuance
- **No native yield** - no protocol-level rewards
- **No privileged actors** - no favoritism

The protocol does not favor savers, borrowers, validators, or liquidity providers.

Any compensation comes exclusively from:
- Market spreads
- Services provided outside consensus

This neutrality is intentional.

---

## Why M0/M1 = 1 Is Not a Peg

The equality M0/M1 = 1 is often misunderstood as a "peg".
It is not.

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

**M0/M1 = 1 is not defended by markets or promises.**
**It is enforced by construction.**

All price discovery happens **outside** the rail (M1/BTC),
never inside it.

### Why This Matters

Because the settlement layer is closed and self-collateralized,
arbitrage inside the system is finite.

**There is nothing to "attack".**

- You cannot mint M1 without burning BTC
- You cannot exit without paying the market spread
- You cannot force redemptions
- You cannot create a death spiral

This is why M0/M1 can be strictly neutral,
while M1/BTC is free to float.

---

## Why Not a Stablecoin?

| Stablecoin | Settlement Rail |
|------------|-----------------|
| Promises: "1 USDC = $1 always" | Promises: "1 min finality, trustless" |
| Value = peg maintenance | Value = service utility |
| Needs reserves/redemption | Needs usage/liquidity |
| Can bank run | Cannot bank run (no redemption promise) |

**M1 does not promise to be worth 1 BTC. It promises to settle in 1 minute.**

---

## The Price Mechanism

### Floor (Minting Cost)

```
Cost to mint 1 M1 = 1 BTC (burned, irrecoverable)
```

This creates a minting floor:
- No rational actor mints M1 to sell below cost
- Supply is strictly limited by BTC burned
- No inflation possible (A5 invariant)

**Note**: The market can price M1 below 1 BTC, but new minting stops
when it's unprofitable. This is the minting floor, not a price floor.

### Ceiling (Arbitrage)

```
If M1 > 1 BTC: Arbitrage burns BTC → sells M1 → profit
If M1 < 1 BTC: No mechanical floor, but utility value provides economic floor
```

### Sub-Parity Is Not Failure

If M1 trades at 0.97 BTC, that's a **3% fee for instant finality**.

Users who value 1-min settlement more than 3% will use it.
This is a price signal, not a failure.

---

## Why BTC Burns Are Not a One-Way Bet

A common misunderstanding is that BTC burns require a long-term belief
that M1 will trade near BTC.

**This is incorrect.**

In practice, BTC burns are not speculative bets.
They are part of **arbitrage flows** across fast markets.

### The Triangle of Fast Markets

M1 is not priced in isolation.
It exists inside a triangle of fast markets:

```
    BTC ↔ M1 ↔ USDC
     \________↗
```

- **BTC/M1** (HTLC, atomic swap, OTC)
- **M1/USDC** (CEX, DEX, OTC)
- **BTC/USDC** (global reference market)

These three markets enforce consistency without any protocol intervention.

### The Arbitrage Loop (Illustrative Example)

*Note: Numbers are illustrative only. Actual profitability depends on
fees, latency, slippage, and market conditions.*

When M1 trades at a premium to BTC:

1. Arbitrageur burns BTC → mints M1
2. Sells M1 on M1/USDC market
3. Buys back BTC on BTC/USDC market
4. Profit = premium minus execution costs

This arbitrage:
- Increases M1 supply when M1 is overpriced
- Pushes M1 price back toward BTC
- **Requires no belief in M1 long-term value**

### What If M1 Trades Below BTC?

**1. No Forced Redemption = No Bank Run**

The protocol does not promise redemption at par.
There is no panic loop. No one is forced to sell.

**2. Arbitrage Still Exists — Just Differently**

If a trader needs fast BTC settlement, they can:
- Buy M1 at a discount
- Use M1 to settle in 1 minute
- Avoid 60-minute BTC finality
- **Save time > spread**

The discount is not a failure.
It is the **settlement fee expressed as a market price**.

### Why This Is Auto-Stabilizing

The system self-regulates through **depth**, not promises.

As liquidity grows:
- M1/BTC spreads tighten
- M1/USDC mirrors BTC/USDC
- Arbitrage becomes cheaper
- Discounts compress naturally

There is no single stabilizer. No peg defender. No treasury.

Stability emerges from:
- Multiple fast markets
- Professional arbitrage
- Real settlement demand

### Why This Is Not Reflexive

Crucially:
- You cannot mint M1 using M1
- You cannot exit without the market
- You cannot lever the system
- You cannot create circular arbitrage

Every arbitrage loop ultimately references **external BTC liquidity**.

This prevents:
- Death spirals
- Reflexive inflation
- Self-referential leverage

### Key Takeaway

**BTC burns are not blind sacrifices.**
**They are the minting leg of arbitrage strategies in fast settlement markets.**

As long as:
- Fast BTC settlement has value
- Arbitrage opportunities exist
- Liquidity paths are open

M1 does not need belief. It needs usage.

> *"The system does not rely on believers.*
> *It relies on arbitrageurs.*
> *And arbitrageurs don't believe — they execute."*

---

## Comparison

| Solution | Finality | Trustless | Capacity | Exit |
|----------|----------|-----------|----------|------|
| Bitcoin L1 | 60 min | Yes | Low | Native |
| Lightning | Instant | Partial | Medium | Native |
| wBTC | Instant | No | High | Custodian |
| tBTC | Instant | Partial | Medium | Threshold sig |
| **M0/M1** | **1 min** | **Yes** | **High** | **Market** |

### Why Not Lightning?

- Channel management overhead
- Liquidity routing issues
- Inbound capacity problems
- Not suitable for large amounts

### Why M0/M1?

- **Truly trustless**: No custodian, no signers, no federation
- **Simple**: Burn + SPV proof, nothing else
- **Irreversible backing**: Can't be "unbacked"
- **Verifiable**: Anyone can audit total supply vs total burns

---

## What Is Not Yet Implemented

- **No HTLC / swap SDK yet**
- **No offer discovery system** (orderbook / quotes)
- **No dexcrow / cross-chain escrow standard**

These are intentionally absent for now.

The core focuses on:
- Settlement rail validity
- Deterministic finality
- Clear separation between infrastructure and market

Market mechanisms (SDK, DEX, clearing, escrow) must remain
**agnostic**, **permissionless**, and **outside consensus**.

### SDK and Upper Layers (Future)

An SDK may exist to:
- Standardize M1/BTC HTLCs
- Facilitate integration with existing systems (BasicSwap, Bisq, etc.)
- Expose settlement and swap primitives

This SDK will make **no economic assumptions**.
It will remain optional, outside consensus, and replaceable.

The rail must remain useful even if multiple competing SDKs exist.

---

## Target Users

### Who This Is For

- **OTC Desks** - Large BTC trades need fast, final settlement
- **Cross-venue Arbitrage** - Profit windows close in seconds
- **Market Makers** - Inventory rebalancing requires speed
- **Atomic Swaps** - HTLC timeouts constrained by BTC finality
- **High-value Payments** - Large transfers can't wait 1 hour

### Who This Is NOT For (Yet)

- Retail users
- Yield seekers
- Stablecoin users
- DeFi composability
- UI-first workflows

Those layers belong **above** the settlement rail.

---

## FAQ

**Q: What if M1 trades at 0.90 BTC?**

A: Then the "cost" of using the settlement rail is 10%. Users who value
1-min finality more than 10% will still use it. This is a price signal,
not a failure.

**Q: Can the protocol force M1 = 1 BTC?**

A: No, and it shouldn't. Promising a peg creates bank run risk.
The protocol promises finality, not price.

**Q: Who would burn BTC knowing they might not get 1 BTC back?**

A: Arbitrageurs executing spread trades, not speculators betting on price.
The burn is one leg of a multi-market arbitrage, not a directional bet.

**Q: What prevents M1 going to zero?**

A: Utility. As long as 1-min trustless settlement has value, M1 has value.
If no one wants fast settlement, M1 has no reason to exist (but neither
does the problem it solves).

**Q: Is this just a worse Lightning?**

A: Different tradeoffs. Lightning = instant but channel management.
M0/M1 = 1 minute but no channels, higher capacity, simpler for large amounts.

**Q: Why two assets (M0 and M1)?**

A: M0 is the audit anchor (tracks burns). M1 is the liquid settlement asset.
Separating them makes the system auditable and upgrade-friendly.

---

## Contact

Experimental project. Technical discussions welcome.

**Matrix**: [@adonisphusis:matrix.org](https://matrix.to/#/@adonisphusis:matrix.org)

If you are working on:
- HTLC protocols
- Atomic swaps
- Settlement infrastructure
- BasicSwap / Bisq / Komodo-style systems

feel free to reach out.

---

## License

MIT License
