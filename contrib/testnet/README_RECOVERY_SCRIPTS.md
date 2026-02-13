# BATHRON Testnet Recovery Scripts

## Quick Reference

### Status & Diagnostics

```bash
# Network-wide status
./deploy_to_vps.sh --status

# Seed daemon logs and status
./check_seed_daemon.sh

# Finality status (Seed)
./check_seed_finality.sh

# Compare block hashes across nodes (fork detection)
./compare_block_hashes.sh <height>

# Get Seed block hash
./get_seed_block_hash.sh <height>

# Full network diagnostic
./diagnose_network.sh
```

### Recovery Procedures

```bash
# Fix Seed startup failure (burn-claim-duplicate)
./fix_seed_startup.sh fix

# Fix Seed fork (complete recovery with MN disable/enable)
./fix_seed_fork_final.sh fix

# Re-enable masternodes after sync
./reenable_seed_mns.sh

# Other node-specific fork fixes
./fix_op3_fork.sh
./fix_coresdk_fork.sh
```

## Common Issues

### 1. Daemon Won't Start - "burn-claim-duplicate"

**Symptoms:**
- Daemon crashes on startup
- Error: `burn-claim-duplicate, BTC txid already claimed or pending`
- VerifyDB fails on specific block

**Solution:**
```bash
./fix_seed_startup.sh fix
```

**What it does:**
- Wipes consensus + finality databases
- Restarts daemon to resync from peers

### 2. Fork + Finality Violation

**Symptoms:**
- Node stuck at specific height
- Error: `HU Finality violation - cannot reorg past finalized block`
- Block hashes differ from network
- Multi-MN node creating own finality quorum

**Solution:**
```bash
./fix_seed_fork_final.sh fix
```

**What it does:**
1. Disables masternode mode (prevents finality)
2. Wipes all consensus + finality databases
3. Syncs as regular node (follows network chain)
4. Re-enables masternodes after sync complete

**Key insight:** Multi-MN hosts (like Seed with 8 MNs) can create their own finality quorum, preventing reorg even when isolated.

### 3. Peer Isolation

**Symptoms:**
- 0 peers
- Can't sync
- Bad addnode config

**Solution:**
Check `bathron.conf` for correct `addnode=` entries. All nodes should have:
```
addnode=57.131.33.151:27171
```

### 4. Database Inconsistency

**Symptoms:**
- "EvoDB is inconsistent with blockchain tip"
- Startup crash

**Solution:**
```bash
# Option A: Targeted wipe + resync
ssh ubuntu@<IP> 'rm -rf ~/.bathron/testnet5/{blocks,chainstate,evodb,settlementdb,finality}'
ssh ubuntu@<IP> '~/bathrond -testnet -daemon'

# Option B: Full reindex
ssh ubuntu@<IP> '~/bathron-cli -testnet stop && ~/bathrond -testnet -daemon -reindex'
```

## Critical Database Directories

When wiping for recovery, ALWAYS include:

```
~/.bathron/testnet5/
├── blocks/          # Block storage
├── chainstate/      # UTXO set
├── index/           # Block index
├── evodb/           # Masternode data
├── llmq/            # Quorum data
├── settlementdb/    # M0/M1 state
├── burnclaimdb/     # BTC burn tracking
├── btcheadersdb/    # BTC SPV headers (consensus)
├── btcspv/          # BTC SPV local data (non-consensus)
├── finality/        # HU Finality checkpoints ⚠️
├── hu_finality/     # Legacy finality data
├── khu/             # Legacy finality data
└── sporks/          # Network params
```

**CRITICAL:** Always wipe `finality/` when wiping consensus data, or you'll hit finality violations.

## Fork Detection

```bash
# Compare block hashes at specific height across all working nodes
./compare_block_hashes.sh 528

# Expected: All nodes return same hash
# If Seed differs = FORK
```

## Finality Status Check

```bash
./check_seed_finality.sh
```

Look for:
- `last_finalized_height` > `tip_height` = Problem (finalized future blocks)
- `finality_lag` should be small (< 10 blocks normally)

## Multi-MN Recovery Strategy

For nodes with multiple masternodes (like Seed):

**Problem:** 8 MNs = quorum threshold (2 of 3), can finalize own chain in isolation

**Solution:**
1. Disable MN mode during recovery sync
2. Let node sync as regular peer (follows canonical chain)
3. Re-enable MNs after catching up

**Script:** `fix_seed_fork_final.sh` implements this pattern

## Preventive Measures

### After Binary Updates

```bash
# Always check daemon started successfully
./deploy_to_vps.sh --status

# Check logs for errors
./check_seed_daemon.sh

# Verify block production continuing
watch -n5 './deploy_to_vps.sh --status'
```

### Before Major Changes

```bash
# Verify network consensus
./compare_block_hashes.sh $(./deploy_to_vps.sh --status | grep height | head -1 | awk -F'height=' '{print $2}' | cut -d',' -f1)

# All nodes should have same hash = healthy
```

## Emergency Contacts

If automated recovery fails:

1. Check incident report: `INCIDENT_REPORT_*.md`
2. Review debug logs manually
3. Consider full genesis reset: `./deploy_to_vps.sh --genesis`

## Script Maintenance

Scripts are located in: `/home/ubuntu/BATHRON/contrib/testnet/`

Key scripts created during incident response:
- `fix_seed_fork_final.sh` - Main recovery tool
- `reenable_seed_mns.sh` - MN re-enable after sync
- `check_seed_daemon.sh` - Quick diagnostic
- `check_seed_finality.sh` - Finality diagnostic
- `compare_block_hashes.sh` - Fork detection
- `get_seed_block_hash.sh` - Helper for Seed queries

All scripts use SSH with key `~/.ssh/id_ed25519_vps` and follow the "no inline SSH" rule.
