"""
BATHRON 2.0 DEX SDK - Data Types

LOT and HTLC data structures for off-chain management.
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional
import json
import hashlib
import time


class LotSide(Enum):
    """LOT side: ASK = LP sells KPIV, BID = LP buys KPIV"""
    ASK = "ask"
    BID = "bid"


class LotStatus(Enum):
    """LOT status"""
    OPEN = "open"
    TAKEN = "taken"
    FILLED = "filled"
    CANCELLED = "cancelled"
    EXPIRED = "expired"


@dataclass
class LOT:
    """
    LOT (Limit Order Ticket) - Off-chain order announcement.

    LOTs are signed messages published by LPs to announce their trading intent.
    They live off-chain and are propagated via HTTP/WS.

    Structure:
      - pair: Trading pair (e.g., "KPIV/USDC")
      - side: ASK (LP sells KPIV) or BID (LP buys KPIV)
      - price: Quote asset per KPIV (e.g., 1.05 USDC/KPIV)
      - size: Amount in KPIV
      - payment_chain: External chain for settlement (e.g., "polygon")
      - payment_addr: LP's address on external chain
      - lp_kpiv_addr: LP's KPIV address
      - expiry_ts: Unix timestamp when LOT expires
      - lp_pubkey: LP's public key (hex)
      - signature: LP's signature (hex)
    """
    # Core fields
    pair: str
    side: LotSide
    price: float
    size: float
    payment_chain: str
    payment_addr: str
    lp_kpiv_addr: str

    # Timing
    expiry_ts: int = 0
    created_ts: int = field(default_factory=lambda: int(time.time()))

    # Identity
    lp_pubkey: str = ""
    signature: str = ""

    # Status (local tracking)
    status: LotStatus = LotStatus.OPEN
    remaining: float = 0.0

    # Computed ID
    lot_id: str = ""

    def __post_init__(self):
        if self.remaining == 0.0:
            self.remaining = self.size
        if not self.lot_id:
            self.lot_id = self.compute_lot_id()

    def compute_lot_id(self) -> str:
        """Compute deterministic LOT ID from core fields."""
        data = f"{self.pair}:{self.side.value}:{self.price}:{self.size}:" \
               f"{self.payment_chain}:{self.payment_addr}:{self.lp_kpiv_addr}:{self.created_ts}"
        return hashlib.sha256(data.encode()).hexdigest()[:16]

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "lot_id": self.lot_id,
            "pair": self.pair,
            "side": self.side.value,
            "price": self.price,
            "size": self.size,
            "remaining": self.remaining,
            "payment_chain": self.payment_chain,
            "payment_addr": self.payment_addr,
            "lp_kpiv_addr": self.lp_kpiv_addr,
            "expiry_ts": self.expiry_ts,
            "created_ts": self.created_ts,
            "lp_pubkey": self.lp_pubkey,
            "signature": self.signature,
            "status": self.status.value
        }

    @classmethod
    def from_dict(cls, data: dict) -> "LOT":
        """Create LOT from dictionary."""
        return cls(
            pair=data["pair"],
            side=LotSide(data["side"]),
            price=float(data["price"]),
            size=float(data["size"]),
            payment_chain=data["payment_chain"],
            payment_addr=data["payment_addr"],
            lp_kpiv_addr=data["lp_kpiv_addr"],
            expiry_ts=data.get("expiry_ts", 0),
            created_ts=data.get("created_ts", int(time.time())),
            lp_pubkey=data.get("lp_pubkey", ""),
            signature=data.get("signature", ""),
            status=LotStatus(data.get("status", "open")),
            remaining=float(data.get("remaining", data["size"])),
            lot_id=data.get("lot_id", "")
        )

    def to_json(self) -> str:
        """Convert to JSON string."""
        return json.dumps(self.to_dict(), indent=2)

    @classmethod
    def from_json(cls, json_str: str) -> "LOT":
        """Create LOT from JSON string."""
        return cls.from_dict(json.loads(json_str))

    def is_expired(self) -> bool:
        """Check if LOT has expired."""
        if self.expiry_ts == 0:
            return False
        return int(time.time()) > self.expiry_ts

    def signing_message(self) -> str:
        """Get message to sign (canonical format)."""
        return f"LOT:{self.pair}:{self.side.value}:{self.price}:{self.size}:" \
               f"{self.payment_chain}:{self.payment_addr}:{self.lp_kpiv_addr}:" \
               f"{self.expiry_ts}:{self.created_ts}"


class HTLCStatus(Enum):
    """HTLC status"""
    PENDING = "pending"
    LOCKED = "locked"
    CLAIMED = "claimed"
    REFUNDED = "refunded"
    EXPIRED = "expired"


@dataclass
class HTLC:
    """
    HTLC (Hash Time Locked Contract) - On-chain settlement.

    HTLCs are on-chain contracts that lock KPIV until:
      - Taker reveals preimage S (claim)
      - Timeout expires (refund to LP)

    This SDK wraps the core htlc_* RPCs.
    """
    # Core fields
    hashlock: str           # H = SHA256(S)
    amount: float           # KPIV amount
    recipient_addr: str     # Taker's KPIV address
    lp_addr: str           # LP's KPIV address (refund)
    expiry_height: int      # Block height for timeout

    # Status
    status: HTLCStatus = HTLCStatus.PENDING

    # On-chain data
    outpoint: str = ""      # txid:vout when created
    preimage: str = ""      # S, revealed on claim
    claim_txid: str = ""    # Claim transaction ID
    refund_txid: str = ""   # Refund transaction ID

    # Timing
    created_height: int = 0
    created_ts: int = field(default_factory=lambda: int(time.time()))

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "hashlock": self.hashlock,
            "amount": self.amount,
            "recipient_addr": self.recipient_addr,
            "lp_addr": self.lp_addr,
            "expiry_height": self.expiry_height,
            "status": self.status.value,
            "outpoint": self.outpoint,
            "preimage": self.preimage,
            "claim_txid": self.claim_txid,
            "refund_txid": self.refund_txid,
            "created_height": self.created_height,
            "created_ts": self.created_ts
        }

    @classmethod
    def from_dict(cls, data: dict) -> "HTLC":
        """Create HTLC from dictionary."""
        return cls(
            hashlock=data["hashlock"],
            amount=float(data["amount"]),
            recipient_addr=data["recipient_addr"],
            lp_addr=data["lp_addr"],
            expiry_height=int(data["expiry_height"]),
            status=HTLCStatus(data.get("status", "pending")),
            outpoint=data.get("outpoint", ""),
            preimage=data.get("preimage", ""),
            claim_txid=data.get("claim_txid", ""),
            refund_txid=data.get("refund_txid", ""),
            created_height=int(data.get("created_height", 0)),
            created_ts=int(data.get("created_ts", time.time()))
        )
