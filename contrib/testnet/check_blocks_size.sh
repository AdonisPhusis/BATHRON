#!/bin/bash
SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=30"
for IP in 162.19.251.75 57.131.33.151 57.131.33.152 57.131.33.214 51.75.31.44; do
    echo -n "$IP: "
    $SSH ubuntu@$IP 'du -sh ~/.bathron/testnet5/blocks 2>/dev/null; ls -lh ~/.bathron/testnet5/blocks/blk*.dat 2>/dev/null | tail -3' 2>/dev/null
done
