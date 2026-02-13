# Incident Report: Seed Node Startup Failure (2026-02-12)

## Summary

After deploying updated binaries, the Seed node (57.131.33.151) failed to start due to a blockchain validation error. The issue was resolved by syncing the node without masternode mode enabled, then re-enabling masternodes.

## Timeline

**14:10** - Deploy updated binaries to all nodes
**14:10** - Seed node fails to start with error: `burn-claim-duplicate, BTC txid already claimed or pending` at block 12616
**14:12-14:21** - Multiple recovery attempts failed due to HU Finality violations preventing reorg
**14:26** - Root cause identified: Seed creating its own finalized chain fork (8 MNs = quorum)
**14:26-14:40** - Successful recovery: sync without MN mode, then re-enable
**14:41** - Network fully recovered, block production resumed

## Root Cause

1. Seed daemon validation detected `burn-claim-duplicate` error in block 12616
2. Initial recovery attempt wiped consensus data but preserved finality database
3. Seed's 8 masternodes created a finality quorum, finalizing its own forked chain
4. Finalized blocks prevented reorg to canonical chain from peers
5. Seed remained isolated on wrong chain

## Technical Details

### Initial Error
```
ERROR: VerifyDB: *** found bad block at 12616, hash=76f0ed1581b9be917d90249a655774cc3391eb44222e07905ba567f7f35a6ef9 
(burn-claim-duplicate, BTC txid already claimed or pending)
```

### Fork Detection
```
Block 528:
- Network: 41927a6584e6798abb830975b4fbc3041c9930c4a2160c364de2e1c26bcda226
- Seed:    bbaa0332899f3613e3eb73626ebf83d819e2cebd1808e214587dd6db99536090
```

### Finality Status (Stuck)
```json
{
  "last_finalized_height": 12618,
  "tip_height": 1001,
  "finality_lag": -11617
}
```

## Solution

Disable masternode mode during initial sync to prevent self-finalization:

```bash
1. Stop daemon
2. Disable MN mode (masternode=0, comment out mnoperatorprivatekey)
3. Wipe ALL databases including finality/
4. Sync as regular node (no finality quorum)
5. Re-enable MN mode
6. Restart daemon
```

## Recovery Scripts

Created/updated:
- `contrib/testnet/fix_seed_fork_final.sh` - Complete recovery procedure
- `contrib/testnet/reenable_seed_mns.sh` - Safely re-enable MNs
- `contrib/testnet/check_seed_daemon.sh` - Diagnostic tool
- `contrib/testnet/check_seed_finality.sh` - Finality diagnostic
- `contrib/testnet/compare_block_hashes.sh` - Fork detection

## Prevention

### For Future Deployments

1. **Always check daemon startup logs** after binary updates
2. **Wipe finality DB** if wiping consensus data: `rm -rf finality/ hu_finality/ khu/`
3. **For multi-MN nodes**: Consider syncing without MN mode first if fork detected
4. **Monitor finality status** during recovery: `getfinalitystatus`

### Code Improvements Needed

1. **Investigate burn-claim-duplicate** - Why did validation reject block 12616?
   - Possible duplicate detection bug in burnclaimdb
   - May need -reindex to rebuild burnclaimdb cleanly
   
2. **Finality DB Consistency** - Should finality be wiped when consensus data is wiped?
   - Consider adding check: if finalized_height > chain_tip, clear finality
   
3. **Fork Recovery** - Better isolation detection for multi-MN hosts
   - Warn if creating finality without external peers

## Files Modified

- `contrib/testnet/fix_seed_startup.sh` - Evolved through multiple iterations
- `contrib/testnet/fix_seed_fork_final.sh` - Final working solution
- `contrib/testnet/reenable_seed_mns.sh` - MN re-enable procedure

## Outcome

- ✅ Seed node recovered and synced to height 12620
- ✅ Block production resumed (12619→12620 observed)
- ✅ All nodes in sync with healthy peer counts
- ✅ Masternodes re-enabled and operational
- ✅ Network stable

## Action Items

1. [ ] Investigate block 12616 burn claim for duplicate detection bug
2. [ ] Review finality DB lifecycle during consensus data wipes
3. [ ] Add automated fork detection to deploy_to_vps.sh --status
4. [ ] Consider startup validation improvements for burnclaimdb consistency
5. [ ] Document multi-MN node recovery procedures in CLAUDE.md

## Related Code Changes

Recent commits before incident:
- `src/wallet/wallet.cpp`: Changed .at() to .find() for vault inputs (CommitTransaction)
- `src/rpc/settlement_wallet.cpp`: Removed M0 fee inputs from unlock RPC

These changes were unrelated to the root cause (burn-claim-duplicate in existing block).

---

**Incident Resolved**: 2026-02-12 14:41 UTC
**Downtime**: ~30 minutes (Seed only, other nodes operational)
**Data Loss**: None (clean resync from peers)
