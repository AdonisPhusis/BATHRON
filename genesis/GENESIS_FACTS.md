# PIV2 Genesis State

**Date:** 2026-01-17
**Lock Height:** 1505
**Block Hash:** `47077dcc4c847263d8c785dbb91204ee7278721d06ff79b608e42bbf2efc5dea`

---

## Supply Summary

| Asset | Amount |
|-------|--------|
| **M0_total** | 3,010,000.00 M0 |
| M0_vaulted | 0.00 |
| M0_shielded | 0.00 |
| M1_supply | 0.00 |
| M2_supply | 0.00 |

## BTC Burns (Genesis Collateral)

| BTC TxID | Amount BTC | Amount Sats | PIV2 Dest | Final Height |
|----------|------------|-------------|-----------|--------------|
| `5d97ae23...1409` | 0.01 BTC | 1,000,000 | pilpous | 652 |
| `7422bfbd...1174` | 0.02 BTC | 2,000,000 | alice | 707 |
| `089706db...97a8` | 0.0001 BTC | 10,000 | alice | 707 |

**Total BTC Burned:** 0.0301 BTC = 3,010,000 sats = 3,010,000 M0

## Invariants Status

| Invariant | Status | Description |
|-----------|--------|-------------|
| A5 | ✅ OK | Anti-inflation: M0_total verified |
| A6 | ✅ OK | Settlement backing: M0_vaulted == M1 + M2 |
| A7 | ✅ OK | Treasury constraints |

## Finality Status

- **Finality Height:** 1505
- **Finality Lag:** 0
- **Status:** healthy

## Genesis Lock Configuration

All nodes configured with:
```
burnclaimpending=0
```

| Node | Config Line |
|------|-------------|
| Seed | `17:burnclaimpending=0` |
| Core+SDK | `14:burnclaimpending=0` |
| OP1 | `15:burnclaimpending=0` |
| OP2 | `15:burnclaimpending=0` |
| OP3 | `15:burnclaimpending=0` |

## Network Nodes

| Node | IP | Role | Status |
|------|-----|------|--------|
| Seed | 57.131.33.151 | Explorer + Seed | healthy |
| Core+SDK | 162.19.251.75 | Dev + MN | healthy |
| OP1 | 57.131.33.152 | MN | healthy |
| OP2 | 57.131.33.214 | MN | healthy |
| OP3 | 51.75.31.44 | Multi-MN (5) | healthy |

## SPV Status

| Node | SPV Height | Synced |
|------|------------|--------|
| Seed | 287477 | true |
| MNs | 287474 | true |

---

## Verification Commands

```bash
# Check genesis state
piv2-cli -testnet getstate

# Verify burns
piv2-cli -testnet listburnclaims final

# Check finality
piv2-cli -testnet getfinalitystatus

# Launch gate
./contrib/testnet/launch-gate.sh
```

---

**Genesis Lock Hash:** `934d300d1364ef1931c6a33d5a316715dc4530b9502ef54544b0235fe9e0d498`

