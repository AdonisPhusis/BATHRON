#!/usr/bin/env python3
"""
BATHRON DEX SDK Server - REST API for DEX Frontend

Endpoints:
  GET  /api/lots          - List all LOTs from bathrond
  GET  /api/orderbook     - Formatted orderbook (asks/bids)
  GET  /api/swap/<hash>   - Swap state (BATHRON + Polygon)
  POST /api/register      - Register taker address for swap
  GET  /api/status        - Server status
"""

import json
import subprocess
import time
import logging
from flask import Flask, jsonify, request
from flask_cors import CORS
from typing import Dict, List, Any, Optional
from dataclasses import dataclass, asdict
from web3 import Web3
from lot_manager import LOTManager
from dex_types import LotSide, LotStatus

# =============================================================================
# CONFIGURATION
# =============================================================================

BATHRON_CLI = "/home/ubuntu/BATHRON-Core/src/bathron-cli"
BATHRON_NETWORK = "-testnet"

POLYGON_RPC = "https://polygon-rpc.com"
HTLC_CONTRACT = "0x3F1843Bc98C526542d6112448842718adc13fA5F"
USDC_CONTRACT = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"

# LP Hot Wallet Address (receives USDC locks)
LP_POLYGON_ADDRESS = "0xA1b41Fb9D8d82bDcA0bA5D7115D4C04be64171B6"

HTTP_PORT = 8080

# =============================================================================
# TIMELOCK POLICY (2-HTLC Atomic Swap)
# =============================================================================
#
# Flow: Retail generates S → locks USDC → LP locks KPIV → Retail claims KPIV
#       (reveals S) → LP claims USDC
#
# Rule: The HTLC claimed FIRST must expire EARLIER.
#       Retail claims KPIV first, so T_KPIV < T_USDC
#
# Safety margin: T_USDC >= T_KPIV + BUFFER to absorb latency/reorgs
#
T_KPIV_SECONDS = 2 * 60 * 60      # 2 hours - KPIV HTLC (claimed first by retail)
T_USDC_SECONDS = 4 * 60 * 60      # 4 hours - USDC HTLC (claimed second by LP)
T_BUFFER_SECONDS = 30 * 60        # 30 min safety buffer

# BATHRON uses blocks (~1 block/min)
T_KPIV_BLOCKS = 120               # ~2 hours
T_USDC_BLOCKS = 240               # ~4 hours (for reference, Polygon uses timestamps)

# Runtime assertion - fail fast if misconfigured
assert T_USDC_SECONDS >= T_KPIV_SECONDS + T_BUFFER_SECONDS, \
    f"TIMELOCK ERROR: T_USDC ({T_USDC_SECONDS}s) must be >= T_KPIV ({T_KPIV_SECONDS}s) + BUFFER ({T_BUFFER_SECONDS}s)"

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)
log = logging.getLogger(__name__)

# =============================================================================
# SECURITY HELPERS
# =============================================================================

def mask_secret(secret: str, visible_prefix: int = 8, visible_suffix: int = 4) -> str:
    """Mask a secret for safe logging. NEVER log full secrets/preimages/keys."""
    if not secret or len(secret) <= visible_prefix + visible_suffix:
        return "***"
    return f"{secret[:visible_prefix]}...{secret[-visible_suffix:]}"

# =============================================================================
# FLASK APP
# =============================================================================

app = Flask(__name__)
CORS(app)  # Allow cross-origin for DEX frontend

# In-memory storage for pending swaps
pending_swaps: Dict[str, dict] = {}

# Known HTLC hashlock -> outpoint mapping (workaround for non-persistent tracking)
# This is updated when HTLCs are created via htlc_create_kpiv
# All fields needed for htlc_register after daemon restart:
#   outpoint, amount, status, claim_address, refund_address, expiry_height
known_htlcs: Dict[str, dict] = {
    # Testnet HTLCs (with full info for re-registration after restart)
    "591e7d7d116b176709f0ea828903d6bbbc2d8e65bf528d11890a35b46e9bea66": {
        "outpoint": "a4258e7443af672f913aa26a1c0d5f5a153633ad1fc664750f12d7d7e9992777:0",
        "amount": 1.0,
        "status": "locked",
        "claim_address": "yH4tZ75tFHFe6EJ5fYH3ntePMpLq1MCrv8",  # Taker's address
        "refund_address": "y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka",  # LP's address
        "expiry_height": 2000  # Approximate expiry
    },
    "ae6d5bcbd1cd08330ec8dd6116aaf4a5ea662da1cf0a19235f0221b5f3225a7d": {
        "outpoint": "1e104f70f236cdfd115bc0be001f51bdeeed81d566158402f810ea086ccd7efa:0",
        "amount": 1.0,
        "status": "locked",
        "claim_address": "yH4tZ75tFHFe6EJ5fYH3ntePMpLq1MCrv8",  # Taker's address
        "refund_address": "y7XRqXgz1d8ELErDxtwQPnvfbe2ZcUecka",  # LP's address
        "expiry_height": 2000  # Approximate expiry
    }
}

# LOT Manager (off-chain orderbook)
lot_manager = LOTManager(storage_path="/home/ubuntu/sdk/lots.json")

# =============================================================================
# BATHRON RPC INTERFACE
# =============================================================================

def bathron_rpc(method: str, *args) -> Any:
    """Execute bathron-cli RPC call"""
    cmd = [BATHRON_CLI, BATHRON_NETWORK, method] + [str(a) for a in args]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            log.error(f"RPC error: {result.stderr}")
            return None
        return json.loads(result.stdout) if result.stdout.strip() else None
    except subprocess.TimeoutExpired:
        log.error(f"RPC timeout: {method}")
        return None
    except json.JSONDecodeError as e:
        log.error(f"JSON decode error: {e}")
        return result.stdout if result.stdout else None
    except Exception as e:
        log.error(f"RPC exception: {e}")
        return None

# =============================================================================
# POLYGON INTERFACE
# =============================================================================

w3 = Web3(Web3.HTTPProvider(POLYGON_RPC))

HTLC_ABI = [
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

htlc_contract = w3.eth.contract(address=HTLC_CONTRACT, abi=HTLC_ABI)

def get_htlc_swap(swap_id: str) -> Optional[dict]:
    """Get HTLC swap state from Polygon"""
    try:
        if not swap_id.startswith('0x'):
            swap_id = '0x' + swap_id
        swap_bytes = bytes.fromhex(swap_id[2:])
        result = htlc_contract.functions.swaps(swap_bytes).call()
        return {
            'sender': result[0],
            'recipient': result[1],
            'token': result[2],
            'amount': result[3] / 1e6,  # USDC has 6 decimals
            'hashlock': '0x' + result[4].hex(),
            'timelock': result[5],
            'withdrawn': result[6],
            'refunded': result[7]
        }
    except Exception as e:
        log.error(f"HTLC query error: {e}")
        return None

# =============================================================================
# ORDERBOOK FORMATTING
# =============================================================================

def format_orderbook(lots: List[dict], pair: str = "KPIV/USDC") -> dict:
    """Format LOT list into orderbook structure"""
    asks = []  # LP sells KPIV (retail buys)
    bids = []  # LP buys KPIV (retail sells)

    current_height = bathron_rpc('getblockcount') or 0

    for lot in lots:
        if lot.get('status') != 'open':
            continue
        if lot.get('pair') != pair:
            continue

        price = float(lot.get('price', 0))
        size = float(lot.get('remaining', lot.get('size_kpiv', 0)))
        expiry = lot.get('expiry_height', 0)

        if expiry <= current_height:
            continue

        entry = {
            'price': price,
            'size': size,
            'lot_id': lot.get('lot_id', ''),
            'lp_kpiv_addr': lot.get('lp_kpiv_addr', ''),
            'payment_chain': lot.get('payment_chain', 'polygon'),
            'payment_addr': lot.get('payment_addr', ''),
            'blocks_until_expiry': expiry - current_height
        }

        side = lot.get('side', '').lower()
        if side == 'ask':
            asks.append(entry)
        elif side == 'bid':
            bids.append(entry)

    # Sort: asks ascending by price, bids descending
    asks.sort(key=lambda x: x['price'])
    bids.sort(key=lambda x: x['price'], reverse=True)

    # Calculate totals (cumulative)
    ask_total = 0
    for ask in asks:
        ask_total += ask['size']
        ask['total'] = ask_total

    bid_total = 0
    for bid in bids:
        bid_total += bid['size']
        bid['total'] = bid_total

    # Calculate spread
    best_ask = asks[0]['price'] if asks else None
    best_bid = bids[0]['price'] if bids else None
    spread = (best_ask - best_bid) if (best_ask and best_bid) else None
    spread_pct = ((spread / best_bid) * 100) if (spread and best_bid) else None

    return {
        'pair': pair,
        'timestamp': int(time.time()),
        'current_height': current_height,
        'asks': asks,
        'bids': bids,
        'best_ask': best_ask,
        'best_bid': best_bid,
        'spread': spread,
        'spread_pct': round(spread_pct, 2) if spread_pct else None,
        'lp_polygon_address': LP_POLYGON_ADDRESS
    }

# =============================================================================
# HEALTH ENDPOINTS (for monitoring and debugging)
# =============================================================================

@app.route('/health')
def health():
    """Simple health check - returns ok if server is running"""
    return jsonify({'ok': True, 'timestamp': int(time.time())})

@app.route('/health/bathron')
def health_bathron():
    """Check BATHRON daemon connectivity"""
    try:
        height = bathron_rpc('getblockcount')
        if height is not None:
            return jsonify({
                'ok': True,
                'height': height,
                'network': 'testnet'
            })
        else:
            return jsonify({'ok': False, 'error': 'RPC returned null'}), 503
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 503

@app.route('/health/polygon')
def health_polygon():
    """Check Polygon RPC connectivity"""
    try:
        if w3.is_connected():
            block = w3.eth.block_number
            return jsonify({
                'ok': True,
                'block': block,
                'rpc': POLYGON_RPC
            })
        else:
            return jsonify({'ok': False, 'error': 'Not connected to Polygon'}), 503
    except Exception as e:
        return jsonify({'ok': False, 'error': str(e)}), 503

@app.route('/health/all')
def health_all():
    """Combined health check for all dependencies"""
    bathron_ok = False
    bathron_height = None
    polygon_ok = False
    polygon_block = None

    try:
        bathron_height = bathron_rpc('getblockcount')
        bathron_ok = bathron_height is not None
    except:
        pass

    try:
        polygon_ok = w3.is_connected()
        if polygon_ok:
            polygon_block = w3.eth.block_number
    except:
        pass

    all_ok = bathron_ok and polygon_ok
    status_code = 200 if all_ok else 503

    return jsonify({
        'ok': all_ok,
        'bathron': {'ok': bathron_ok, 'height': bathron_height},
        'polygon': {'ok': polygon_ok, 'block': polygon_block},
        'timelocks': {
            'T_KPIV_blocks': T_KPIV_BLOCKS,
            'T_USDC_seconds': T_USDC_SECONDS,
            'buffer_seconds': T_BUFFER_SECONDS
        }
    }), status_code

# =============================================================================
# API ENDPOINTS
# =============================================================================

@app.route('/api/status')
def api_status():
    """Server status and connectivity check"""
    bathron_height = bathron_rpc('getblockcount')
    polygon_block = w3.eth.block_number if w3.is_connected() else None

    return jsonify({
        'status': 'ok',
        'timestamp': int(time.time()),
        'bathron': {
            'connected': bathron_height is not None,
            'height': bathron_height
        },
        'polygon': {
            'connected': w3.is_connected(),
            'block': polygon_block
        },
        'htlc_contract': HTLC_CONTRACT,
        'lp_address': LP_POLYGON_ADDRESS,
        'timelocks': {
            'T_KPIV_blocks': T_KPIV_BLOCKS,
            'T_USDC_seconds': T_USDC_SECONDS
        }
    })

@app.route('/api/lots')
def api_lots():
    """Get all LOTs (off-chain orderbook)"""
    lots = lot_manager.list_lots(include_expired=False)
    return jsonify({
        'lots': [lot.to_dict() for lot in lots],
        'count': len(lots)
    })

@app.route('/api/lots/create', methods=['POST'])
def api_create_lot():
    """
    Create a new LOT (off-chain offer).

    Request:
    {
        "side": "ASK",              # ASK (sell KPIV) or BID (buy KPIV)
        "price": 0.05,              # USDC per KPIV
        "size": 100,                # KPIV amount
        "payment_chain": "polygon", # External chain
        "payment_addr": "0x...",    # LP's address on external chain
        "lp_kpiv_addr": "y7XRq...", # LP's BATHRON address
        "expiry_hours": 24          # Optional, default 24h
    }
    """
    data = request.json
    if not data:
        return jsonify({'error': 'No data provided'}), 400

    try:
        side_str = data.get('side', 'ASK').upper()
        side = LotSide.ASK if side_str == 'ASK' else LotSide.BID

        lot = lot_manager.create_lot(
            pair=data.get('pair', 'KPIV/USDC'),
            side=side,
            price=float(data.get('price', 0)),
            size=float(data.get('size', 0)),
            payment_chain=data.get('payment_chain', 'polygon'),
            payment_addr=data.get('payment_addr', ''),
            lp_kpiv_addr=data.get('lp_kpiv_addr', ''),
            expiry_hours=int(data.get('expiry_hours', 24)),
            sign=False  # No RPC for signing in server mode
        )

        log.info(f"LOT created: {lot.lot_id[:16]}... {side_str} {lot.size} KPIV @ {lot.price}")

        return jsonify({
            'success': True,
            'lot': lot.to_dict()
        })

    except ValueError as e:
        return jsonify({'error': str(e)}), 400
    except Exception as e:
        log.error(f"LOT creation error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/lots/cancel', methods=['POST'])
def api_cancel_lot():
    """Cancel a LOT by ID"""
    data = request.json
    lot_id = data.get('lot_id', '')

    if not lot_id:
        return jsonify({'error': 'Missing lot_id'}), 400

    if lot_manager.cancel_lot(lot_id):
        log.info(f"LOT cancelled: {lot_id[:16]}...")
        return jsonify({'success': True})
    else:
        return jsonify({'error': 'LOT not found'}), 404

@app.route('/api/orderbook')
def api_orderbook():
    """Get formatted orderbook with cumulative totals"""
    pair = request.args.get('pair', 'KPIV/USDC')
    orderbook = lot_manager.get_orderbook(pair)

    # Add cumulative totals for depth visualization
    asks = orderbook.get('asks', [])
    bids = orderbook.get('bids', [])

    # Calculate cumulative totals for asks (ascending price)
    ask_total = 0
    for ask in asks:
        size = ask.get('remaining', ask.get('size', 0))
        ask['size'] = size  # Use remaining as display size
        ask_total += size
        ask['total'] = ask_total

    # Calculate cumulative totals for bids (descending price)
    bid_total = 0
    for bid in bids:
        size = bid.get('remaining', bid.get('size', 0))
        bid['size'] = size
        bid_total += size
        bid['total'] = bid_total

    # Calculate spread percentage
    best_ask = orderbook.get('best_ask')
    best_bid = orderbook.get('best_bid')
    if best_ask and best_bid:
        orderbook['spread_pct'] = round(((best_ask - best_bid) / best_bid) * 100, 2)
    else:
        orderbook['spread_pct'] = None

    orderbook['lp_polygon_address'] = LP_POLYGON_ADDRESS
    orderbook['timestamp'] = int(time.time())
    return jsonify(orderbook)

@app.route('/api/lot/<lot_id>')
def api_lot_details(lot_id):
    """Get specific LOT details"""
    lot = lot_manager.get_lot(lot_id)
    if lot is None:
        return jsonify({'error': 'LOT not found'}), 404
    return jsonify(lot.to_dict())

@app.route('/api/swap/<hashlock>')
def api_swap_status(hashlock):
    """Get unified swap state (BATHRON + Polygon)"""
    # Check if we have this swap registered
    swap_info = pending_swaps.get(hashlock, {})

    # Query Polygon HTLC using swap_id if available, otherwise hashlock
    # The HTLC contract indexes by swap_id, not hashlock!
    polygon_key = swap_info.get('swap_id', hashlock)
    htlc_state = get_htlc_swap(polygon_key)

    # Determine state
    state = 'UNKNOWN'
    next_action = None
    next_action_by = None

    if htlc_state:
        if htlc_state['refunded']:
            state = 'REFUNDED'
        elif htlc_state['withdrawn']:
            state = 'COMPLETED'
        elif htlc_state['timelock'] < int(time.time()):
            state = 'REFUNDABLE'
            next_action = 'REFUND'
            next_action_by = 'TAKER'
        else:
            state = 'LOCKED'
            next_action = 'WAIT_KPIV'
            next_action_by = 'LP'
            # If KPIV was sent, taker can reveal
            if swap_info.get('kpiv_sent'):
                state = 'CLAIMABLE'
                next_action = 'REVEAL_SECRET'
                next_action_by = 'TAKER'

    return jsonify({
        'hashlock': hashlock,
        'state': state,
        'polygon': htlc_state,
        'bathron': {
            'taker_addr': swap_info.get('taker_kpiv_addr'),
            'lot_id': swap_info.get('lot_id'),
            'kpiv_sent': swap_info.get('kpiv_sent', False),
            'kpiv_tx': swap_info.get('kpiv_tx')
        },
        'next_action': next_action,
        'next_action_by': next_action_by
    })

@app.route('/api/register', methods=['POST'])
def api_register_swap():
    """Register a new swap (taker address for LP)"""
    data = request.json
    if not data:
        return jsonify({'error': 'No data provided'}), 400

    hashlock = data.get('hashlock')
    taker_kpiv_addr = data.get('taker_kpiv_addr')
    lot_id = data.get('lot_id')

    if not all([hashlock, taker_kpiv_addr, lot_id]):
        return jsonify({'error': 'Missing required fields'}), 400

    # Validate BATHRON address format
    if not (taker_kpiv_addr.startswith('x') or taker_kpiv_addr.startswith('y')):
        return jsonify({'error': 'Invalid BATHRON address format'}), 400

    # Store swap info
    pending_swaps[hashlock] = {
        'hashlock': hashlock,
        'taker_kpiv_addr': taker_kpiv_addr,
        'lot_id': lot_id,
        'registered_at': int(time.time()),
        'kpiv_sent': False
    }

    log.info(f"Registered swap: {hashlock[:16]}... -> {taker_kpiv_addr}")

    return jsonify({
        'success': True,
        'swap_id': hashlock[:16],
        'message': 'Swap registered. LP will send KPIV after detecting your USDC lock.'
    })

@app.route('/api/pending_swaps')
def api_pending_swaps():
    """List pending swaps (for LP watcher)"""
    return jsonify({
        'swaps': list(pending_swaps.values()),
        'count': len(pending_swaps)
    })

@app.route('/api/taker_address')
def api_taker_address():
    """
    Get taker's KPIV address by hashlock (for LP watcher).

    Query: /api/taker_address?hashlock=abc123...

    Returns: {"found": true, "kpiv_address": "y7XRq..."} or {"found": false}
    """
    hashlock = request.args.get('hashlock', '')

    if not hashlock:
        return jsonify({'error': 'Missing hashlock parameter', 'found': False}), 400

    # Normalize hashlock (check both with and without 0x prefix)
    hashlock_clean = hashlock.lower().replace('0x', '')
    hashlock_with_prefix = '0x' + hashlock_clean

    # Look up in pending swaps (try both formats)
    swap = pending_swaps.get(hashlock_clean) or pending_swaps.get(hashlock_with_prefix)

    if swap and swap.get('taker_kpiv_addr'):
        return jsonify({
            'found': True,
            'kpiv_address': swap['taker_kpiv_addr'],
            'lot_id': swap.get('lot_id'),
            'registered_at': swap.get('registered_at')
        })

    return jsonify({'found': False})

@app.route('/api/update_swap', methods=['POST'])
def api_update_swap():
    """
    Update swap state with swap_id after USDC lock (called by DEX frontend or LP watcher).

    Request:
    {
        "hashlock": "abc123...",    # Original hashlock
        "swap_id": "0xdef456...",   # Polygon HTLC swap_id (returned after lock)
        "tx_hash": "0x..."          # Optional: lock transaction hash
    }

    This is critical because Polygon HTLC contract indexes by swap_id, not hashlock.
    """
    data = request.json
    hashlock = data.get('hashlock')

    if not hashlock:
        return jsonify({'error': 'Missing hashlock'}), 400

    if hashlock in pending_swaps:
        # Update with new data (swap_id, tx_hash, etc.)
        pending_swaps[hashlock].update(data)
        log.info(f"Updated swap {hashlock[:16]}... with swap_id: {data.get('swap_id', 'N/A')[:16]}...")
        return jsonify({'success': True})

    return jsonify({'error': 'Swap not found'}), 404

# =============================================================================
# HTLC KPIV ENDPOINTS (2-HTLC Model)
# =============================================================================

@app.route('/api/htlc/create_kpiv', methods=['POST'])
def api_create_kpiv_htlc():
    """
    Create KPIV HTLC on BATHRON chain (called by LP watcher)

    Request:
    {
        "hashlock": "abc123...",       # Same H as Polygon HTLC
        "amount": 100.0,                # KPIV amount
        "recipient_addr": "y7XRq...",   # Taker's BATHRON address
        "expiry_blocks": 120            # Optional, default 120 (~2h)
    }

    This is Step 5 in the 2-HTLC flow:
    1. Retail generates S, H
    2. Retail registers H + addr
    3. Retail locks USDC with H
    4. LP detects USDC lock
    5. LP creates KPIV HTLC with H  <-- THIS ENDPOINT
    6. Retail claims KPIV (reveals S)
    7. LP extracts S, claims USDC
    """
    data = request.json
    if not data:
        return jsonify({'error': 'No data provided'}), 400

    hashlock = data.get('hashlock')
    amount = data.get('amount')
    recipient_addr = data.get('recipient_addr')
    expiry_blocks = data.get('expiry_blocks', 120)  # ~2 hours at 1 block/min

    if not all([hashlock, amount, recipient_addr]):
        return jsonify({'error': 'Missing required fields: hashlock, amount, recipient_addr'}), 400

    # Validate BATHRON address format
    if not (recipient_addr.startswith('x') or recipient_addr.startswith('y')):
        return jsonify({'error': 'Invalid BATHRON address format'}), 400

    try:
        # Call bathrond to create HTLC
        result = bathron_rpc('htlc_create_kpiv', hashlock, str(amount), recipient_addr, str(expiry_blocks))

        if result is None:
            return jsonify({'error': 'RPC call failed'}), 500

        # Update swap state
        if hashlock in pending_swaps:
            pending_swaps[hashlock].update({
                'kpiv_htlc_created': True,
                'kpiv_htlc_outpoint': result.get('outpoint'),
                'kpiv_htlc_txid': result.get('txid'),
                'kpiv_amount': amount
            })

        # Add to known_htlcs for persistence across daemon restarts
        # Store ALL info needed for htlc_register in case of restart
        hashlock_clean = hashlock.lower().replace('0x', '')
        current_height = bathron_rpc('getblockcount') or 0
        known_htlcs[hashlock_clean] = {
            'outpoint': result.get('outpoint'),
            'amount': float(amount),
            'status': 'locked',
            'claim_address': recipient_addr,
            'refund_address': result.get('refund_path', {}).get('signing_address', ''),
            'expiry_height': result.get('expiry_height', current_height + expiry_blocks)
        }

        log.info(f"Created KPIV HTLC: {hashlock[:16]}... -> {recipient_addr}, {amount} KPIV")

        return jsonify({
            'success': True,
            'txid': result.get('txid'),
            'outpoint': result.get('outpoint'),
            'hashlock': hashlock,
            'amount': amount,
            'expiry_height': result.get('expiry_height')
        })

    except Exception as e:
        log.error(f"HTLC creation error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/htlc/list')
def api_list_htlcs():
    """List all HTLCs from bathrond"""
    filter_status = request.args.get('status', '')
    htlcs = bathron_rpc('htlc_list', filter_status) if filter_status else bathron_rpc('htlc_list')
    if htlcs is None:
        return jsonify({'error': 'Failed to fetch HTLCs', 'htlcs': []}), 500
    return jsonify({'htlcs': htlcs, 'count': len(htlcs)})

@app.route('/api/htlc/<identifier>')
def api_get_htlc(identifier):
    """Get HTLC by outpoint or hashlock"""
    htlc = bathron_rpc('htlc_get', identifier)
    if htlc is None:
        return jsonify({'error': 'HTLC not found'}), 404
    return jsonify(htlc)

@app.route('/api/htlc/extract_preimage/<txid>')
def api_extract_preimage(txid):
    """
    Extract preimage S from a claim transaction.

    This is Step 7 in the 2-HTLC flow - LP extracts S from Retail's claim TX.

    SECURITY NOTE: Returns FULL preimage (needed by LP to claim USDC).
    The preimage is already public on-chain once retail claims KPIV.
    """
    result = bathron_rpc('htlc_extract_preimage', txid)
    if result is None:
        return jsonify({'error': 'Failed to extract preimage'}), 404

    preimage = result.get('preimage', '')
    # Log with masking (preimage is public on-chain but avoid log exposure)
    log.info(f"Preimage extracted from {txid[:16]}...: {mask_secret(preimage)}")

    return jsonify({
        'preimage': preimage,
        'hashlock': result.get('hashlock'),
        'verified': result.get('verified', False)
    })

@app.route('/api/htlc/verify_preimage', methods=['POST'])
def api_verify_preimage():
    """Verify that SHA256(preimage) == hashlock"""
    data = request.json
    preimage = data.get('preimage')
    hashlock = data.get('hashlock')

    if not all([preimage, hashlock]):
        return jsonify({'error': 'Missing preimage or hashlock'}), 400

    result = bathron_rpc('htlc_verify_preimage', preimage, hashlock)
    return jsonify({'valid': result if result is not None else False})

@app.route('/api/htlc/claim_kpiv', methods=['POST'])
def api_claim_kpiv_htlc():
    """
    Claim KPIV HTLC on BATHRON chain (called by Taker/Retail via DEX UI)

    Request:
    {
        "hashlock": "abc123...",       # HTLC hashlock (to find the HTLC)
        "preimage": "secret..."        # Secret S where SHA256(S) == hashlock
    }

    OR (if outpoint is known):
    {
        "outpoint": "txid:vout",       # Direct HTLC outpoint
        "preimage": "secret..."
    }

    This is Step 6 in the 2-HTLC flow:
    1. Retail generates S, H
    2. Retail registers H + addr
    3. Retail locks USDC with H
    4. LP detects USDC lock
    5. LP creates KPIV HTLC with H
    6. Retail claims KPIV (reveals S)  <-- THIS ENDPOINT
    7. LP extracts S, claims USDC

    SECURITY NOTE: This reveals the preimage on-chain, allowing LP to claim USDC.
    Only call this after verifying the KPIV HTLC exists and has correct amount.
    """
    data = request.json
    if not data:
        return jsonify({'error': 'No data provided'}), 400

    preimage = data.get('preimage')
    outpoint = data.get('outpoint')
    hashlock = data.get('hashlock')

    if not preimage:
        return jsonify({'error': 'Missing required field: preimage'}), 400

    htlc_info = None  # Will hold known_htlcs data if we need to register

    # If no outpoint provided, find HTLC by hashlock
    if not outpoint and hashlock:
        hashlock_clean = hashlock.lower().replace('0x', '')

        # First try htlc_list from daemon (if HTLC is already tracked)
        htlcs = bathron_rpc('htlc_list', 'locked')
        if htlcs:
            for htlc in htlcs:
                if htlc.get('hashlock', '').lower() == hashlock_clean:
                    outpoint = htlc.get('outpoint')
                    log.info(f"Found HTLC in daemon tracking: {hashlock_clean[:16]}...")
                    break

        # Fallback: check known_htlcs (workaround for non-persistent tracking)
        if not outpoint and hashlock_clean in known_htlcs:
            htlc_info = known_htlcs[hashlock_clean]
            outpoint = htlc_info['outpoint']
            log.info(f"Using known_htlcs fallback for {hashlock_clean[:16]}...")

        if not outpoint:
            return jsonify({'error': f'No locked HTLC found for hashlock {hashlock[:16]}...'}), 404

    if not outpoint:
        return jsonify({'error': 'Missing outpoint or hashlock to identify HTLC'}), 400

    try:
        # If we found the HTLC via known_htlcs (not daemon tracking), register it first
        if htlc_info and htlc_info.get('claim_address') and htlc_info.get('refund_address'):
            log.info(f"Registering HTLC with daemon before claim: {outpoint}")
            hashlock_clean = hashlock.lower().replace('0x', '')

            # Call htlc_register to add HTLC to daemon's tracking
            reg_result = bathron_rpc(
                'htlc_register',
                outpoint,
                hashlock_clean,
                htlc_info['claim_address'],
                htlc_info['refund_address'],
                str(htlc_info.get('expiry_height', 5000))  # Default expiry if not known
            )

            if reg_result is None:
                log.warning(f"htlc_register returned None (may already be registered or spent)")
            elif isinstance(reg_result, dict) and reg_result.get('registered'):
                log.info(f"Successfully registered HTLC: {outpoint}")
            else:
                log.warning(f"htlc_register result: {reg_result}")

        # Call bathrond to claim HTLC
        result = bathron_rpc('htlc_claim_kpiv', outpoint, preimage)

        if result is None:
            return jsonify({'error': 'RPC call failed - check daemon logs'}), 500

        # Check for RPC error
        if isinstance(result, dict) and 'error' in result:
            return jsonify({'error': result['error']}), 400

        # Update swap state
        if hashlock and hashlock in pending_swaps:
            pending_swaps[hashlock].update({
                'kpiv_claimed': True,
                'kpiv_claim_txid': result.get('txid') if isinstance(result, dict) else result
            })

        # Update known_htlcs status
        if hashlock:
            hashlock_clean = hashlock.lower().replace('0x', '')
            if hashlock_clean in known_htlcs:
                known_htlcs[hashlock_clean]['status'] = 'claimed'

        # Log with masked preimage (security)
        log.info(f"Claimed KPIV HTLC: outpoint={outpoint}, preimage={mask_secret(preimage)}")

        return jsonify({
            'success': True,
            'txid': result.get('txid') if isinstance(result, dict) else result,
            'outpoint': outpoint,
            'hashlock': hashlock
        })

    except Exception as e:
        log.error(f"HTLC claim error: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/htlc/find_by_hashlock/<hashlock>')
def api_find_htlc_by_hashlock(hashlock):
    """
    Find KPIV HTLC by hashlock.

    Returns the HTLC details if found, or 404 if not.
    Used by DEX UI to check if LP has created the KPIV HTLC.
    """
    hashlock_clean = hashlock.lower().replace('0x', '')

    # First try htlc_list from daemon
    htlcs = bathron_rpc('htlc_list')
    if htlcs:
        for htlc in htlcs:
            htlc_hashlock = htlc.get('hashlock', '').lower().replace('0x', '')
            if htlc_hashlock == hashlock_clean:
                return jsonify({
                    'found': True,
                    'htlc': htlc
                })

    # Fallback: check known_htlcs (workaround for non-persistent tracking)
    if hashlock_clean in known_htlcs:
        htlc_data = known_htlcs[hashlock_clean]
        return jsonify({
            'found': True,
            'htlc': {
                'outpoint': htlc_data['outpoint'],
                'hashlock': hashlock_clean,
                'amount': htlc_data['amount'],
                'status': htlc_data.get('status', 'locked')
            }
        })

    return jsonify({'found': False})

# =============================================================================
# MAIN
# =============================================================================

if __name__ == '__main__':
    log.info(f"Starting SDK Server on port {HTTP_PORT}")
    log.info(f"BATHRON CLI: {BATHRON_CLI}")
    log.info(f"Polygon RPC: {POLYGON_RPC}")
    log.info(f"HTLC Contract: {HTLC_CONTRACT}")
    log.info(f"LP Address: {LP_POLYGON_ADDRESS}")

    app.run(host='0.0.0.0', port=HTTP_PORT, debug=False)
