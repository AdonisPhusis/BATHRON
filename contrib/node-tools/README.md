# BATHRON Node Tools

Permissionless tools for BATHRON node operators. Anyone can run these daemons to strengthen the network.

## Why Run These?

Today, a single node publishes BTC headers and processes burn claims. That's a centralization risk. By running these tools, you:

- **Decentralize SPV header publication** - more publishers = more resilient consensus
- **Decentralize burn claim processing** - anyone can claim burns for anyone (credits go to the address in the burn metadata, not the submitter)

## Tools

### btc_header_daemon.sh

Syncs BTC headers into BATHRON's SPV chain. Polls your local Bitcoin node and submits headers to your BATHRON node, which then broadcasts `TX_BTC_HEADERS` to the network.

```
BTC Node --> [this daemon] --> submitbtcheaders --> btcspv
                                                      |
                              auto-publisher (60s) --> TX_BTC_HEADERS --> all nodes
```

### btc_burn_claim_daemon.sh

Scans BTC blocks for BATHRON burn transactions (OP_RETURN with `BATHRON` magic) and auto-submits `TX_BURN_CLAIM` on the BATHRON network. Burns are fee-free and credits go to the destination encoded in the burn metadata.

```
BTC Node --> [scan for burns] --> [check if claimed] --> submitburnclaimproof
                                                              |
                                                              v
                                                    TX_BURN_CLAIM (fee-free)
                                                              |
                                                    K confirmations later
                                                              |
                                                    TX_MINT_M0BTC (auto)
```

## Requirements

- **Bitcoin Core** (Signet for testnet, Mainnet for production) with `txindex=1`
- **bathrond** running and synced
- `bitcoin-cli` and `bathron-cli` accessible
- `jq` installed

## Quick Start

```bash
# 1. Configure paths (or use defaults)
export BTC_CLI=/path/to/bitcoin-cli
export BTC_DATADIR=/path/to/.bitcoin-signet
export BATHRON_CLI=/path/to/bathron-cli

# 2. Start BTC header sync
./btc_header_daemon.sh start

# 3. Start burn claim daemon
./btc_burn_claim_daemon.sh start

# 4. Check status
./btc_header_daemon.sh status
./btc_burn_claim_daemon.sh status
```

## Configuration

All configuration via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `BTC_CLI` | `~/bitcoin-27.0/bin/bitcoin-cli` | Path to bitcoin-cli |
| `BTC_DATADIR` | `~/.bitcoin-signet` | Bitcoin data directory |
| `BTC_CONF` | `$BTC_DATADIR/bitcoin.conf` | Bitcoin config file |
| `BATHRON_CLI` | `~/bathron-cli` | Path to bathron-cli |
| `INTERVAL` | `120` (headers) / `300` (burns) | Poll interval in seconds |

## Commands

Both daemons support the same commands:

```bash
./btc_header_daemon.sh start      # Start in background
./btc_header_daemon.sh stop       # Stop daemon
./btc_header_daemon.sh status     # Check status + sync progress
./btc_header_daemon.sh once       # Run one cycle (for testing)
./btc_header_daemon.sh logs       # Tail daemon logs
```

The burn claim daemon also supports:

```bash
./btc_burn_claim_daemon.sh bootstrap   # Aggressive scan for initial setup
```

## How Burns Work

1. User sends BTC to an unspendable P2WSH address with an OP_RETURN containing: `BATHRON|01|<NET>|<DEST_HASH160>`
2. This daemon detects the burn after K=6 confirmations
3. Submits `TX_BURN_CLAIM` with merkle proof (fee-free)
4. After K confirmations on BATHRON, `TX_MINT_M0BTC` is created automatically
5. M0BTC is credited to the destination address encoded in the burn

Anyone can submit the claim - it doesn't matter who runs the daemon. The M0BTC always goes to the address specified by the burner.

## License

Same as BATHRON Core.
