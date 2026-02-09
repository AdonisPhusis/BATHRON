"""
BATHRON 2.0 DEX SDK - HTLC Wrapper

On-chain HTLC settlement via core RPCs.
"""

import hashlib
import secrets
from typing import Optional, Tuple, List

try:
    from .dex_types import HTLC, HTLCStatus
    from .rpc_client import RPCClient, RPCError
except ImportError:
    from dex_types import HTLC, HTLCStatus
    from rpc_client import RPCClient, RPCError


class HTLCWrapper:
    """
    HTLC wrapper for on-chain settlement.

    Wraps the core htlc_* RPCs and provides higher-level functions
    for atomic swap settlement.

    Usage:
        htlc = HTLCWrapper(rpc)

        # Generate secret and hashlock
        secret, hashlock = htlc.generate_secret()

        # Create HTLC (LP locks KPIV)
        result = htlc.create(hashlock, 100.0, "taker_address", expiry_blocks=720)

        # Claim HTLC (Taker reveals secret)
        claim_result = htlc.claim(result["outpoint"], secret)

        # Or refund after timeout (LP only)
        refund_result = htlc.refund(result["outpoint"])
    """

    def __init__(self, rpc: RPCClient):
        """
        Initialize HTLC wrapper.

        Args:
            rpc: RPC client connected to bathrond
        """
        self.rpc = rpc

    @staticmethod
    def generate_secret() -> Tuple[str, str]:
        """
        Generate random secret S and hashlock H = SHA256(S).

        Returns:
            (secret, hashlock) as hex strings
        """
        secret_bytes = secrets.token_bytes(32)
        secret = secret_bytes.hex()
        hashlock = hashlib.sha256(secret_bytes).hexdigest()
        return secret, hashlock

    @staticmethod
    def compute_hashlock(secret: str) -> str:
        """
        Compute hashlock from secret.

        Args:
            secret: 32-byte secret as hex string

        Returns:
            hashlock as hex string
        """
        secret_bytes = bytes.fromhex(secret)
        return hashlib.sha256(secret_bytes).hexdigest()

    @staticmethod
    def verify_preimage(hashlock: str, preimage: str) -> bool:
        """
        Verify that preimage matches hashlock.

        Args:
            hashlock: Expected hashlock
            preimage: Claimed preimage

        Returns:
            True if SHA256(preimage) == hashlock
        """
        try:
            computed = hashlib.sha256(bytes.fromhex(preimage)).hexdigest()
            return computed.lower() == hashlock.lower()
        except:
            return False

    def create(self, hashlock: str, amount: float,
               claim_addr: str, expiry_blocks: int = 720,
               claim_signing_addr: str = "",
               refund_dest: str = "",
               refund_signing_addr: str = "") -> dict:
        """
        Create HTLC that locks KPIV with hot/cold wallet separation.

        This is called by the LP to lock KPIV for the taker.

        Args:
            hashlock: H = SHA256(S) in hex
            amount: KPIV amount to lock
            claim_addr: Taker's KPIV destination (cold wallet)
            expiry_blocks: Blocks until LP can refund (default ~12 hours)
            claim_signing_addr: Taker's signing key (hot wallet, optional)
            refund_dest: LP's refund destination (cold wallet, optional)
            refund_signing_addr: LP's refund signing key (hot wallet, optional)

        Returns:
            {
                "txid": "...",
                "outpoint": "txid:vout",
                "hashlock": "...",
                "amount": ...,
                "expiry_height": ...,
                "claim_destination": "...",
                "refund_destination": "..."
            }

        Hot/Cold Security Model:
            - claim_addr (cold): Where KPIV goes after claim
            - claim_signing_addr (hot): Key that signs claim TX
            - refund_dest (cold): Where KPIV goes after refund
            - refund_signing_addr (hot): Key that signs refund TX

            If hot wallet is compromised, attacker can trigger claim/refund
            but funds STILL go to cold wallet. No fund loss, only griefing.
        """
        return self.rpc.htlc_create_kpiv(
            hashlock, amount, claim_addr, expiry_blocks,
            claim_signing_addr, refund_dest, refund_signing_addr
        )

    def claim(self, outpoint: str, preimage: str) -> dict:
        """
        Claim HTLC with preimage.

        This is called by the taker to claim their KPIV.

        Args:
            outpoint: HTLC outpoint (txid:vout)
            preimage: S such that SHA256(S) = H

        Returns:
            {
                "txid": "...",
                "preimage": "...",
                "amount": ...
            }
        """
        return self.rpc.htlc_claim_kpiv(outpoint, preimage)

    def refund(self, outpoint: str) -> dict:
        """
        Refund HTLC after timeout.

        This is called by the LP if the taker doesn't claim in time.

        Args:
            outpoint: HTLC outpoint (txid:vout)

        Returns:
            {
                "txid": "...",
                "amount": ...
            }
        """
        return self.rpc.htlc_refund_kpiv(outpoint)

    def list(self, filter_status: str = "") -> List[dict]:
        """
        List all HTLCs.

        Args:
            filter_status: Optional filter ("pending", "locked", "claimed", "refunded")

        Returns:
            List of HTLC objects
        """
        return self.rpc.htlc_list(filter_status)

    def get(self, identifier: str) -> Optional[dict]:
        """
        Get HTLC by outpoint or hashlock.

        Args:
            identifier: HTLC outpoint or hashlock

        Returns:
            HTLC details or None if not found
        """
        try:
            return self.rpc.htlc_get(identifier)
        except RPCError:
            return None

    def get_by_hashlock(self, hashlock: str) -> Optional[dict]:
        """
        Get HTLC by hashlock.

        Args:
            hashlock: HTLC hashlock

        Returns:
            HTLC details or None if not found
        """
        return self.get(hashlock)

    def is_claimable(self, outpoint: str) -> bool:
        """
        Check if HTLC is claimable (locked and not expired).

        Args:
            outpoint: HTLC outpoint

        Returns:
            True if claimable
        """
        htlc = self.get(outpoint)
        if not htlc:
            return False

        # Check status
        if htlc.get("status") not in ["pending", "locked"]:
            return False

        # Check not expired
        current_height = self.rpc.getblockcount()
        if current_height >= htlc.get("expiry_height", 0):
            return False

        return True

    def is_refundable(self, outpoint: str) -> bool:
        """
        Check if HTLC is refundable (expired and not claimed).

        Args:
            outpoint: HTLC outpoint

        Returns:
            True if refundable
        """
        htlc = self.get(outpoint)
        if not htlc:
            return False

        # Check not already claimed/refunded
        if htlc.get("status") in ["claimed", "refunded"]:
            return False

        # Check expired
        current_height = self.rpc.getblockcount()
        if current_height < htlc.get("expiry_height", 0):
            return False

        return True

    def get_current_height(self) -> int:
        """Get current block height."""
        return self.rpc.getblockcount()

    def blocks_until_expiry(self, outpoint: str) -> int:
        """
        Get blocks until HTLC expires.

        Args:
            outpoint: HTLC outpoint

        Returns:
            Blocks until expiry (negative if already expired)
        """
        htlc = self.get(outpoint)
        if not htlc:
            return 0

        current_height = self.rpc.getblockcount()
        expiry_height = htlc.get("expiry_height", 0)
        return expiry_height - current_height


class SwapExecutor:
    """
    High-level swap executor for ASK and BID flows.

    Orchestrates the full swap process including:
      - Secret generation
      - HTLC creation
      - Claim/refund handling
    """

    def __init__(self, htlc: HTLCWrapper):
        """
        Initialize swap executor.

        Args:
            htlc: HTLC wrapper
        """
        self.htlc = htlc

    def start_ask_swap(self, amount: float, taker_addr: str,
                       expiry_blocks: int = 720) -> dict:
        """
        Start ASK swap (LP sells KPIV).

        Flow:
          1. Generate secret S, hashlock H
          2. Taker locks external asset (USDC) with H
          3. LP creates KPIV HTLC with H
          4. Taker claims KPIV, reveals S
          5. LP claims external asset with S

        Args:
            amount: KPIV amount
            taker_addr: Taker's KPIV address
            expiry_blocks: KPIV HTLC expiry

        Returns:
            {
                "secret": "...",
                "hashlock": "...",
                "step": "waiting_for_external_lock"
            }
        """
        secret, hashlock = self.htlc.generate_secret()

        return {
            "secret": secret,
            "hashlock": hashlock,
            "amount": amount,
            "taker_addr": taker_addr,
            "expiry_blocks": expiry_blocks,
            "step": "waiting_for_external_lock",
            "instructions": (
                f"1. Share hashlock {hashlock[:16]}... with taker\n"
                f"2. Wait for taker to lock external asset with this hashlock\n"
                f"3. Verify external HTLC, then call complete_ask_swap()"
            )
        }

    def complete_ask_swap(self, hashlock: str, amount: float,
                          taker_addr: str, expiry_blocks: int = 720) -> dict:
        """
        Complete ASK swap by creating KPIV HTLC.

        Called after verifying taker's external HTLC.

        Args:
            hashlock: Hashlock from start_ask_swap
            amount: KPIV amount
            taker_addr: Taker's KPIV address
            expiry_blocks: KPIV HTLC expiry

        Returns:
            HTLC creation result
        """
        return self.htlc.create(hashlock, amount, taker_addr, expiry_blocks)

    def claim_with_secret(self, outpoint: str, secret: str) -> dict:
        """
        Claim KPIV HTLC with secret (taker action).

        Args:
            outpoint: KPIV HTLC outpoint
            secret: Preimage S

        Returns:
            Claim result
        """
        return self.htlc.claim(outpoint, secret)
