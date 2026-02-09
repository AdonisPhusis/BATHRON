#!/usr/bin/env python3
# Copyright (c) 2025 The BATHRON 2.0 developers
# Distributed under the MIT software license

"""
LP Watcher - Automated LP for HTLC Atomic Swaps (ASK Flow)

Trustless ASK Flow:
1. Retail generates S, H = SHA256(S)
2. Retail locks USDC on Polygon (hashlock H)
3. LP Watcher detects the lock
4. LP creates HTLC KPIV on BATHRON (same hashlock H)
5. Retail claims KPIV (reveals S on BATHRON chain)
6. LP Watcher detects S, claims USDC on Polygon

Configuration:
- LP_POLYGON_ADDRESS: Your Polygon address (receives USDC locks)
- LP_POLYGON_PRIVATE_KEY: For claiming USDC
- LOT prices: Define at what price to respond to locks
"""

import json
import time
import logging
import subprocess
import threading
from typing import Optional, Dict, Any, List
from dataclasses import dataclass, field
from urllib.request import urlopen, Request
from web3 import Web3
from eth_account import Account

# =============================================================================
# CONFIGURATION
# =============================================================================

BATHRON_CLI = "/home/ubuntu/BATHRON-Core/src/bathron-cli"
BATHRON_NETWORK = "-testnet"

# Swap Watcher API (for taker address registration)
SWAP_WATCHER_URL = "http://127.0.0.1:8080"

# =============================================================================
# MULTI-CHAIN NETWORK CONFIGURATIONS
# =============================================================================

NETWORKS = {
    "polygon": {
        "name": "Polygon",
        "rpc": "https://polygon-rpc.com",
        "htlc": "0x3F1843Bc98C526542d6112448842718adc13fA5F",
        "usdc": "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359",
        "chain_id": 137,
    },
    "worldchain": {
        "name": "World Chain",
        "rpc": "https://worldchain-mainnet.g.alchemy.com/public",
        "htlc": "0x7a8370b79Be8aBB2b9F72afd9Fba31D70D357F0b",
        "usdc": "0x79a02482a880bce3f13e09da970dc34db4cd24d1",
        "chain_id": 480,
    },
    "base": {
        "name": "Base",
        "rpc": "https://mainnet.base.org",
        "htlc": "0xd7937b1C7D25239b4c829aDA9D137114fcefD9A8",
        "usdc": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        "chain_id": 8453,
    },
}

# Default network (can be overridden via --network)
ACTIVE_NETWORK = "worldchain"

# LP Configuration
LP_EVM_ADDRESS = "0xA1b41Fb9D8d82bDcA0bA5D7115D4C04be64171B6"  # LP address (receives USDC locks)
LP_EVM_PRIVATE_KEY = ""  # Set via environment or config file (NEVER commit!)

# Legacy aliases
LP_POLYGON_ADDRESS = LP_EVM_ADDRESS
LP_POLYGON_PRIVATE_KEY = LP_EVM_PRIVATE_KEY

# Pricing (KPIV/USDC rate)
LP_PRICE = 0.05  # 1 KPIV = 0.05 USDC (matches LOT)

# HTLC timeouts
KPIV_EXPIRY_BLOCKS = 720  # ~12 hours (longer than Polygon to ensure safety)

# Event signatures (keccak256)
LOCKED_TOPIC = "0x" + Web3.keccak(text="Locked(bytes32,address,address,address,uint256,bytes32,uint256)").hex()

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
log = logging.getLogger(__name__)

# =============================================================================
# HTLC CONTRACT ABI (minimal)
# =============================================================================

HTLC_ABI = [
    {
        "name": "claim",
        "type": "function",
        "inputs": [
            {"name": "swapId", "type": "bytes32"},
            {"name": "preimage", "type": "bytes32"}
        ],
        "outputs": []
    },
    {
        "name": "swaps",
        "type": "function",
        "inputs": [{"name": "", "type": "bytes32"}],
        "outputs": [
            {"name": "sender", "type": "address"},
            {"name": "recipient", "type": "address"},
            {"name": "token", "type": "address"},
            {"name": "amount", "type": "uint256"},
            {"name": "hashlock", "type": "bytes32"},
            {"name": "timelock", "type": "uint256"},
            {"name": "withdrawn", "type": "bool"},
            {"name": "refunded", "type": "bool"}
        ]
    }
]

# =============================================================================
# DATA STRUCTURES
# =============================================================================

@dataclass
class PendingSwap:
    """Tracks a swap in progress"""
    hashlock: str
    polygon_swap_id: str
    usdc_amount: float
    kpiv_amount: float
    polygon_timelock: int

    # BATHRON HTLC info (filled after we create it)
    kpiv_htlc_outpoint: str = ""
    kpiv_htlc_created: bool = False

    # Completion
    preimage_revealed: str = ""
    usdc_claimed: bool = False
    created_at: float = field(default_factory=time.time)

# =============================================================================
# BATHRON RPC
# =============================================================================

def bathron_rpc(method: str, *args) -> Any:
    """Call BATHRON RPC via CLI"""
    cmd = [BATHRON_CLI, BATHRON_NETWORK, method] + [str(a) for a in args]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            log.error(f"BATHRON RPC error: {result.stderr}")
            return None
        return json.loads(result.stdout) if result.stdout.strip() else None
    except Exception as e:
        log.error(f"BATHRON RPC exception: {e}")
        return None

def create_kpiv_htlc(amount: float, hashlock: str, taker_address: str, expiry_blocks: int = 120) -> Optional[Dict]:
    """Create KPIV HTLC on BATHRON chain

    RPC signature: htlc_create_kpiv <hashlock> <amount> <recipient> [expiry]
    """
    log.info(f"Creating KPIV HTLC: {amount} KPIV, hashlock={hashlock[:16]}..., recipient={taker_address}")

    # Call htlc_create_kpiv RPC
    # Order: hashlock, amount, recipient, expiry_blocks
    result = bathron_rpc("htlc_create_kpiv", hashlock, str(amount), taker_address, str(expiry_blocks))

    if result and "txid" in result:
        log.info(f"KPIV HTLC created: txid={result['txid']}")
        return result
    else:
        log.error(f"Failed to create KPIV HTLC: {result}")
        return None

def get_htlc_by_hashlock(hashlock: str) -> Optional[Dict]:
    """Get HTLC by hashlock"""
    htlcs = bathron_rpc("htlc_list", hashlock)
    if htlcs and len(htlcs) > 0:
        # Return first active HTLC with matching hashlock
        for htlc in htlcs:
            if htlc.get("status") == "claimed":
                return htlc  # Has preimage revealed
        return htlcs[0]
    return None

def refund_kpiv_htlc(outpoint: str) -> Optional[str]:
    """Refund expired KPIV HTLC back to LP

    RPC signature: htlc_refund_kpiv <outpoint> [destination]
    """
    log.info(f"Refunding KPIV HTLC: outpoint={outpoint}")
    result = bathron_rpc("htlc_refund_kpiv", outpoint)

    if result and isinstance(result, dict) and result.get("txid"):
        log.info(f"KPIV HTLC refunded: txid={result['txid']}")
        return result['txid']
    elif isinstance(result, str):
        log.info(f"KPIV HTLC refunded: txid={result}")
        return result
    else:
        log.error(f"Failed to refund KPIV HTLC: {result}")
        return None

def get_taker_kpiv_address(hashlock: str) -> Optional[str]:
    """Query Swap Watcher API for registered taker address"""
    # Normalize hashlock (remove 0x prefix)
    hashlock_clean = hashlock[2:] if hashlock.startswith("0x") else hashlock

    try:
        url = f"{SWAP_WATCHER_URL}/api/taker_address?hashlock={hashlock_clean}"
        req = Request(url, headers={"Accept": "application/json"})
        with urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            if data.get("found"):
                return data.get("kpiv_address")
    except Exception as e:
        log.debug(f"Taker address lookup failed: {e}")

    return None

def update_orderbook_lot(lot_id: str, amount_filled: float):
    """Update LOT in order book after trade (reduce remaining amount)

    Uses /api/lots/update endpoint:
    POST {"lot_id": "xxx", "filled_amount": 100.0}
    """
    try:
        update_url = f"{SWAP_WATCHER_URL}/api/lots/update"
        update_data = json.dumps({
            "lot_id": lot_id,
            "filled_amount": amount_filled
        }).encode()
        update_req = Request(update_url, data=update_data,
                            headers={"Content-Type": "application/json"})
        with urlopen(update_req, timeout=5) as update_resp:
            result = json.loads(update_resp.read())
            if result.get("success"):
                new_remaining = result.get("new_remaining", 0)
                log.info(f"Order book updated: LOT {lot_id[:8]}... remaining={new_remaining}")
                return True
            else:
                log.warning(f"Order book update failed: {result.get('error', 'unknown')}")
    except Exception as e:
        log.error(f"Failed to update order book: {e}")
    return False

def notify_trade_executed(kpiv_amount: float, hashlock: str, status: str = "htlc_created"):
    """Notify order book of trade execution.

    Finds matching ASK LOT and updates remaining amount.
    Uses /api/orderbook which returns sorted asks/bids.
    """
    try:
        # Get orderbook (asks sorted by price ascending)
        url = f"{SWAP_WATCHER_URL}/api/orderbook?pair=KPIV/USDC"
        req = Request(url, headers={"Accept": "application/json"})
        with urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            asks = data.get("asks", [])

            # Find first ASK LOT with enough remaining (already sorted by price)
            for ask in asks:
                remaining = ask.get("remaining", ask.get("size", 0))
                if remaining >= kpiv_amount and ask.get("status") == "open":
                    lot_id = ask.get("lot_id")
                    log.info(f"Trade matched to LOT {lot_id[:8]}... ({kpiv_amount} KPIV)")
                    update_orderbook_lot(lot_id, kpiv_amount)
                    return True

            log.warning(f"No matching LOT found for trade of {kpiv_amount} KPIV")
    except Exception as e:
        log.error(f"Failed to notify trade: {e}")
    return False

# =============================================================================
# POLYGON MONITORING
# =============================================================================

class EVMMonitor:
    """Monitors EVM chain for HTLC events (Polygon, World Chain, Base)"""

    def __init__(self, lp_address: str, private_key: str = "", network: str = None):
        self.network_key = network or ACTIVE_NETWORK
        self.network_config = NETWORKS[self.network_key]

        self.w3 = Web3(Web3.HTTPProvider(self.network_config["rpc"]))
        self.lp_address = lp_address.lower()
        self.private_key = private_key
        self.htlc_address = self.network_config["htlc"]
        self.usdc_address = self.network_config["usdc"]

        self.htlc_contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(self.htlc_address),
            abi=HTLC_ABI
        )
        self.last_block = self.w3.eth.block_number - 100  # Start 100 blocks back

        log.info(f"EVMMonitor initialized for {self.network_config['name']}")
        log.info(f"  HTLC: {self.htlc_address}")
        log.info(f"  USDC: {self.usdc_address}")

    def scan_for_locks(self) -> List[Dict]:
        """Scan for new USDC locks targeting our LP address"""
        current_block = self.w3.eth.block_number

        if current_block <= self.last_block:
            return []

        locks = []

        try:
            # Query Locked events
            # Topic[0] = event signature
            # Topic[1] = swapId (indexed)
            # Topic[2] = recipient (indexed) - this is the LP address

            lp_topic = "0x" + self.lp_address[2:].lower().zfill(64)

            logs = self.w3.eth.get_logs({
                "address": self.htlc_address,
                "fromBlock": self.last_block + 1,
                "toBlock": current_block,
                "topics": [None, None, lp_topic]  # Any event, any swapId, our LP address
            })

            for log_entry in logs:
                try:
                    # Parse topics:
                    # topics[0] = event signature
                    # topics[1] = swapId (indexed)
                    # topics[2] = recipient (indexed) - our LP address
                    # topics[3] = sender (indexed)
                    topics = log_entry["topics"]
                    swap_id = topics[1].hex() if len(topics) > 1 else ""
                    sender = "0x" + topics[3].hex()[26:] if len(topics) > 3 else ""

                    # Decode data: token, amount, hashlock, timelock (4 * 32 bytes = 256 hex chars)
                    data = log_entry["data"].hex() if isinstance(log_entry["data"], bytes) else log_entry["data"]
                    if data.startswith("0x"):
                        data = data[2:]

                    log.debug(f"Parsing event data: len={len(data)}")

                    if len(data) >= 256:  # 4 * 64 hex chars
                        token = "0x" + data[24:64]       # bytes 0-32: token address (last 20 bytes)
                        amount_hex = data[64:128]         # bytes 32-64: amount
                        hashlock = "0x" + data[128:192]   # bytes 64-96: hashlock
                        timelock_hex = data[192:256]      # bytes 96-128: timelock

                        amount = int(amount_hex, 16) / 1e6  # USDC has 6 decimals
                        timelock = int(timelock_hex, 16)

                        log.info(f"Parsed lock: token={token}, amount={amount}, hashlock={hashlock[:18]}...")

                        # Only process USDC locks
                        if token.lower() == self.usdc_address.lower():
                            locks.append({
                                "swap_id": swap_id,
                                "sender": sender,
                                "recipient": self.lp_address,
                                "token": token,
                                "amount": amount,
                                "hashlock": hashlock,
                                "timelock": timelock,
                                "tx_hash": log_entry["transactionHash"].hex()
                            })
                            log.info(f"Found USDC lock: {amount} USDC, hashlock={hashlock[:18]}...")
                        else:
                            log.debug(f"Skipping non-USDC token: {token}")
                    else:
                        log.warning(f"Data too short: {len(data)} chars, expected >= 256")

                except Exception as parse_error:
                    log.error(f"Error parsing log entry: {parse_error}")

            self.last_block = current_block

        except Exception as e:
            log.error(f"Error scanning Polygon: {e}")

        return locks

    def claim_usdc(self, swap_id: str, preimage: str) -> Optional[str]:
        """Claim USDC from HTLC using revealed preimage"""
        if not self.private_key:
            log.warning("No private key configured - cannot auto-claim USDC")
            # SECURITY: Never log full preimage - mask it
            preimage_masked = preimage[:10] + "..." + preimage[-4:] if len(preimage) > 14 else "***"
            log.info(f"Manual claim required: swap_id={swap_id[:18]}..., preimage={preimage_masked}")
            return None

        try:
            account = Account.from_key(self.private_key)

            # Build claim transaction
            tx = self.htlc_contract.functions.claim(
                bytes.fromhex(swap_id[2:] if swap_id.startswith("0x") else swap_id),
                bytes.fromhex(preimage[2:] if preimage.startswith("0x") else preimage)
            ).build_transaction({
                "from": account.address,
                "gas": 100000,
                "gasPrice": self.w3.eth.gas_price,
                "nonce": self.w3.eth.get_transaction_count(account.address)
            })

            # Sign and send
            signed = account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed.rawTransaction)

            log.info(f"USDC claim TX sent: {tx_hash.hex()}")
            return tx_hash.hex()

        except Exception as e:
            log.error(f"Failed to claim USDC: {e}")
            return None

# =============================================================================
# LP WATCHER MAIN
# =============================================================================

class LPWatcher:
    """Main LP Watcher process"""

    def __init__(self, lp_address: str, lp_private_key: str = "", network: str = None):
        self.network = network or ACTIVE_NETWORK
        self.evm = EVMMonitor(lp_address, lp_private_key, self.network)
        # Legacy alias
        self.polygon = self.evm
        self.pending_swaps: Dict[str, PendingSwap] = {}
        self.running = False

    def process_new_lock(self, lock: Dict):
        """Process a new USDC lock - store and try to create KPIV HTLC"""
        hashlock = lock["hashlock"]

        # Skip if we already processed this hashlock
        if hashlock in self.pending_swaps:
            log.debug(f"Already tracking hashlock {hashlock[:16]}...")
            return

        usdc_amount = lock["amount"]
        kpiv_amount = usdc_amount / LP_PRICE  # Convert at our rate

        log.info(f"New lock detected: {usdc_amount} USDC -> {kpiv_amount} KPIV, H={hashlock[:16]}...")

        # Create pending swap record FIRST (store regardless of registration)
        swap = PendingSwap(
            hashlock=hashlock,
            polygon_swap_id=lock["swap_id"],
            usdc_amount=usdc_amount,
            kpiv_amount=kpiv_amount,
            polygon_timelock=lock["timelock"]
        )
        self.pending_swaps[hashlock] = swap
        log.info(f"Swap stored in pending_swaps: H={hashlock[:16]}...")

        # Try to create HTLC immediately if taker is registered
        self.try_create_kpiv_htlc(swap)

    def try_create_kpiv_htlc(self, swap: PendingSwap):
        """Try to create KPIV HTLC if taker address is available"""
        if swap.kpiv_htlc_created:
            return  # Already created

        hashlock = swap.hashlock

        # Get taker's KPIV address from registration API
        taker_kpiv_address = get_taker_kpiv_address(hashlock)
        if not taker_kpiv_address:
            log.debug(f"Taker not yet registered for H={hashlock[:16]}... (will retry)")
            return

        log.info(f"Taker registered: {taker_kpiv_address} for H={hashlock[:16]}...")

        # Create KPIV HTLC on BATHRON
        hashlock_hex = hashlock[2:] if hashlock.startswith("0x") else hashlock

        result = create_kpiv_htlc(swap.kpiv_amount, hashlock_hex, taker_kpiv_address)

        if result:
            swap.kpiv_htlc_outpoint = f"{result['txid']}:0"
            swap.kpiv_htlc_created = True
            log.info(f"KPIV HTLC created: txid={result['txid']}, recipient={taker_kpiv_address}")

            # Update order book (reduce LOT remaining amount)
            notify_trade_executed(swap.kpiv_amount, hashlock, "htlc_created")
        else:
            log.error(f"Failed to create KPIV HTLC for hashlock {hashlock[:16]}...")

    def check_pending_htlcs(self):
        """Try to create HTLCs for pending swaps (waiting for registration)"""
        for hashlock, swap in self.pending_swaps.items():
            if not swap.kpiv_htlc_created:
                self.try_create_kpiv_htlc(swap)

    def check_for_reveals(self):
        """Check if any KPIV HTLCs have been claimed (preimage revealed)"""
        for hashlock, swap in list(self.pending_swaps.items()):
            if swap.usdc_claimed:
                continue  # Already completed

            if not swap.kpiv_htlc_created:
                continue  # HTLC not created yet

            # Check BATHRON for claim
            hashlock_hex = hashlock[2:] if hashlock.startswith("0x") else hashlock
            htlc = get_htlc_by_hashlock(hashlock_hex)

            if htlc and htlc.get("status") == "claimed":
                preimage = htlc.get("preimage")
                if preimage:
                    log.info(f"Preimage revealed on BATHRON: {preimage[:16]}...")
                    swap.preimage_revealed = preimage

                    # Claim USDC on Polygon
                    tx_hash = self.polygon.claim_usdc(swap.polygon_swap_id, preimage)
                    if tx_hash:
                        swap.usdc_claimed = True
                        log.info(f"USDC claimed successfully!")
                    else:
                        log.info(f"Manual USDC claim required for swap {swap.polygon_swap_id}")

    def check_for_expired_htlcs(self):
        """
        AUTO-REFUND: Check for expired KPIV HTLCs that weren't claimed.

        If taker didn't claim KPIV before expiry (didn't reveal preimage),
        LP can refund the KPIV back to their wallet.
        """
        for hashlock, swap in list(self.pending_swaps.items()):
            if swap.usdc_claimed:
                continue  # Already completed successfully

            if not swap.kpiv_htlc_created:
                continue  # HTLC not created yet

            if hasattr(swap, 'kpiv_refunded') and swap.kpiv_refunded:
                continue  # Already refunded

            # Check BATHRON HTLC status
            hashlock_hex = hashlock[2:] if hashlock.startswith("0x") else hashlock
            htlc = get_htlc_by_hashlock(hashlock_hex)

            if htlc and htlc.get("status") == "expired":
                log.info(f"[AutoRefund] KPIV HTLC expired for H={hashlock[:16]}...")
                log.info(f"[AutoRefund] Taker didn't claim. Refunding KPIV to LP wallet...")

                outpoint = htlc.get("outpoint", swap.kpiv_htlc_outpoint)
                if outpoint:
                    txid = refund_kpiv_htlc(outpoint)
                    if txid:
                        swap.kpiv_refunded = True
                        log.info(f"[AutoRefund] KPIV refunded successfully! txid={txid}")
                    else:
                        log.error(f"[AutoRefund] Failed to refund KPIV HTLC")
                else:
                    log.error(f"[AutoRefund] No outpoint found for KPIV HTLC")

    def run(self, poll_interval: int = 15):
        """Main run loop"""
        self.running = True
        network_name = NETWORKS[self.network]["name"]
        log.info(f"LP Watcher started on {network_name}")
        log.info(f"Monitoring for locks to {self.evm.lp_address}")
        log.info(f"Price: 1 KPIV = {LP_PRICE} USDC")

        while self.running:
            try:
                # 1. Scan for new USDC locks (Loop A)
                locks = self.polygon.scan_for_locks()
                for lock in locks:
                    self.process_new_lock(lock)

                # 2. Retry creating HTLCs for pending swaps (registration arrived?)
                self.check_pending_htlcs()

                # 3. Check for preimage reveals on BATHRON (Loop B)
                self.check_for_reveals()

                # 4. Check for expired KPIV HTLCs (auto-refund)
                self.check_for_expired_htlcs()

                # 5. Report status
                active = sum(1 for s in self.pending_swaps.values() if not s.usdc_claimed)
                completed = sum(1 for s in self.pending_swaps.values() if s.usdc_claimed)
                if active > 0 or completed > 0:
                    log.debug(f"Status: {active} active, {completed} completed")

            except Exception as e:
                log.error(f"Watcher error: {e}")

            time.sleep(poll_interval)

    def stop(self):
        """Stop the watcher"""
        self.running = False

# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    import argparse
    import os

    # Try to load .env file if present (chmod 600 recommended!)
    env_file = os.path.join(os.path.dirname(__file__), ".env")
    if os.path.exists(env_file):
        log.info(f"Loading config from .env file")
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))

    parser = argparse.ArgumentParser(description="LP Watcher for HTLC Atomic Swaps")
    parser.add_argument("--network", default=ACTIVE_NETWORK, choices=list(NETWORKS.keys()),
                       help=f"Network to monitor (default: {ACTIVE_NETWORK})")
    parser.add_argument("--lp-address", default=LP_EVM_ADDRESS, help="LP's EVM address")
    parser.add_argument("--private-key", default="", help="LP's private key for auto-claim")
    parser.add_argument("--poll", type=int, default=15, help="Poll interval in seconds")
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")
    parser.add_argument("--no-auto-claim", action="store_true", help="Disable auto-claim (log only)")
    args = parser.parse_args()

    # Show network info
    net_config = NETWORKS[args.network]
    log.info(f"Network: {net_config['name']} (chain_id={net_config['chain_id']})")

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    # Get private key: args > LP_EVM_PRIVKEY > LP_PRIVATE_KEY
    private_key = (
        args.private_key or
        os.environ.get("LP_EVM_PRIVKEY", "") or
        os.environ.get("LP_PRIVATE_KEY", "")
    )

    # AUTO_CLAIM toggle (can be disabled via --no-auto-claim or AUTO_CLAIM=0 in .env)
    auto_claim_env = os.environ.get("AUTO_CLAIM", "1")
    auto_claim = not args.no_auto_claim and auto_claim_env.lower() not in ("0", "false", "no")

    if not private_key:
        log.warning("=" * 60)
        log.warning("NO PRIVATE KEY - USDC auto-claim DISABLED")
        log.warning("Set LP_EVM_PRIVKEY in .env or via --private-key")
        log.warning("=" * 60)
    else:
        # Mask key for logging (security: never log full key)
        masked = private_key[:6] + "..." + private_key[-4:] if len(private_key) > 10 else "***"
        log.info("=" * 60)
        log.info(f"LP_EVM_PRIVKEY loaded: {masked}")
        log.info(f"AUTO_CLAIM: {'ENABLED' if auto_claim else 'DISABLED (log only)'}")
        log.info("=" * 60)

        # If auto-claim disabled, clear the key so claim_usdc() won't execute
        if not auto_claim:
            log.info("Running in SAFE MODE - preimages logged but not auto-claimed")
            private_key = ""

    watcher = LPWatcher(args.lp_address, private_key, args.network)

    try:
        watcher.run(args.poll)
    except KeyboardInterrupt:
        log.info("Shutting down...")
        watcher.stop()
