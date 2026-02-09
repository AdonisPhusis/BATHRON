#!/bin/bash
# Deploy a fresh HTLC3S contract to Base Sepolia

SSH_KEY="$HOME/.ssh/id_ed25519_vps"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no"
OP1_IP="57.131.33.152"

echo "=== Deploying Fresh HTLC3S Contract ==="

ssh $SSH_OPTS ubuntu@$OP1_IP "
cd /home/ubuntu/pna-lp

# Use forge to deploy
if [ -d contracts ]; then
    cd contracts

    # Check if foundry is available
    if command -v forge &> /dev/null; then
        echo 'Deploying with Forge...'

        # Load private key
        source /home/ubuntu/.BathronKey/evm_env.sh 2>/dev/null || {
            PRIVATE_KEY=\$(python3 -c \"import json; print(json.load(open('/home/ubuntu/.BathronKey/evm.json'))['private_key'])\")
        }

        forge create --rpc-url https://base-sepolia-rpc.publicnode.com \
            --private-key \$PRIVATE_KEY \
            src/HTLC3S.sol:HashedTimelockERC20_3S \
            --broadcast
    else
        echo 'Forge not found. Deploying with web3...'
    fi
else
    echo 'contracts directory not found'
fi
"

echo ""
echo "If forge deployment failed, we'll use solcx in Python..."

ssh $SSH_OPTS ubuntu@$OP1_IP "
python3 << 'PYEOF'
import json
from web3 import Web3
from eth_account import Account

# Check if solcx is available
try:
    import solcx
    print('solcx available')
except ImportError:
    print('Installing solcx...')
    import subprocess
    subprocess.run(['pip3', 'install', '--user', '--break-system-packages', 'py-solc-x'], check=True)
    import solcx

# Install solc if needed
solcx.install_solc('0.8.20')

w3 = Web3(Web3.HTTPProvider('https://base-sepolia-rpc.publicnode.com'))
print(f'Connected, block: {w3.eth.block_number}')

with open('/home/ubuntu/.BathronKey/evm.json') as f:
    deployer = Account.from_key(json.load(f)['private_key'])
print(f'Deployer: {deployer.address}')

# Contract source (simplified for deployment)
source = '''
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract HTLC3S {
    struct HTLC {
        address sender;
        address recipient;
        address token;
        uint256 amount;
        bytes32 H_user;
        bytes32 H_lp1;
        bytes32 H_lp2;
        uint256 timelock;
        bool claimed;
        bool refunded;
    }

    mapping(bytes32 => HTLC) public htlcs;

    event HTLCCreated(bytes32 indexed htlcId, address indexed sender, address indexed recipient,
        address token, uint256 amount, bytes32 H_user, bytes32 H_lp1, bytes32 H_lp2, uint256 timelock);
    event HTLCClaimed(bytes32 indexed htlcId, address indexed claimer, address indexed recipient,
        bytes32 S_user, bytes32 S_lp1, bytes32 S_lp2);
    event HTLCRefunded(bytes32 indexed htlcId, address indexed sender);

    function create(
        address recipient, address token, uint256 amount,
        bytes32 H_user, bytes32 H_lp1, bytes32 H_lp2, uint256 timelock
    ) external returns (bytes32 htlcId) {
        require(recipient != address(0), "Invalid recipient");
        require(token != address(0), "Invalid token");
        require(amount > 0, "Amount must be > 0");
        require(timelock > block.timestamp, "Timelock must be future");
        require(H_user != bytes32(0), "Invalid H_user");
        require(H_lp1 != bytes32(0), "Invalid H_lp1");
        require(H_lp2 != bytes32(0), "Invalid H_lp2");

        htlcId = keccak256(abi.encodePacked(msg.sender, recipient, token, amount,
            H_user, H_lp1, H_lp2, timelock, block.timestamp));
        require(htlcs[htlcId].sender == address(0), "HTLC exists");

        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");

        htlcs[htlcId] = HTLC(msg.sender, recipient, token, amount,
            H_user, H_lp1, H_lp2, timelock, false, false);
        emit HTLCCreated(htlcId, msg.sender, recipient, token, amount,
            H_user, H_lp1, H_lp2, timelock);
    }

    function claim(bytes32 htlcId, bytes32 S_user, bytes32 S_lp1, bytes32 S_lp2) external {
        HTLC storage h = htlcs[htlcId];
        require(h.sender != address(0), "HTLC not found");
        require(!h.claimed && !h.refunded, "Already settled");
        require(block.timestamp < h.timelock, "HTLC expired");
        require(sha256(abi.encodePacked(S_user)) == h.H_user, "Invalid S_user");
        require(sha256(abi.encodePacked(S_lp1)) == h.H_lp1, "Invalid S_lp1");
        require(sha256(abi.encodePacked(S_lp2)) == h.H_lp2, "Invalid S_lp2");

        h.claimed = true;
        require(IERC20(h.token).transfer(h.recipient, h.amount), "Transfer failed");
        emit HTLCClaimed(htlcId, msg.sender, h.recipient, S_user, S_lp1, S_lp2);
    }

    function refund(bytes32 htlcId) external {
        HTLC storage h = htlcs[htlcId];
        require(h.sender != address(0), "HTLC not found");
        require(!h.claimed && !h.refunded, "Already settled");
        require(block.timestamp >= h.timelock, "Not expired");

        h.refunded = true;
        require(IERC20(h.token).transfer(h.sender, h.amount), "Transfer failed");
        emit HTLCRefunded(htlcId, h.sender);
    }

    function getHTLC(bytes32 htlcId) external view returns (
        address, address, address, uint256, bytes32, bytes32, bytes32, uint256, bool, bool
    ) {
        HTLC storage h = htlcs[htlcId];
        return (h.sender, h.recipient, h.token, h.amount,
            h.H_user, h.H_lp1, h.H_lp2, h.timelock, h.claimed, h.refunded);
    }
}
'''

print('Compiling...')
compiled = solcx.compile_source(source, output_values=['abi', 'bin'], solc_version='0.8.20')
contract_data = compiled['<stdin>:HTLC3S']
abi = contract_data['abi']
bytecode = contract_data['bin']

print(f'Bytecode length: {len(bytecode)} bytes')

# Deploy
print('Deploying...')
Contract = w3.eth.contract(abi=abi, bytecode=bytecode)
nonce = w3.eth.get_transaction_count(deployer.address)
gas_price = int(w3.eth.gas_price * 2)

tx = Contract.constructor().build_transaction({
    'from': deployer.address,
    'nonce': nonce,
    'gas': 2000000,
    'gasPrice': gas_price
})

signed = deployer.sign_transaction(tx)
tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
print(f'Deploy TX: {tx_hash.hex()}')

receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
print(f'Status: {receipt.status}')
print(f'Contract: {receipt.contractAddress}')
print(f'Gas used: {receipt.gasUsed}')

if receipt.status == 1:
    print()
    print(f'NEW_CONTRACT:{receipt.contractAddress}')
    print('SUCCESS')
PYEOF
"
