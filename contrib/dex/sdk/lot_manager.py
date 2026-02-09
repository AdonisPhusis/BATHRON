"""
BATHRON 2.0 DEX SDK - LOT Manager

Off-chain LOT (Limit Order Ticket) management.
LOTs are signed messages published by LPs to announce trading intent.
"""

import json
import time
import os
from typing import List, Optional, Dict, Callable
from dataclasses import asdict

try:
    from .dex_types import LOT, LotSide, LotStatus
    from .rpc_client import RPCClient
except ImportError:
    from dex_types import LOT, LotSide, LotStatus
    from rpc_client import RPCClient


class LOTManager:
    """
    Off-chain LOT manager.

    LOTs are stored locally and can be:
      - Published to HTTP endpoints (pull model)
      - Pushed via WebSocket (push model)
      - Shared via P2P gossip (future)

    Usage:
        lots = LOTManager(rpc, storage_path="/path/to/lots.json")

        # Create a LOT
        lot = lots.create_lot(
            pair="KPIV/USDC",
            side=LotSide.ASK,
            price=1.05,
            size=1000,
            payment_chain="polygon",
            payment_addr="0x...",
            expiry_hours=24
        )

        # List LOTs
        all_lots = lots.list_lots()
        open_asks = lots.list_lots(side=LotSide.ASK, status=LotStatus.OPEN)

        # Cancel a LOT
        lots.cancel_lot(lot.lot_id)
    """

    # Supported trading pairs
    SUPPORTED_PAIRS = [
        "KPIV/USDC",
        "KPIV/USDT",
        "KPIV/BTC",
        "KPIV/ETH",
        "KPIV/POL"
    ]

    # Supported payment chains
    SUPPORTED_CHAINS = [
        "polygon",
        "ethereum",
        "bitcoin",
        "bsc"
    ]

    def __init__(self, rpc: Optional[RPCClient] = None,
                 storage_path: str = "lots.json"):
        """
        Initialize LOT manager.

        Args:
            rpc: RPC client for signing (optional)
            storage_path: Path to store LOTs locally
        """
        self.rpc = rpc
        self.storage_path = storage_path
        self.lots: Dict[str, LOT] = {}
        self._load_lots()

    def _load_lots(self):
        """Load LOTs from storage."""
        if os.path.exists(self.storage_path):
            try:
                with open(self.storage_path, "r") as f:
                    data = json.load(f)
                    for lot_data in data.get("lots", []):
                        lot = LOT.from_dict(lot_data)
                        self.lots[lot.lot_id] = lot
            except Exception as e:
                print(f"Warning: Failed to load LOTs: {e}")

    def _save_lots(self):
        """Save LOTs to storage."""
        try:
            data = {
                "version": "1.0",
                "updated_ts": int(time.time()),
                "lots": [lot.to_dict() for lot in self.lots.values()]
            }
            with open(self.storage_path, "w") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"Warning: Failed to save LOTs: {e}")

    def create_lot(self,
                   pair: str,
                   side: LotSide,
                   price: float,
                   size: float,
                   payment_chain: str,
                   payment_addr: str,
                   lp_kpiv_addr: str = "",
                   expiry_hours: int = 24,
                   sign: bool = True) -> LOT:
        """
        Create a new LOT.

        Args:
            pair: Trading pair (e.g., "KPIV/USDC")
            side: ASK (sell KPIV) or BID (buy KPIV)
            price: Quote asset per KPIV
            size: Amount in KPIV
            payment_chain: External chain (e.g., "polygon")
            payment_addr: LP's address on external chain
            lp_kpiv_addr: LP's KPIV address (auto-generated if empty)
            expiry_hours: Hours until expiry (default 24)
            sign: Whether to sign the LOT (requires RPC)

        Returns:
            Created LOT
        """
        # Validate pair
        if pair not in self.SUPPORTED_PAIRS:
            raise ValueError(f"Unsupported pair: {pair}. Supported: {self.SUPPORTED_PAIRS}")

        # Validate chain
        if payment_chain not in self.SUPPORTED_CHAINS:
            raise ValueError(f"Unsupported chain: {payment_chain}. Supported: {self.SUPPORTED_CHAINS}")

        # Validate price and size
        if price <= 0:
            raise ValueError("Price must be positive")
        if size <= 0:
            raise ValueError("Size must be positive")

        # Get KPIV address if not provided
        if not lp_kpiv_addr and self.rpc:
            lp_kpiv_addr = self.rpc.getnewaddress("lot")

        # Calculate expiry
        expiry_ts = int(time.time()) + (expiry_hours * 3600)

        # Create LOT
        lot = LOT(
            pair=pair,
            side=side,
            price=price,
            size=size,
            payment_chain=payment_chain,
            payment_addr=payment_addr,
            lp_kpiv_addr=lp_kpiv_addr,
            expiry_ts=expiry_ts
        )

        # Sign if requested
        if sign and self.rpc and lp_kpiv_addr:
            try:
                message = lot.signing_message()
                lot.signature = self.rpc.signmessage(lp_kpiv_addr, message)
                # Get pubkey
                addr_info = self.rpc.validateaddress(lp_kpiv_addr)
                lot.lp_pubkey = addr_info.get("pubkey", "")
            except Exception as e:
                print(f"Warning: Failed to sign LOT: {e}")

        # Store
        self.lots[lot.lot_id] = lot
        self._save_lots()

        return lot

    def get_lot(self, lot_id: str) -> Optional[LOT]:
        """Get LOT by ID."""
        return self.lots.get(lot_id)

    def list_lots(self,
                  pair: str = "",
                  side: Optional[LotSide] = None,
                  status: Optional[LotStatus] = None,
                  include_expired: bool = False) -> List[LOT]:
        """
        List LOTs with optional filtering.

        Args:
            pair: Filter by pair
            side: Filter by side
            status: Filter by status
            include_expired: Include expired LOTs

        Returns:
            List of matching LOTs
        """
        result = []
        for lot in self.lots.values():
            # Filter by pair
            if pair and lot.pair != pair:
                continue

            # Filter by side
            if side and lot.side != side:
                continue

            # Filter by status
            if status and lot.status != status:
                continue

            # Filter expired
            if not include_expired and lot.is_expired():
                continue

            result.append(lot)

        # Sort by price (asks ascending, bids descending)
        result.sort(key=lambda x: x.price, reverse=(side == LotSide.BID))

        return result

    def cancel_lot(self, lot_id: str) -> bool:
        """
        Cancel a LOT.

        Args:
            lot_id: LOT ID to cancel

        Returns:
            True if cancelled, False if not found
        """
        if lot_id not in self.lots:
            return False

        self.lots[lot_id].status = LotStatus.CANCELLED
        self._save_lots()
        return True

    def update_lot_status(self, lot_id: str, status: LotStatus,
                          remaining: Optional[float] = None) -> bool:
        """
        Update LOT status.

        Args:
            lot_id: LOT ID
            status: New status
            remaining: New remaining amount (optional)

        Returns:
            True if updated, False if not found
        """
        if lot_id not in self.lots:
            return False

        self.lots[lot_id].status = status
        if remaining is not None:
            self.lots[lot_id].remaining = remaining
        self._save_lots()
        return True

    def cleanup_expired(self) -> int:
        """
        Mark expired LOTs as expired.

        Returns:
            Number of LOTs marked expired
        """
        count = 0
        for lot in self.lots.values():
            if lot.status == LotStatus.OPEN and lot.is_expired():
                lot.status = LotStatus.EXPIRED
                count += 1

        if count > 0:
            self._save_lots()

        return count

    def get_orderbook(self, pair: str) -> dict:
        """
        Get orderbook for a pair.

        Args:
            pair: Trading pair

        Returns:
            {
                "pair": "KPIV/USDC",
                "asks": [...],  # Sorted by price ascending
                "bids": [...],  # Sorted by price descending
                "best_ask": ...,
                "best_bid": ...,
                "spread": ...
            }
        """
        asks = self.list_lots(pair=pair, side=LotSide.ASK, status=LotStatus.OPEN)
        bids = self.list_lots(pair=pair, side=LotSide.BID, status=LotStatus.OPEN)

        asks.sort(key=lambda x: x.price)
        bids.sort(key=lambda x: x.price, reverse=True)

        best_ask = asks[0].price if asks else None
        best_bid = bids[0].price if bids else None
        spread = (best_ask - best_bid) if (best_ask and best_bid) else None

        return {
            "pair": pair,
            "asks": [lot.to_dict() for lot in asks],
            "bids": [lot.to_dict() for lot in bids],
            "best_ask": best_ask,
            "best_bid": best_bid,
            "spread": spread
        }

    def export_lots(self, pair: str = "", side: Optional[LotSide] = None) -> str:
        """
        Export LOTs as JSON for publication.

        Args:
            pair: Filter by pair
            side: Filter by side

        Returns:
            JSON string of LOTs
        """
        lots = self.list_lots(pair=pair, side=side, status=LotStatus.OPEN)
        return json.dumps({
            "version": "1.0",
            "timestamp": int(time.time()),
            "lots": [lot.to_dict() for lot in lots]
        }, indent=2)

    def import_lots(self, json_str: str, verify_signatures: bool = True) -> int:
        """
        Import LOTs from JSON (e.g., from another LP).

        Args:
            json_str: JSON string of LOTs
            verify_signatures: Whether to verify signatures

        Returns:
            Number of LOTs imported
        """
        data = json.loads(json_str)
        count = 0

        for lot_data in data.get("lots", []):
            lot = LOT.from_dict(lot_data)

            # Skip if already have
            if lot.lot_id in self.lots:
                continue

            # Verify signature if requested
            if verify_signatures and lot.signature and self.rpc:
                try:
                    message = lot.signing_message()
                    if not self.rpc.verifymessage(lot.lp_kpiv_addr, lot.signature, message):
                        print(f"Warning: Invalid signature for LOT {lot.lot_id}")
                        continue
                except Exception as e:
                    print(f"Warning: Failed to verify LOT {lot.lot_id}: {e}")
                    continue

            self.lots[lot.lot_id] = lot
            count += 1

        if count > 0:
            self._save_lots()

        return count
