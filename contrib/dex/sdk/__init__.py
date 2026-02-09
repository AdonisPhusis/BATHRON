"""
BATHRON 2.0 DEX SDK

Off-chain LOT management and on-chain HTLC settlement.

Architecture:
  - LOTs (BID/ASK offers) are managed OFF-CHAIN via this SDK
  - HTLCs (settlement) are ON-CHAIN via core RPCs
  - The core is a settlement layer, not an exchange

Standard LOT Sizes:
  - Core (protocol): Accepts ANY positive KPIV amount (permissionless)
  - SDK (policy): Enforces standard sizes {1, 10, 100, 1000, 10000} KPIV
  - Non-standard amounts are auto-split by SDK

Usage:
    from sdk import LOTManager, HTLCWrapper, RPCClient, split_amount

    # Connect to node
    rpc = RPCClient("localhost", 27170, "user", "pass")

    # Split amount into standard lots
    lots = split_amount(55)  # [10,10,10,10,10, 1,1,1,1,1]

    # Create LOT manager
    lot_mgr = LOTManager()

    # Create HTLC wrapper
    htlc = HTLCWrapper(rpc)
"""

from .dex_types import LOT, HTLC, LotSide
from .rpc_client import RPCClient
from .lot_manager import LOTManager
from .htlc_wrapper import HTLCWrapper
from .lot_sizes import (
    STANDARD_SIZES,
    split_amount,
    split_amount_grouped,
    split_amount_optimized,
    count_lots,
    is_standard_size,
    format_split,
    validate_amount,
)

__version__ = "0.3.0"  # Hot/cold wallet support
__all__ = [
    # Types
    "LOT", "HTLC", "LotSide",
    # Core
    "RPCClient", "LOTManager", "HTLCWrapper",
    # Lot sizes
    "STANDARD_SIZES", "split_amount", "split_amount_grouped",
    "split_amount_optimized", "count_lots", "is_standard_size",
    "format_split", "validate_amount",
]
