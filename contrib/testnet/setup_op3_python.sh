#!/usr/bin/env bash
# Setup Python dependencies on OP3
set -euo pipefail

OP3_IP="51.75.31.44"
OP3_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519_vps"

echo "Installing Python dependencies on OP3..."

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$OP3_USER@$OP3_IP" << 'REMOTE_EOF'
set -e

# Install pip first
if ! python3 -c "import pip" 2>/dev/null; then
    echo "Installing pip..."
    curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
    python3 /tmp/get-pip.py --user --break-system-packages
fi

# Add .local/bin to PATH
export PATH="$HOME/.local/bin:$PATH"

echo "Installing web3 dependencies..."
python3 -m pip install --user --break-system-packages web3 eth-account pycryptodome

echo "Verifying installation..."
python3 -c "import sys; sys.path.insert(0, '$HOME/.local/lib/python3.13/site-packages'); import web3; import eth_account; print('Dependencies OK')"

echo "Installed packages location: $HOME/.local/lib/python3.13/site-packages"
REMOTE_EOF

echo "Setup complete"
