#!/usr/bin/env python3
"""
Debug failed EVM transaction to find revert reason.
"""
import json
from web3 import Web3

RPC_URL = "https://sepolia.base.org"
TX_HASH = "0x345b04fe76b299552d4e022753b5700481b4dee13aab6fa2645d5cc51081247b"

USDC_ADDRESS = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
HTLC3S_ADDRESS = "0x667E9bDC368F0aC2abff69F5963714e3656d2d9D"
BOB_ADDRESS = "0x170d28a996799E951d5A95d5ACBaA453DEE6c867"

def main():
    w3 = Web3(Web3.HTTPProvider(RPC_URL))
    print(f"Connected: {w3.is_connected()}")
    print(f"Chain ID: {w3.eth.chain_id}")
    print()

    # Get transaction
    tx = w3.eth.get_transaction(TX_HASH)
    print(f"TX Hash: {TX_HASH}")
    print(f"From: {tx['from']}")
    print(f"To: {tx['to']}")
    print(f"Gas: {tx['gas']}")
    print(f"Gas Price: {tx['gasPrice']}")
    print(f"Nonce: {tx['nonce']}")
    print(f"Input data length: {len(tx['input'])} bytes")
    print()

    # Decode input data
    # create(address,address,uint256,bytes32,bytes32,bytes32,uint256)
    # Selector: 0x first 4 bytes
    input_data = tx['input'].hex() if hasattr(tx['input'], 'hex') else tx['input']
    selector = input_data[:10]
    print(f"Function selector: {selector}")

    # Decode parameters (manual decode)
    data = input_data[10:]  # Remove selector
    chunks = [data[i:i+64] for i in range(0, len(data), 64)]

    print(f"Parameters:")
    params = ['recipient', 'token', 'amount', 'H_user', 'H_lp1', 'H_lp2', 'timelock']
    for i, (name, chunk) in enumerate(zip(params, chunks)):
        if name in ['recipient', 'token']:
            print(f"  {name}: 0x{chunk[-40:]}")
        elif name == 'amount':
            print(f"  {name}: {int(chunk, 16)} ({int(chunk, 16)/1e6} USDC)")
        elif name == 'timelock':
            print(f"  {name}: {int(chunk, 16)}")
        else:
            print(f"  {name}: 0x{chunk}")
    print()

    # Get receipt
    receipt = w3.eth.get_transaction_receipt(TX_HASH)
    print(f"Receipt status: {receipt['status']} ({'SUCCESS' if receipt['status'] == 1 else 'FAILED'})")
    print(f"Gas used: {receipt['gasUsed']}")
    print(f"Logs: {len(receipt['logs'])}")
    print()

    # Check timelock vs block timestamp
    block = w3.eth.get_block(receipt['blockNumber'])
    timelock = int(chunks[6], 16)
    print(f"Block number: {receipt['blockNumber']}")
    print(f"Block timestamp: {block['timestamp']}")
    print(f"Timelock: {timelock}")
    print(f"Timelock > block.timestamp: {timelock > block['timestamp']}")
    print()

    # Check USDC allowance at that block
    usdc_abi = [
        {"name": "allowance", "type": "function", "stateMutability": "view",
         "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}],
         "outputs": [{"name": "", "type": "uint256"}]},
        {"name": "balanceOf", "type": "function", "stateMutability": "view",
         "inputs": [{"name": "account", "type": "address"}],
         "outputs": [{"name": "", "type": "uint256"}]},
    ]

    usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_ADDRESS), abi=usdc_abi)

    # Check at current block
    balance = usdc.functions.balanceOf(BOB_ADDRESS).call()
    allowance = usdc.functions.allowance(BOB_ADDRESS, HTLC3S_ADDRESS).call()
    print(f"Current USDC balance: {balance} ({balance/1e6} USDC)")
    print(f"Current USDC allowance: {allowance}")
    print()

    # Try to simulate the call
    print("Simulating call at latest block...")

    htlc_abi = [
        {"name": "create", "type": "function",
         "inputs": [
             {"name": "recipient", "type": "address"},
             {"name": "token", "type": "address"},
             {"name": "amount", "type": "uint256"},
             {"name": "H_user", "type": "bytes32"},
             {"name": "H_lp1", "type": "bytes32"},
             {"name": "H_lp2", "type": "bytes32"},
             {"name": "timelock", "type": "uint256"}
         ],
         "outputs": [{"name": "htlcId", "type": "bytes32"}]}
    ]

    htlc = w3.eth.contract(address=HTLC3S_ADDRESS, abi=htlc_abi)

    import time
    new_timelock = int(time.time()) + 3600

    # Use same params from tx but with new timelock
    recipient = "0x" + chunks[0][-40:]
    token = "0x" + chunks[1][-40:]
    amount = int(chunks[2], 16)
    h_user = bytes.fromhex(chunks[3])
    h_lp1 = bytes.fromhex(chunks[4])
    h_lp2 = bytes.fromhex(chunks[5])

    try:
        gas = htlc.functions.create(
            Web3.to_checksum_address(recipient),
            Web3.to_checksum_address(token),
            amount,
            h_user,
            h_lp1,
            h_lp2,
            new_timelock
        ).estimate_gas({'from': BOB_ADDRESS})
        print(f"Gas estimate: {gas}")
    except Exception as e:
        print(f"Simulation failed: {e}")
        print(f"Error type: {type(e).__name__}")
        if hasattr(e, 'args'):
            for i, arg in enumerate(e.args):
                print(f"  arg[{i}]: {arg}")

if __name__ == "__main__":
    main()
