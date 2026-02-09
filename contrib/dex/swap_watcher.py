#!/usr/bin/env python3
# Copyright (c) 2025 The BATHRON 2.0 developers
# Distributed under the MIT software license

"""
Swap Watcher - State machine for HTLC atomic swaps

Monitors both BATHRON and Polygon chains, computes unified swap state.
Exposes HTTP API for explorer/UI consumption.

States (Taker perspective):
  BROWSE        - Viewing LOTs, not committed
  LOCKING       - EVM lock TX pending
  LOCKED        - EVM lock confirmed, waiting LP claim
  CLAIMABLE     - LP claimed (secret revealed), can claim PIV
  COMPLETED     - Taker claimed PIV, swap done
  REFUNDABLE    - Timeout reached, can refund EVM
  REFUNDED      - EVM refund completed

States (LP perspective):
  INVENTORY     - LOT created, waiting taker
  TAKEN         - Taker locked EVM funds
  CLAIMING      - LP claim TX pending
  CLAIMED       - LP claimed EVM funds (secret revealed)
  RELEASED      - Taker claimed PIV (or auto-released)
  EXPIRED       - LOT expired, can refund PIV
"""

import json
import time
import logging
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import urlopen, Request
from urllib.parse import urlparse, parse_qs
from typing import Optional, Dict, Any
from dataclasses import dataclass, asdict
from enum import Enum

# =============================================================================
# CONFIGURATION
# =============================================================================

BATHRON_CLI = "/home/ubuntu/BATHRON-Core/src/bathron-cli"  # On Seed node
BATHRON_NETWORK = "-testnet"

POLYGON_RPC = "https://polygon-rpc.com"
HTLC_CONTRACT = "0x3F1843Bc98C526542d6112448842718adc13fA5F"
USDC_CONTRACT = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"

# Event signatures
LOCKED_TOPIC = "0x14442dbf5e9aa943f3b7681bdf4e57c3256930c69ccc137263150f7e01bd51cf"
CLAIMED_TOPIC = "0x51f8c0a1f9d4e5b7c8a3b2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f1"

HTTP_PORT = 8080

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
log = logging.getLogger(__name__)

# =============================================================================
# STATE MACHINE
# =============================================================================

class TakerState(Enum):
    BROWSE = "browse"
    LOCKING = "locking"
    LOCKED = "locked"
    CLAIMABLE = "claimable"
    COMPLETED = "completed"
    REFUNDABLE = "refundable"
    REFUNDED = "refunded"

class LPState(Enum):
    INVENTORY = "inventory"
    TAKEN = "taken"
    CLAIMING = "claiming"
    CLAIMED = "claimed"
    RELEASED = "released"
    EXPIRED = "expired"

@dataclass
class SwapState:
    swap_id: str
    hashlock: str

    # BATHRON side
    piv_lot_outpoint: Optional[str] = None
    piv_amount: float = 0.0
    piv_lot_status: str = "unknown"
    piv_expiry_blocks: int = 0

    # Polygon side
    evm_locked: bool = False
    evm_amount: float = 0.0
    evm_claimed: bool = False
    evm_refunded: bool = False
    evm_timelock: int = 0
    evm_time_left: int = 0

    # Derived state
    taker_state: str = "browse"
    taker_action: str = "Select a LOT"
    lp_state: str = "inventory"
    lp_action: str = "Wait for taker"

    # Secret (only if revealed)
    secret_revealed: bool = False
    secret: Optional[str] = None

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

def get_lot_by_hashlock(hashlock: str) -> Optional[Dict]:
    """Find LOT by hashlock"""
    lots = bathron_rpc("lot_list")
    if not lots:
        return None
    for lot in lots:
        if lot.get("hashlock") == hashlock:
            return lot
    return None

def get_lot_secret(hashlock: str) -> Optional[str]:
    """Get saved secret for hashlock"""
    try:
        result = bathron_rpc("lot_get_secret", hashlock)
        if result and result.get("found"):
            return result.get("secret")
    except:
        pass  # RPC might not exist in older versions
    return None

# =============================================================================
# POLYGON RPC
# =============================================================================

def polygon_rpc(method: str, params: list) -> Any:
    """Call Polygon JSON-RPC"""
    payload = json.dumps({
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1
    }).encode()

    try:
        req = Request(POLYGON_RPC, data=payload, headers={"Content-Type": "application/json"})
        with urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
            if "error" in data:
                log.error(f"Polygon RPC error: {data['error']}")
                return None
            return data.get("result")
    except Exception as e:
        log.error(f"Polygon RPC exception: {e}")
        return None

def get_htlc_by_hashlock(hashlock: str, lp_address: str) -> Optional[Dict]:
    """Find HTLC on Polygon by hashlock"""
    # Get recent blocks
    current_block = polygon_rpc("eth_blockNumber", [])
    if not current_block:
        return None

    current_block = int(current_block, 16)
    from_block = hex(max(0, current_block - 500))  # Only 500 blocks (~15 min)

    # Query Locked events
    lp_topic = "0x" + lp_address[2:].lower().zfill(64)

    logs = polygon_rpc("eth_getLogs", [{
        "address": HTLC_CONTRACT,
        "fromBlock": from_block,
        "toBlock": "latest",
        "topics": [LOCKED_TOPIC, None, lp_topic]
    }])

    if not logs:
        return None

    # Find matching hashlock
    for log_entry in logs:
        data = log_entry.get("data", "")[2:]  # Remove 0x
        if len(data) >= 192:
            log_hashlock = "0x" + data[128:192]
            if log_hashlock.lower() == hashlock.lower():
                swap_id = log_entry["topics"][1]
                amount = int("0x" + data[64:128], 16)
                timelock = int("0x" + data[192:256], 16)
                return {
                    "swap_id": swap_id,
                    "hashlock": log_hashlock,
                    "amount": amount / 1e6,  # USDC decimals
                    "timelock": timelock,
                    "tx_hash": log_entry.get("transactionHash")
                }

    return None

def check_htlc_claimed(swap_id: str) -> Optional[str]:
    """Check if HTLC was claimed, return secret if so"""
    # Query Claimed events for this swap
    logs = polygon_rpc("eth_getLogs", [{
        "address": HTLC_CONTRACT,
        "fromBlock": "0x0",
        "toBlock": "latest",
        "topics": [CLAIMED_TOPIC, swap_id]
    }])

    if logs and len(logs) > 0:
        # Secret is in the data field
        data = logs[0].get("data", "")[2:]
        if len(data) >= 64:
            return "0x" + data[:64]

    return None

# =============================================================================
# STATE COMPUTATION
# =============================================================================

def compute_swap_state(hashlock: str, lp_address: str = None) -> SwapState:
    """Compute unified swap state from both chains"""
    state = SwapState(swap_id="", hashlock=hashlock)

    # 1. Check BATHRON LOT
    lot = get_lot_by_hashlock(hashlock)
    if lot:
        state.piv_lot_outpoint = lot.get("outpoint")
        state.piv_amount = lot.get("amount", 0)
        state.piv_lot_status = lot.get("status", "unknown")
        state.piv_expiry_blocks = lot.get("blocks_until_expiry", 0)

        if lot.get("status") == "claimed":
            state.secret_revealed = True
            state.secret = lot.get("preimage")

    # 2. Check saved secret
    saved_secret = get_lot_secret(hashlock)
    if saved_secret:
        state.secret = saved_secret

    # 3. Check Polygon HTLC (if LP address provided)
    if lp_address:
        htlc = get_htlc_by_hashlock(hashlock, lp_address)
        if htlc:
            state.swap_id = htlc.get("swap_id", "")
            state.evm_locked = True
            state.evm_amount = htlc.get("amount", 0)
            state.evm_timelock = htlc.get("timelock", 0)
            state.evm_time_left = max(0, state.evm_timelock - int(time.time()))

            # Check if claimed
            secret = check_htlc_claimed(state.swap_id)
            if secret:
                state.evm_claimed = True
                state.secret_revealed = True
                state.secret = secret

    # 4. Derive states
    state = derive_states(state)

    return state

def derive_states(state: SwapState) -> SwapState:
    """Derive taker/LP states and actions from raw data"""

    # LP State Machine
    if state.piv_lot_status == "expired":
        state.lp_state = "expired"
        state.lp_action = "Refund your KPIV"
    elif state.evm_claimed:
        state.lp_state = "claimed"
        state.lp_action = "Done! USDC claimed"
    elif state.evm_locked and state.secret:
        state.lp_state = "taken"
        state.lp_action = "Claim USDC now!"
    elif state.evm_locked:
        state.lp_state = "taken"
        state.lp_action = "Taker locked funds - claim when ready"
    elif state.piv_lot_outpoint:
        state.lp_state = "inventory"
        state.lp_action = "Waiting for taker"

    # Taker State Machine
    if state.piv_lot_status == "claimed":
        state.taker_state = "completed"
        state.taker_action = "Done! KPIV received"
    elif state.secret_revealed and state.evm_locked:
        state.taker_state = "claimable"
        state.taker_action = "Claim KPIV now!"
    elif state.evm_locked and state.evm_time_left <= 0:
        state.taker_state = "refundable"
        state.taker_action = "Timeout - refund your USDC"
    elif state.evm_locked:
        state.taker_state = "locked"
        state.taker_action = f"Waiting for LP ({state.evm_time_left // 3600}h left)"
    elif state.piv_lot_outpoint:
        state.taker_state = "browse"
        state.taker_action = "Lock USDC to start swap"

    return state

# =============================================================================
# HTTP SERVER
# =============================================================================

# =============================================================================
# TAKER REGISTRATION (hashlock → kpiv_address mapping)
# =============================================================================

# In-memory storage for taker registrations
# In production, this should be persisted to disk/database
taker_registry: Dict[str, str] = {}

# =============================================================================
# LOT STORAGE (Off-chain V3.0)
# LOTs are now managed off-chain. This is a simple in-memory store.
# =============================================================================

lot_storage: Dict[str, dict] = {}

def load_lots_from_file(filepath: str = "lots.json"):
    """Load LOTs from JSON file."""
    global lot_storage
    try:
        import os
        if os.path.exists(filepath):
            with open(filepath, 'r') as f:
                data = json.load(f)
                for lot in data.get("lots", []):
                    lot_id = lot.get("lot_id", "")
                    if lot_id:
                        lot_storage[lot_id] = lot
            log.info(f"Loaded {len(lot_storage)} LOTs from {filepath}")
    except Exception as e:
        log.error(f"Failed to load LOTs: {e}")

def save_lots_to_file(filepath: str = "lots.json"):
    """Save LOTs to JSON file."""
    try:
        import time
        data = {
            "version": "1.0",
            "updated_ts": int(time.time()),
            "lots": list(lot_storage.values())
        }
        with open(filepath, 'w') as f:
            json.dump(data, f, indent=2)
        log.info(f"Saved {len(lot_storage)} LOTs to {filepath}")
    except Exception as e:
        log.error(f"Failed to save LOTs: {e}")

def get_active_lots():
    """Get active (open) LOTs."""
    import time
    now = int(time.time())
    return [
        lot for lot in lot_storage.values()
        if lot.get("status") == "open" and lot.get("expiry_ts", 0) > now
    ]

class SwapHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        log.debug(f"{self.address_string()} - {format % args}")

    def send_json(self, data: Any, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode())

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        # Read request body
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else '{}'

        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self.send_json({"error": "Invalid JSON"}, 400)
            return

        # POST /api/register_taker - Register taker's KPIV address for a hashlock
        if path == "/api/register_taker":
            hashlock = data.get("hashlock")
            kpiv_address = data.get("kpiv_address")

            if not hashlock or not kpiv_address:
                self.send_json({"error": "Missing hashlock or kpiv_address"}, 400)
                return

            # Normalize hashlock (remove 0x prefix if present)
            hashlock = hashlock.lower()
            if hashlock.startswith("0x"):
                hashlock = hashlock[2:]

            # Validate hashlock length (32 bytes = 64 hex chars)
            if len(hashlock) != 64:
                self.send_json({"error": "Invalid hashlock length (must be 64 hex chars)"}, 400)
                return

            # Store registration
            taker_registry[hashlock] = kpiv_address
            log.info(f"Registered taker: hashlock={hashlock[:16]}... -> {kpiv_address}")

            self.send_json({
                "success": True,
                "hashlock": hashlock,
                "kpiv_address": kpiv_address
            })
            return

        # POST /api/claim_kpiv - Claim KPIV HTLC (for retail UI)
        if path == "/api/claim_kpiv":
            outpoint = data.get("outpoint")
            preimage = data.get("preimage")

            if not outpoint or not preimage:
                self.send_json({"error": "Missing outpoint or preimage"}, 400)
                return

            # Normalize preimage (remove 0x prefix if present)
            preimage_clean = preimage[2:] if preimage.startswith("0x") else preimage

            # Call htlc_claim_kpiv RPC
            result = bathron_rpc("htlc_claim_kpiv", outpoint, preimage_clean)

            if result and "txid" in result:
                log.info(f"KPIV claimed: txid={result['txid']}, preimage={preimage_clean[:16]}...")
                self.send_json({
                    "success": True,
                    "txid": result["txid"],
                    "claimed_amount": result.get("claimed_amount", "unknown"),
                    "preimage_revealed": preimage_clean
                })
            else:
                log.error(f"Claim failed: {result}")
                self.send_json({"error": "Claim failed", "details": str(result)}, 500)
            return

        # POST /api/lots/add - Add a LOT to the order book
        if path == "/api/lots/add":
            lot = data
            lot_id = lot.get("lot_id")

            if not lot_id:
                self.send_json({"error": "Missing lot_id"}, 400)
                return

            # Validate required fields
            required = ["pair", "side", "price", "size", "payment_addr", "expiry_ts"]
            missing = [f for f in required if f not in lot]
            if missing:
                self.send_json({"error": f"Missing fields: {missing}"}, 400)
                return

            # Set defaults
            lot.setdefault("status", "open")
            lot.setdefault("remaining", lot.get("size"))

            # Store
            lot_storage[lot_id] = lot
            save_lots_to_file()

            log.info(f"LOT added: {lot_id[:16]}... {lot.get('side')} {lot.get('size')} KPIV @ {lot.get('price')}")
            self.send_json({"success": True, "lot_id": lot_id, "lot": lot})
            return

        # POST /api/lots/remove - Remove a LOT from the order book
        if path == "/api/lots/remove":
            lot_id = data.get("lot_id")
            if not lot_id:
                self.send_json({"error": "Missing lot_id"}, 400)
                return

            if lot_id in lot_storage:
                del lot_storage[lot_id]
                save_lots_to_file()
                log.info(f"LOT removed: {lot_id[:16]}...")
                self.send_json({"success": True, "lot_id": lot_id})
            else:
                self.send_json({"error": "LOT not found"}, 404)
            return

        # 404 for unknown POST endpoints
        self.send_json({"error": "Not found"}, 404)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        # /api/health
        if path == "/api/health":
            self.send_json({"status": "ok", "time": int(time.time())})
            return

        # /api/lots - List all active LOTs (V3.0: off-chain storage)
        if path == "/api/lots":
            lots = get_active_lots()
            self.send_json({"lots": lots, "count": len(lots)})
            return

        # /api/lots/reload - Reload LOTs from file
        if path == "/api/lots/reload":
            load_lots_from_file()
            lots = get_active_lots()
            self.send_json({"reloaded": True, "lots": lots, "count": len(lots)})
            return

        # /api/swap/state?hashlock=xxx&lp=0x...
        if path == "/api/swap/state":
            hashlock = params.get("hashlock", [None])[0]
            lp_address = params.get("lp", [None])[0]

            if not hashlock:
                self.send_json({"error": "Missing hashlock parameter"}, 400)
                return

            state = compute_swap_state(hashlock, lp_address)
            self.send_json(asdict(state))
            return

        # /api/swap/secret?hashlock=xxx
        if path == "/api/swap/secret":
            hashlock = params.get("hashlock", [None])[0]
            if not hashlock:
                self.send_json({"error": "Missing hashlock parameter"}, 400)
                return

            secret = get_lot_secret(hashlock)
            if secret:
                self.send_json({"hashlock": hashlock, "secret": secret, "found": True})
            else:
                self.send_json({"hashlock": hashlock, "found": False}, 404)
            return

        # /api/taker_address?hashlock=xxx - Get registered taker's KPIV address
        if path == "/api/taker_address":
            hashlock = params.get("hashlock", [None])[0]
            if not hashlock:
                self.send_json({"error": "Missing hashlock parameter"}, 400)
                return

            # Normalize hashlock
            hashlock = hashlock.lower()
            if hashlock.startswith("0x"):
                hashlock = hashlock[2:]

            kpiv_address = taker_registry.get(hashlock)
            if kpiv_address:
                self.send_json({
                    "hashlock": hashlock,
                    "kpiv_address": kpiv_address,
                    "found": True
                })
            else:
                self.send_json({
                    "hashlock": hashlock,
                    "found": False,
                    "error": "Taker not registered for this hashlock"
                }, 404)
            return

        # 404
        self.send_json({"error": "Not found"}, 404)

def run_server():
    server = HTTPServer(("0.0.0.0", HTTP_PORT), SwapHandler)
    log.info(f"Swap Watcher running on http://0.0.0.0:{HTTP_PORT}")
    log.info("Endpoints:")
    log.info("  GET  /api/health")
    log.info("  GET  /api/lots")
    log.info("  GET  /api/swap/state?hashlock=xxx&lp=0x...")
    log.info("  GET  /api/swap/secret?hashlock=xxx")
    log.info("  GET  /api/taker_address?hashlock=xxx")
    log.info("  POST /api/register_taker {hashlock, kpiv_address}")
    server.serve_forever()

# =============================================================================
# MAIN
# =============================================================================

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Swap Watcher - HTLC State Machine")
    parser.add_argument("--port", type=int, default=HTTP_PORT, help="HTTP port")
    parser.add_argument("--debug", action="store_true", help="Debug logging")
    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    HTTP_PORT = args.port
    run_server()
