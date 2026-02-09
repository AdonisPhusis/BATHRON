"""
BATHRON 2.0 DEX SDK - RPC Client

JSON-RPC client for communicating with bathrond core.
"""

import json
import requests
from typing import Any, Optional, List, Dict


class RPCError(Exception):
    """RPC call failed."""
    def __init__(self, code: int, message: str):
        self.code = code
        self.message = message
        super().__init__(f"RPC Error {code}: {message}")


class RPCClient:
    """
    JSON-RPC client for bathrond.

    Usage:
        rpc = RPCClient("localhost", 27170, "user", "pass")
        height = rpc.getblockcount()
        balance = rpc.getbalances()
    """

    def __init__(self, host: str = "localhost", port: int = 27170,
                 user: str = "testuser", password: str = "testpass123",
                 timeout: int = 30):
        self.url = f"http://{host}:{port}"
        self.auth = (user, password)
        self.timeout = timeout
        self._id = 0

    def _call(self, method: str, params: list = None) -> Any:
        """Make RPC call."""
        self._id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": self._id,
            "method": method,
            "params": params or []
        }

        try:
            response = requests.post(
                self.url,
                json=payload,
                auth=self.auth,
                timeout=self.timeout
            )
            response.raise_for_status()
        except requests.exceptions.RequestException as e:
            raise RPCError(-1, f"Connection failed: {e}")

        result = response.json()

        if "error" in result and result["error"]:
            raise RPCError(result["error"]["code"], result["error"]["message"])

        return result.get("result")

    def __getattr__(self, name: str):
        """Allow calling RPC methods as attributes."""
        def method(*args):
            return self._call(name, list(args))
        return method

    # ═══════════════════════════════════════════════════════════════════════
    # COMMON RPC METHODS (typed for IDE support)
    # ═══════════════════════════════════════════════════════════════════════

    def getblockcount(self) -> int:
        """Get current block height."""
        return self._call("getblockcount")

    def getblockchaininfo(self) -> dict:
        """Get blockchain info."""
        return self._call("getblockchaininfo")

    def getbalances(self) -> dict:
        """Get wallet balances (PIV, KPIV, savings)."""
        return self._call("getbalances")

    def getnewaddress(self, label: str = "") -> str:
        """Get new address from wallet."""
        return self._call("getnewaddress", [label] if label else [])

    def send(self, asset: str, address: str, amount: float) -> str:
        """Send PIV or KPIV."""
        return self._call("send", [asset, address, amount])

    def deposit(self, amount: float) -> str:
        """Deposit PIV -> KPIV."""
        return self._call("deposit", [amount])

    def withdraw(self, amount: float) -> str:
        """Withdraw KPIV -> PIV."""
        return self._call("withdraw", [amount])

    # ═══════════════════════════════════════════════════════════════════════
    # HTLC RPC METHODS
    # ═══════════════════════════════════════════════════════════════════════

    def htlc_create_kpiv(self, hashlock: str, amount: float,
                         claim_addr: str, expiry_blocks: int = 720,
                         claim_signing_addr: str = "",
                         refund_dest: str = "",
                         refund_signing_addr: str = "") -> dict:
        """
        Create HTLC that locks KPIV with hot/cold wallet separation.

        Args:
            hashlock: H = SHA256(S) in hex
            amount: KPIV amount to lock
            claim_addr: Taker's KPIV destination (cold wallet)
            expiry_blocks: Blocks until LP can refund (default 12 hours)
            claim_signing_addr: Taker's signing address (hot wallet, optional)
            refund_dest: LP's refund destination (cold wallet, optional)
            refund_signing_addr: LP's refund signing (hot wallet, optional)

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

            If hot wallet is compromised, attacker can only trigger
            claim/refund but cannot redirect funds (they go to cold).
        """
        params = [hashlock, amount, claim_addr, expiry_blocks]
        if claim_signing_addr:
            params.append(claim_signing_addr)
            if refund_dest:
                params.append(refund_dest)
                if refund_signing_addr:
                    params.append(refund_signing_addr)
        return self._call("htlc_create_kpiv", params)

    def htlc_claim_kpiv(self, outpoint: str, preimage: str) -> dict:
        """
        Claim HTLC with preimage S.

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
        return self._call("htlc_claim_kpiv", [outpoint, preimage])

    def htlc_refund_kpiv(self, outpoint: str) -> dict:
        """
        Refund HTLC after timeout (LP only).

        Args:
            outpoint: HTLC outpoint (txid:vout)

        Returns:
            {
                "txid": "...",
                "amount": ...
            }
        """
        return self._call("htlc_refund_kpiv", [outpoint])

    def htlc_list(self, filter_status: str = "") -> List[dict]:
        """
        List HTLCs.

        Args:
            filter_status: Optional filter ("pending", "locked", "claimed", "refunded")

        Returns:
            List of HTLC objects
        """
        params = [filter_status] if filter_status else []
        return self._call("htlc_list", params)

    def htlc_get(self, identifier: str) -> dict:
        """
        Get HTLC details by outpoint or hashlock.

        Args:
            identifier: HTLC outpoint or hashlock

        Returns:
            HTLC details
        """
        return self._call("htlc_get", [identifier])

    # ═══════════════════════════════════════════════════════════════════════
    # UTILITY METHODS
    # ═══════════════════════════════════════════════════════════════════════

    def signmessage(self, address: str, message: str) -> str:
        """Sign message with address key."""
        return self._call("signmessage", [address, message])

    def verifymessage(self, address: str, signature: str, message: str) -> bool:
        """Verify message signature."""
        return self._call("verifymessage", [address, signature, message])

    def validateaddress(self, address: str) -> dict:
        """Validate address."""
        return self._call("validateaddress", [address])

    def getstate(self) -> dict:
        """Get global state (C, U, Z, Treasury, etc.)."""
        return self._call("getstate")

    def test_connection(self) -> bool:
        """Test if RPC connection works."""
        try:
            self.getblockcount()
            return True
        except:
            return False
