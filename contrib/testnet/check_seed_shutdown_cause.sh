#!/usr/bin/env bash
set -euo pipefail

SEED_IP="57.131.33.151"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

echo "================================================================"
echo "SEED SHUTDOWN ANALYSIS"
echo "================================================================"
echo ""

echo "[$(date +%H:%M:%S)] Last 200 lines before shutdown..."
echo "----------------------------------------------------------------"
$SSH ubuntu@$SEED_IP 'tail -200 ~/.bathron/testnet5/debug.log | grep -B 50 "Shutdown:"' || echo "No shutdown marker found"
echo ""

echo "[$(date +%H:%M:%S)] Checking for stop command in recent history..."
echo "----------------------------------------------------------------"
$SSH ubuntu@$SEED_IP 'grep "bathron-cli.*stop" ~/.bash_history | tail -5 || echo "No stop commands in bash history"'
echo ""

echo "[$(date +%H:%M:%S)] Checking system logs for kills/OOM..."
echo "----------------------------------------------------------------"
$SSH ubuntu@$SEED_IP 'sudo journalctl --since "2026-02-02 19:00:00" | grep -iE "bathrond|killed|oom" || echo "No system kills found"'
echo ""

echo "================================================================"
echo "ANALYSIS COMPLETE"
echo "================================================================"
