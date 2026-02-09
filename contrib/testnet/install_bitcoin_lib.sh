#!/bin/bash
# Install python-bitcoinlib on OP3 for HTLC signing

set -e

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP3_IP="51.75.31.44"

echo "Installing python-bitcoinlib on OP3..."

cat << 'INSTALL_SCRIPT' > /tmp/install_btclib.sh
#!/bin/bash
echo "Checking python-bitcoinlib..."
if python3 -c "import bitcoin" 2>/dev/null; then
    echo "Already installed"
else
    echo "Installing..."
    pip3 install --user python-bitcoinlib 2>/dev/null || \
    pip3 install --break-system-packages python-bitcoinlib 2>/dev/null || \
    {
        python3 -m venv /tmp/btc_env
        /tmp/btc_env/bin/pip install python-bitcoinlib
        echo "Installed in venv: /tmp/btc_env"
    }
fi

# Test
python3 -c "import bitcoin; print('OK')" 2>/dev/null || \
/tmp/btc_env/bin/python3 -c "import bitcoin; print('OK (venv)')" 2>/dev/null || \
echo "Install failed"
INSTALL_SCRIPT

scp $SSH_OPTS /tmp/install_btclib.sh ubuntu@$OP3_IP:/tmp/
ssh $SSH_OPTS ubuntu@$OP3_IP "chmod +x /tmp/install_btclib.sh && /tmp/install_btclib.sh"
