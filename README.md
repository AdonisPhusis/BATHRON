# BATHRON

> *"M1 doesn't need a perfect peg. It needs a reason to exist."*

BATHRON is an experimental **BTC-native settlement rail**.

~1 minute trustless finality for BTC-denominated value transfer,
without bridges, custodians, channels, or oracles.

---

## Architecture

```
    BITCOIN (signet/testnet)
              │
              │ BTC Burn (SPV-verified)
              ▼
             M0   ← Base money (1:1 with burned BTC)
              │
              │ Lock/Unlock (instant, 1:1)
              ▼
             M1   ← Settlement token (transferable, ~1 min finality)
              │
              │ HTLC / Atomic Swap
              ▼
         EXIT VIA MARKET
```

| Property | Value |
|----------|-------|
| Entry | Trustless (SPV burn proof) |
| Finality | ~1 minute |
| Exit | Market-based (HTLC, OTC) |
| Custodian | None |

---

## This Is NOT a Stablecoin

| Stablecoin | Settlement Rail |
|------------|-----------------|
| Promises: "always worth $1" | Promises: "settles in 1 minute" |
| Can bank run | Cannot bank run |
| Needs redemption | No redemption promise |

**M1 does not promise to be worth 1 BTC. It promises to settle in 1 minute.**

If M1 trades at a discount, that's the **settlement fee**, not a failure.

---

## Why M0/M1 = 1 Is Not a Peg

The equality M0/M1 = 1 is an **internal accounting identity**, not a peg.

- M0 is created only via BTC burn
- M1 is created only by locking M0
- Every M1 is backed by exactly 1 M0
- No circular path to increase supply

**Enforced by construction, not by promises.**

There is nothing to "attack":
- You cannot mint M1 without burning BTC
- You cannot create a death spiral
- All price discovery happens outside (M1/BTC), never inside

---

## Why Two Assets?

**M0** = audit anchor (tracks burns, transparent)
**M1** = liquid settlement asset (transfers, HTLCs)

Separating them makes the system auditable, neutral, and upgrade-friendly.

---

## Who This Is For

- OTC desks needing fast settlement
- Cross-venue arbitrageurs
- Market makers rebalancing inventory
- HTLC / atomic swap researchers

**Not for**: retail users, yield seekers, DeFi composability (yet).

---

## Current Status

- Bitcoin signet integration
- BATHRON testnet running
- SPV burn detection active
- Deterministic finality via quorum
- **No SDK yet**
- **No production guarantees**

---

## Security & Risk

- BTC burns are **irreversible**
- Liquidity exits are **not guaranteed**
- This software is **experimental**
- **Testnet / signet only**

**Do not use with funds you cannot afford to lose.**

---

## Learn More

For detailed documentation on price mechanisms, arbitrage dynamics,
and system design, see:

→ **[docs/settlement-rail.md](docs/settlement-rail.md)**

---

## Contact

Experimental project. Technical discussions welcome.

**Matrix**: [@adonisphusis:matrix.org](https://matrix.to/#/@adonisphusis:matrix.org)

---

## License

MIT License
