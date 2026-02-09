#!/bin/bash
# Check btcspv tip on Seed
set -e
SSH="ssh -i /home/ubuntu/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

echo "=== Checking btcspv state on Seed ==="

# Kill any running daemon, clean lock
$SSH ubuntu@57.131.33.151 'pkill -9 bathrond 2>/dev/null || true; sleep 2; rm -f ~/.bathron/testnet5/.lock'
sleep 1

# Check backup file
echo "--- Backup file ---"
$SSH ubuntu@57.131.33.151 'ls -la ~/btcspv_backup_latest.tar.gz 2>/dev/null; readlink ~/btcspv_backup_latest.tar.gz 2>/dev/null'

# Check btcspv directory
echo "--- btcspv directory ---"
$SSH ubuntu@57.131.33.151 'ls -la ~/.bathron/testnet5/btcspv/ 2>/dev/null | head -5; du -sh ~/.bathron/testnet5/btcspv/ 2>/dev/null'

# Start daemon and check SPV tip
echo "--- Starting daemon to check SPV tip ---"
$SSH ubuntu@57.131.33.151 '
    ~/bathrond -testnet -daemon -noconnect -listen=0 2>/dev/null
    sleep 12
    echo "getblockcount: $(~/bathron-cli -testnet getblockcount 2>/dev/null)"
    echo "btcsyncstatus: $(~/bathron-cli -testnet getbtcsyncstatus 2>/dev/null)"
    echo "btcheaderstip: $(~/bathron-cli -testnet getbtcheaderstip 2>/dev/null)"
    echo "getbtcheadersstatus: $(~/bathron-cli -testnet getbtcheadersstatus 2>/dev/null)"
    # Check debug.log for GENESIS lines
    echo "--- debug.log GENESIS/SPV lines ---"
    grep -i "GENESIS\|btcspv\|spv.*tip\|m_bestHeight" ~/.bathron/testnet5/debug.log 2>/dev/null | tail -20
    ~/bathron-cli -testnet stop 2>/dev/null
'
echo "=== Done ==="
