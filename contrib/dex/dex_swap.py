#!/usr/bin/env python3
"""
BATHRON DEX Swap Automation Script

This script automates the DEX swap process:
1. Lists available LOTs from BATHRON node
2. Sends USDC payment on Polygon
3. Calls lot_take on BATHRON to claim KPIV

Requirements:
    pip install web3 requests

Usage:
    # List available LOTs
    python3 dex_swap.py list

    # Buy KPIV with USDC (automated)
    python3 dex_swap.py buy --lots 5 --evm-key <private_key>

    # Manual lot_take (after external payment)
    python3 dex_swap.py take --outpoint "txid:n" --quote-tx "0x..."

Configuration:
    Set environment variables or edit CONFIG section below.
"""

import os
import sys
import json
import time
import argparse
import subprocess
from typing import Optional, Dict, List, Any

# ============ CONFIGURATION ============

CONFIG = {
    # BATHRON RPC
    "bathron_cli": os.path.expanduser("~/BATHRON-Core/src/bathron-cli"),
    "bathron_network": "-testnet",
    "bathron_rpc_host": "127.0.0.1",
    "bathron_rpc_port": 51475,

    # Polygon RPC (mainnet)
    "polygon_rpc": "https://polygon-rpc.com",
    "polygon_chain_id": 137,

    # USDC on Polygon mainnet
    "usdc_contract": "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359",
    "usdc_decimals": 6,

    # Your addresses
    "bathron_receive_address": "",  # Will receive KPIV
    "evm_private_key": "",       # For sending USDC (NEVER commit!)

    # Gas settings
    "gas_limit": 100000,
    "max_priority_fee_gwei": 30,
    "max_fee_gwei": 50,
}

# ERC20 Transfer ABI
ERC20_ABI = [
    {
        "constant": False,
        "inputs": [
            {"name": "_to", "type": "address"},
            {"name": "_value", "type": "uint256"}
        ],
        "name": "transfer",
        "outputs": [{"name": "", "type": "bool"}],
        "type": "function"
    },
    {
        "constant": True,
        "inputs": [{"name": "_owner", "type": "address"}],
        "name": "balanceOf",
        "outputs": [{"name": "balance", "type": "uint256"}],
        "type": "function"
    }
]

# ============ BATHRON RPC HELPERS ============

def bathron_rpc(method: str, *params) -> Any:
    """Call BATHRON RPC via CLI."""
    cmd = [CONFIG["bathron_cli"], CONFIG["bathron_network"], method]
    cmd.extend([str(p) for p in params])

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            print(f"RPC Error: {result.stderr}", file=sys.stderr)
            return None
        return json.loads(result.stdout) if result.stdout.strip() else None
    except subprocess.TimeoutExpired:
        print("RPC timeout", file=sys.stderr)
        return None
    except json.JSONDecodeError:
        return result.stdout.strip()

def get_dex_info() -> Dict:
    """Get DEX status."""
    return bathron_rpc("dex_info") or {"enabled": False}

def get_lot_list() -> List[Dict]:
    """Get all available LOTs."""
    # lot_list returns empty via CLI, use lot_rebuild + individual queries
    bathron_rpc("lot_rebuild")
    return []  # TODO: Parse lot_list output when fixed

def get_lot(outpoint: str) -> Optional[Dict]:
    """Get specific LOT details."""
    return bathron_rpc("lot_get", outpoint)

def lot_take(outpoint: str, quote_asset: str, taker_address: str, quote_tx_hash: str) -> Optional[Dict]:
    """Submit a lot_take request."""
    return bathron_rpc("lot_take", outpoint, quote_asset, taker_address, quote_tx_hash)

# ============ POLYGON/EVM HELPERS ============

def get_web3():
    """Get Web3 instance."""
    try:
        from web3 import Web3
        w3 = Web3(Web3.HTTPProvider(CONFIG["polygon_rpc"]))
        if not w3.is_connected():
            print("Failed to connect to Polygon RPC", file=sys.stderr)
            return None
        return w3
    except ImportError:
        print("web3 not installed. Run: pip install web3", file=sys.stderr)
        return None

def get_usdc_balance(address: str) -> float:
    """Get USDC balance for address."""
    w3 = get_web3()
    if not w3:
        return 0.0

    usdc = w3.eth.contract(
        address=Web3.to_checksum_address(CONFIG["usdc_contract"]),
        abi=ERC20_ABI
    )

    balance = usdc.functions.balanceOf(Web3.to_checksum_address(address)).call()
    return balance / (10 ** CONFIG["usdc_decimals"])

def send_usdc(to_address: str, amount_usdc: float, private_key: str) -> Optional[str]:
    """Send USDC on Polygon. Returns TX hash."""
    w3 = get_web3()
    if not w3:
        return None

    from web3 import Web3

    # Get account from private key
    account = w3.eth.account.from_key(private_key)
    from_address = account.address

    # USDC contract
    usdc = w3.eth.contract(
        address=Web3.to_checksum_address(CONFIG["usdc_contract"]),
        abi=ERC20_ABI
    )

    # Amount in USDC units (6 decimals)
    amount_units = int(amount_usdc * (10 ** CONFIG["usdc_decimals"]))

    # Check balance
    balance = usdc.functions.balanceOf(from_address).call()
    if balance < amount_units:
        print(f"Insufficient USDC balance: {balance / 1e6:.2f} < {amount_usdc:.2f}", file=sys.stderr)
        return None

    # Build transaction
    nonce = w3.eth.get_transaction_count(from_address)

    tx = usdc.functions.transfer(
        Web3.to_checksum_address(to_address),
        amount_units
    ).build_transaction({
        'chainId': CONFIG["polygon_chain_id"],
        'gas': CONFIG["gas_limit"],
        'maxFeePerGas': w3.to_wei(CONFIG["max_fee_gwei"], 'gwei'),
        'maxPriorityFeePerGas': w3.to_wei(CONFIG["max_priority_fee_gwei"], 'gwei'),
        'nonce': nonce,
    })

    # Sign and send
    signed_tx = w3.eth.account.sign_transaction(tx, private_key)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)

    print(f"USDC TX sent: {tx_hash.hex()}")

    # Wait for confirmation
    print("Waiting for confirmation...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

    if receipt['status'] == 1:
        print(f"TX confirmed in block {receipt['blockNumber']}")
        return tx_hash.hex()
    else:
        print("TX failed!", file=sys.stderr)
        return None

# ============ COMMANDS ============

def cmd_list(args):
    """List available LOTs."""
    dex = get_dex_info()

    print(f"DEX Status: {'Enabled' if dex.get('enabled') else 'Disabled'}")
    print(f"Total LOTs: {dex.get('lot_count', 0)}")
    print(f"Pending Takes: {dex.get('pending_takes', 0)}")
    print(f"Version: {dex.get('version', 'N/A')}")
    print()

    # Show specific LOT if provided
    if args.outpoint:
        lot = get_lot(args.outpoint)
        if lot:
            print(f"LOT Details:")
            print(json.dumps(lot, indent=2))
        else:
            print(f"LOT not found: {args.outpoint}")

def cmd_buy(args):
    """Buy KPIV by sending USDC and calling lot_take."""
    if not args.evm_key:
        print("Error: --evm-key required", file=sys.stderr)
        sys.exit(1)

    if not args.outpoint:
        print("Error: --outpoint required", file=sys.stderr)
        sys.exit(1)

    # Get LOT details
    lot = get_lot(args.outpoint)
    if not lot:
        print(f"LOT not found: {args.outpoint}", file=sys.stderr)
        sys.exit(1)

    print(f"LOT: {lot.get('outpoint')}")
    print(f"Amount: 1 KPIV")
    print(f"Expiry: Block {lot.get('expiry_height')}")

    # Parse payment address from blob (if available)
    # For now, use provided address
    payment_address = args.payment_address
    amount_usdc = args.amount or 0.10

    if not payment_address:
        print("Error: --payment-address required (LP's Polygon address)", file=sys.stderr)
        sys.exit(1)

    print(f"\nPayment Details:")
    print(f"  To: {payment_address}")
    print(f"  Amount: {amount_usdc} USDC")

    # Confirm
    if not args.yes:
        confirm = input("\nProceed with payment? [y/N]: ")
        if confirm.lower() != 'y':
            print("Aborted.")
            sys.exit(0)

    # Send USDC
    tx_hash = send_usdc(payment_address, amount_usdc, args.evm_key)
    if not tx_hash:
        print("Failed to send USDC", file=sys.stderr)
        sys.exit(1)

    # Call lot_take
    receive_address = args.receive_address or CONFIG["bathron_receive_address"]
    if not receive_address:
        print("Error: --receive-address required (your BATHRON address)", file=sys.stderr)
        sys.exit(1)

    print(f"\nCalling lot_take...")
    result = lot_take(args.outpoint, "USDC", receive_address, tx_hash)

    if result:
        print(f"lot_take submitted!")
        print(json.dumps(result, indent=2))
    else:
        print("lot_take failed - you may need to call it manually:", file=sys.stderr)
        print(f"  bathron-cli lot_take \"{args.outpoint}\" \"USDC\" \"{receive_address}\" \"{tx_hash}\"")

def cmd_take(args):
    """Manual lot_take (after external payment)."""
    if not args.outpoint or not args.quote_tx:
        print("Error: --outpoint and --quote-tx required", file=sys.stderr)
        sys.exit(1)

    receive_address = args.receive_address or CONFIG["bathron_receive_address"]
    if not receive_address:
        print("Error: --receive-address required", file=sys.stderr)
        sys.exit(1)

    quote_asset = args.asset or "USDC"

    print(f"Calling lot_take:")
    print(f"  LOT: {args.outpoint}")
    print(f"  Asset: {quote_asset}")
    print(f"  Receive: {receive_address}")
    print(f"  Quote TX: {args.quote_tx}")

    result = lot_take(args.outpoint, quote_asset, receive_address, args.quote_tx)

    if result:
        print(f"\nlot_take submitted!")
        print(json.dumps(result, indent=2))
    else:
        print("\nlot_take failed!", file=sys.stderr)
        sys.exit(1)

def cmd_balance(args):
    """Check USDC balance."""
    if not args.address:
        print("Error: --address required", file=sys.stderr)
        sys.exit(1)

    balance = get_usdc_balance(args.address)
    print(f"USDC Balance: {balance:.6f}")

# ============ MAIN ============

def main():
    parser = argparse.ArgumentParser(description="BATHRON DEX Swap Automation")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # list command
    list_parser = subparsers.add_parser("list", help="List DEX info and LOTs")
    list_parser.add_argument("--outpoint", help="Show specific LOT details")

    # buy command
    buy_parser = subparsers.add_parser("buy", help="Buy KPIV with USDC (automated)")
    buy_parser.add_argument("--outpoint", required=True, help="LOT outpoint (txid:n)")
    buy_parser.add_argument("--payment-address", help="LP's Polygon address for USDC")
    buy_parser.add_argument("--amount", type=float, default=0.10, help="USDC amount (default: 0.10)")
    buy_parser.add_argument("--receive-address", help="Your BATHRON address for KPIV")
    buy_parser.add_argument("--evm-key", help="Your EVM private key (hex, no 0x)")
    buy_parser.add_argument("-y", "--yes", action="store_true", help="Skip confirmation")

    # take command
    take_parser = subparsers.add_parser("take", help="Manual lot_take after external payment")
    take_parser.add_argument("--outpoint", required=True, help="LOT outpoint (txid:n)")
    take_parser.add_argument("--quote-tx", required=True, help="Polygon TX hash (0x...)")
    take_parser.add_argument("--receive-address", help="Your BATHRON address for KPIV")
    take_parser.add_argument("--asset", default="USDC", help="Quote asset (default: USDC)")

    # balance command
    balance_parser = subparsers.add_parser("balance", help="Check USDC balance")
    balance_parser.add_argument("--address", required=True, help="Polygon address")

    args = parser.parse_args()

    if args.command == "list":
        cmd_list(args)
    elif args.command == "buy":
        cmd_buy(args)
    elif args.command == "take":
        cmd_take(args)
    elif args.command == "balance":
        cmd_balance(args)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
