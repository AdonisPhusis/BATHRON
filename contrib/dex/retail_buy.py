#!/usr/bin/env python3
"""
Retail Buy KPIV - Automated ASK flow for buying KPIV with USDC

Usage:
    python3 retail_buy.py --amount 1 --kpiv-address y7XRqXgz... --polygon-key 0x...

Flow:
    1. Generate secret S and hashlock H = SHA256(S)
    2. Register taker address via Swap Watcher API
    3. Lock USDC on Polygon HTLC contract
    4. Wait for LP to create KPIV HTLC
    5. Claim KPIV (reveals S)
    6. Done!
"""

import os
import sys
import json
import time
import hashlib
import secrets
import argparse
import subprocess
from urllib.request import urlopen, Request
from urllib.error import URLError

# =============================================================================
# CONFIGURATION
# =============================================================================

# Swap Watcher API (on Seed node)
SWAP_WATCHER_URL = "http://57.131.33.151:8080"

# Polygon
POLYGON_RPC = "https://polygon-rpc.com"
HTLC_CONTRACT = "0x3F1843Bc98C526542d6112448842718adc13fA5F"
USDC_CONTRACT = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"
CHAIN_ID = 137

# LP Address (from LOT)
LP_POLYGON_ADDRESS = "0x7348943C8d263ea253c0541656c36b88becD77B9"

# BATHRON CLI
BATHRON_CLI = "/home/ubuntu/BATHRON-Core/src/bathron-cli"
BATHRON_NETWORK = "-testnet"

# HTLC timeouts
POLYGON_TIMELOCK_SECONDS = 6 * 3600  # 6 hours

# =============================================================================
# CRYPTO UTILITIES
# =============================================================================

def generate_secret():
    """Generate random 32-byte secret"""
    return secrets.token_bytes(32)

def compute_hashlock(secret: bytes) -> bytes:
    """Compute SHA256 hashlock from secret"""
    return hashlib.sha256(secret).digest()

def to_hex(data: bytes) -> str:
    """Convert bytes to hex string (no 0x prefix)"""
    return data.hex()

def to_hex_0x(data: bytes) -> str:
    """Convert bytes to hex string with 0x prefix"""
    return "0x" + data.hex()

# =============================================================================
# API CALLS
# =============================================================================

def register_taker(hashlock: str, kpiv_address: str) -> bool:
    """Register taker's KPIV address with Swap Watcher"""
    url = f"{SWAP_WATCHER_URL}/api/register_taker"
    data = json.dumps({
        "hashlock": hashlock,
        "kpiv_address": kpiv_address
    }).encode()

    try:
        req = Request(url, data=data, headers={"Content-Type": "application/json"})
        with urlopen(req, timeout=10) as resp:
            result = json.loads(resp.read())
            return result.get("success", False)
    except Exception as e:
        print(f"Error registering taker: {e}")
        return False

def check_htlc_created(hashlock: str) -> dict:
    """Check if LP has created KPIV HTLC for this hashlock"""
    cmd = [BATHRON_CLI, BATHRON_NETWORK, "htlc_list", hashlock]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            htlcs = json.loads(result.stdout)
            for htlc in htlcs:
                if htlc.get("status") == "active":
                    return htlc
    except Exception as e:
        print(f"Error checking HTLC: {e}")
    return None

def claim_kpiv(outpoint: str, preimage: str) -> dict:
    """Claim KPIV HTLC by revealing preimage"""
    cmd = [BATHRON_CLI, BATHRON_NETWORK, "htlc_claim_kpiv", outpoint, preimage]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            return json.loads(result.stdout)
        else:
            print(f"Claim error: {result.stderr}")
    except Exception as e:
        print(f"Error claiming: {e}")
    return None

# =============================================================================
# POLYGON HTLC
# =============================================================================

def lock_usdc_polygon(private_key: str, amount_usdc: float, hashlock: str, lp_address: str, timelock_seconds: int):
    """Lock USDC on Polygon HTLC contract"""
    try:
        from web3 import Web3
        from eth_account import Account
    except ImportError:
        print("Installing web3...")
        os.system("pip3 install web3 eth_account --quiet")
        from web3 import Web3
        from eth_account import Account

    w3 = Web3(Web3.HTTPProvider(POLYGON_RPC))
    if not w3.is_connected():
        raise Exception("Cannot connect to Polygon RPC")

    account = Account.from_key(private_key)
    print(f"Polygon address: {account.address}")

    # USDC Contract (for approval)
    USDC_ABI = [
        {"constant": False, "inputs": [{"name": "spender", "type": "address"}, {"name": "amount", "type": "uint256"}], "name": "approve", "outputs": [{"name": "", "type": "bool"}], "type": "function"},
        {"constant": True, "inputs": [{"name": "owner", "type": "address"}], "name": "balanceOf", "outputs": [{"name": "", "type": "uint256"}], "type": "function"},
        {"constant": True, "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}], "name": "allowance", "outputs": [{"name": "", "type": "uint256"}], "type": "function"}
    ]
    usdc = w3.eth.contract(address=Web3.to_checksum_address(USDC_CONTRACT), abi=USDC_ABI)

    # Check balance
    balance = usdc.functions.balanceOf(account.address).call()
    amount_units = int(amount_usdc * 1e6)  # USDC has 6 decimals
    print(f"USDC Balance: {balance / 1e6:.2f}")

    if balance < amount_units:
        raise Exception(f"Insufficient USDC. Need {amount_usdc}, have {balance / 1e6:.2f}")

    # HTLC Contract
    HTLC_ABI = [
        {
            "name": "lock",
            "type": "function",
            "inputs": [
                {"name": "swapId", "type": "bytes32"},
                {"name": "recipient", "type": "address"},
                {"name": "token", "type": "address"},
                {"name": "amount", "type": "uint256"},
                {"name": "hashlock", "type": "bytes32"},
                {"name": "timelock", "type": "uint256"}
            ],
            "outputs": []
        }
    ]
    htlc = w3.eth.contract(address=Web3.to_checksum_address(HTLC_CONTRACT), abi=HTLC_ABI)

    # Generate swap ID
    nonce = int(time.time())
    swap_id = w3.keccak(
        Web3.to_bytes(hexstr=lp_address) +
        Web3.to_bytes(hexstr=account.address) +
        Web3.to_bytes(hexstr=hashlock) +
        nonce.to_bytes(32, 'big')
    )

    timelock = int(time.time()) + timelock_seconds

    print(f"Swap ID: {swap_id.hex()}")
    print(f"Hashlock: {hashlock}")
    print(f"Timelock: {timelock} ({time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(timelock))})")

    # Step 1: Approve USDC
    print("\n1. Approving USDC...")
    allowance = usdc.functions.allowance(account.address, HTLC_CONTRACT).call()
    if allowance < amount_units:
        approve_tx = usdc.functions.approve(
            Web3.to_checksum_address(HTLC_CONTRACT),
            amount_units
        ).build_transaction({
            'chainId': CHAIN_ID,
            'gas': 100000,
            'maxFeePerGas': w3.to_wei(50, 'gwei'),
            'maxPriorityFeePerGas': w3.to_wei(30, 'gwei'),
            'nonce': w3.eth.get_transaction_count(account.address),
        })
        signed = account.sign_transaction(approve_tx)
        tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
        print(f"   Approve TX: {tx_hash.hex()}")
        receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
        if receipt['status'] != 1:
            raise Exception("Approval failed")
        print("   Approved!")
    else:
        print("   Already approved")

    # Step 2: Lock USDC
    print("\n2. Locking USDC in HTLC...")
    lock_tx = htlc.functions.lock(
        swap_id,
        Web3.to_checksum_address(lp_address),
        Web3.to_checksum_address(USDC_CONTRACT),
        amount_units,
        Web3.to_bytes(hexstr=hashlock),
        timelock
    ).build_transaction({
        'chainId': CHAIN_ID,
        'gas': 200000,
        'maxFeePerGas': w3.to_wei(50, 'gwei'),
        'maxPriorityFeePerGas': w3.to_wei(30, 'gwei'),
        'nonce': w3.eth.get_transaction_count(account.address),
    })
    signed = account.sign_transaction(lock_tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    print(f"   Lock TX: {tx_hash.hex()}")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

    if receipt['status'] == 1:
        print(f"   Locked {amount_usdc} USDC!")
        return {
            "tx_hash": tx_hash.hex(),
            "swap_id": swap_id.hex(),
            "block": receipt['blockNumber']
        }
    else:
        raise Exception("Lock transaction failed")

# =============================================================================
# MAIN FLOW
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="Buy KPIV with USDC (automated)")
    parser.add_argument("--amount", type=float, required=True, help="Amount of USDC to spend")
    parser.add_argument("--kpiv-address", required=True, help="Your BATHRON address to receive KPIV")
    parser.add_argument("--polygon-key", required=True, help="Your Polygon private key (for USDC)")
    parser.add_argument("--price", type=float, default=0.05, help="Price per KPIV in USDC (default: 0.05)")
    args = parser.parse_args()

    kpiv_amount = args.amount / args.price
    print("=" * 60)
    print("RETAIL BUY KPIV - Automated ASK Flow")
    print("=" * 60)
    print(f"Spending:     {args.amount} USDC")
    print(f"Price:        {args.price} USDC/KPIV")
    print(f"Receiving:    ~{kpiv_amount:.2f} KPIV")
    print(f"KPIV Address: {args.kpiv_address}")
    print("=" * 60)

    # Step 1: Generate secret
    print("\n[1/5] Generating secret...")
    secret = generate_secret()
    hashlock = compute_hashlock(secret)
    secret_hex = to_hex(secret)
    hashlock_hex = to_hex(hashlock)

    print(f"   Secret S:  {secret_hex}")
    print(f"   Hashlock H: {hashlock_hex}")
    print(f"   SAVE YOUR SECRET! You need it to claim KPIV!")

    # Save secret to file
    secret_file = f"/tmp/swap_secret_{hashlock_hex[:16]}.json"
    with open(secret_file, 'w') as f:
        json.dump({"secret": secret_hex, "hashlock": hashlock_hex}, f)
    print(f"   Saved to: {secret_file}")

    # Step 2: Register with Swap Watcher
    print("\n[2/5] Registering with Swap Watcher...")
    if register_taker(hashlock_hex, args.kpiv_address):
        print("   Registered!")
    else:
        print("   WARNING: Registration failed. LP may not respond.")

    # Step 3: Lock USDC on Polygon
    print("\n[3/5] Locking USDC on Polygon...")
    try:
        result = lock_usdc_polygon(
            args.polygon_key,
            args.amount,
            "0x" + hashlock_hex,
            LP_POLYGON_ADDRESS,
            POLYGON_TIMELOCK_SECONDS
        )
        print(f"   TX: {result['tx_hash']}")
    except Exception as e:
        print(f"   ERROR: {e}")
        return 1

    # Step 4: Wait for LP to create KPIV HTLC
    print("\n[4/5] Waiting for LP to create KPIV HTLC...")
    print("   (LP Watcher will detect the lock and respond automatically)")

    htlc = None
    for i in range(60):  # Wait up to 5 minutes
        htlc = check_htlc_created(hashlock_hex)
        if htlc:
            break
        print(f"   Waiting... ({i*5}s)")
        time.sleep(5)

    if not htlc:
        print("   ERROR: LP did not respond in time")
        print(f"   Your USDC is locked. You can refund after timeout.")
        print(f"   Secret saved in: {secret_file}")
        return 1

    print(f"   LP created HTLC!")
    print(f"   Outpoint: {htlc['outpoint']}")
    print(f"   Amount: {htlc['amount']} KPIV")

    # Step 5: Claim KPIV
    print("\n[5/5] Claiming KPIV...")
    claim_result = claim_kpiv(htlc['outpoint'], secret_hex)

    if claim_result:
        print(f"   SUCCESS!")
        print(f"   TX: {claim_result['txid']}")
        print(f"   Claimed: {claim_result['claimed_amount']} KPIV")
        print("\n" + "=" * 60)
        print("SWAP COMPLETE!")
        print(f"You received {claim_result['claimed_amount']} KPIV")
        print("=" * 60)
        return 0
    else:
        print("   ERROR: Claim failed")
        print(f"   Try manually: bathron-cli -testnet htlc_claim_kpiv '{htlc['outpoint']}' '{secret_hex}'")
        return 1

if __name__ == "__main__":
    sys.exit(main())
