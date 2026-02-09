#!/usr/bin/env python3
# Copyright (c) 2025 The BATHRON 2.0 developers
# Distributed under the MIT software license

"""
DEX Daemon - Automated LOT attestation and release

Architecture:
  - BATHRON-Core = agnostic (no Polygon/BTC code)
  - dex-daemon = watches external chains, calls RPC

This daemon:
  1. Polls BATHRON for pending takes
  2. Verifies USDC payments on Polygon
  3. Auto-attests when payment confirmed
  4. Auto-releases when quorum reached
"""

import json
import time
import argparse
import logging
import sys
from typing import Optional, Dict, List, Any
from dataclasses import dataclass
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

# =============================================================================
# CONFIGURATION
# =============================================================================

@dataclass
class Config:
    # Polygon RPC (public, no API key needed)
    polygon_rpc: str = "https://polygon-bor-rpc.publicnode.com"
    polygon_confirmations: int = 12  # ~24 seconds

    # USDC Contract (Polygon Mainnet)
    usdc_contract: str = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359"
    usdc_decimals: int = 6

    # Daemon settings
    poll_interval: int = 30  # seconds
    log_level: str = "INFO"


# =============================================================================
# BATHRON RPC CLIENT (via CLI)
# =============================================================================

class BATHRONRPC:
    """RPC client using bathron-cli subprocess (more reliable than HTTP)"""

    def __init__(self, cli_path: str = "bathron-cli", testnet: bool = True):
        self.cli_path = cli_path
        self.testnet = testnet

    def call(self, method: str, params: List = None) -> Any:
        """Make RPC call via bathron-cli"""
        import subprocess

        cmd = [self.cli_path]
        if self.testnet:
            cmd.append("-testnet")
        cmd.append(method)
        if params:
            for p in params:
                cmd.append(str(p))

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30
            )
            if result.returncode != 0:
                raise Exception(f"CLI error: {result.stderr.strip()}")

            output = result.stdout.strip()
            if not output:
                return None

            # Try to parse as JSON
            try:
                return json.loads(output)
            except json.JSONDecodeError:
                # Return raw string if not JSON
                return output

        except subprocess.TimeoutExpired:
            raise Exception("CLI timeout")
        except FileNotFoundError:
            raise Exception(f"CLI not found: {self.cli_path}")

    # DEX RPCs
    def lot_get_pending_takes(self) -> List[Dict]:
        return self.call("lot_get_pending_takes")

    def lot_get(self, outpoint: str) -> Dict:
        return self.call("lot_get", [outpoint])

    def lot_attest(self, outpoint: str, quote_tx_hash: str) -> Dict:
        return self.call("lot_attest", [outpoint, quote_tx_hash])

    def lot_try_release(self, outpoint: str) -> Dict:
        return self.call("lot_try_release", [outpoint])

    def lot_list(self) -> List[Dict]:
        return self.call("lot_list")

    def getblockcount(self) -> int:
        return self.call("getblockcount")


# =============================================================================
# POLYGON WATCHER
# =============================================================================

class PolygonWatcher:
    """Watches Polygon for USDC payments"""

    # ERC20 Transfer event topic
    TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

    def __init__(self, rpc_url: str, usdc_contract: str, confirmations: int = 12):
        self.rpc_url = rpc_url
        self.usdc_contract = usdc_contract.lower()
        self.confirmations_required = confirmations
        self._id = 0

    def _rpc_call(self, method: str, params: List) -> Any:
        """Make JSON-RPC call to Polygon"""
        self._id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": self._id,
            "method": method,
            "params": params
        }

        req = Request(
            self.rpc_url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}
        )

        try:
            with urlopen(req, timeout=30) as resp:
                result = json.loads(resp.read().decode())
                if "error" in result and result["error"]:
                    logging.warning(f"Polygon RPC error: {result['error']}")
                    return None
                return result.get("result")
        except Exception as e:
            logging.error(f"Polygon RPC failed: {e}")
            return None

    def get_block_number(self) -> Optional[int]:
        """Get current Polygon block number"""
        result = self._rpc_call("eth_blockNumber", [])
        if result:
            return int(result, 16)
        return None

    def verify_payment(self, tx_hash: str, expected_to: str, expected_amount: int) -> Optional[Dict]:
        """
        Verify a USDC payment on Polygon

        Args:
            tx_hash: Polygon transaction hash (0x...)
            expected_to: Expected recipient address (0x...)
            expected_amount: Expected amount in USDC units (6 decimals)

        Returns:
            Payment info dict if valid and confirmed, None otherwise
        """
        # Get transaction receipt
        receipt = self._rpc_call("eth_getTransactionReceipt", [tx_hash])
        if not receipt:
            logging.debug(f"TX {tx_hash[:16]}... not found")
            return None

        # Check status
        if receipt.get("status") != "0x1":
            logging.warning(f"TX {tx_hash[:16]}... failed")
            return None

        # Get confirmations
        tx_block = int(receipt.get("blockNumber", "0x0"), 16)
        current_block = self.get_block_number()
        if not current_block:
            return None

        confirmations = current_block - tx_block
        if confirmations < self.confirmations_required:
            logging.debug(f"TX {tx_hash[:16]}... needs more confirmations ({confirmations}/{self.confirmations_required})")
            return None

        # Parse logs for USDC transfer
        expected_to_normalized = expected_to.lower()
        if expected_to_normalized.startswith("0x"):
            expected_to_normalized = expected_to_normalized[2:]

        for log in receipt.get("logs", []):
            # Check contract address
            contract = log.get("address", "").lower()
            if contract != self.usdc_contract:
                continue

            topics = log.get("topics", [])
            if len(topics) < 3:
                continue

            # Check Transfer event
            if topics[0].lower() != self.TRANSFER_TOPIC:
                continue

            # Extract 'to' address (last 40 chars of topic[2])
            to_addr = topics[2][-40:].lower()
            if to_addr != expected_to_normalized:
                continue

            # Extract amount from data
            data = log.get("data", "0x0")
            amount = int(data, 16)

            if amount < expected_amount:
                logging.warning(f"TX {tx_hash[:16]}... amount too low: {amount} < {expected_amount}")
                continue

            # Valid payment!
            from_addr = "0x" + topics[1][-40:]
            return {
                "tx_hash": tx_hash,
                "from": from_addr,
                "to": "0x" + to_addr,
                "amount": amount,
                "amount_usdc": amount / 1_000_000,
                "block": tx_block,
                "confirmations": confirmations
            }

        logging.debug(f"TX {tx_hash[:16]}... no matching USDC transfer found")
        return None


# =============================================================================
# DEX DAEMON
# =============================================================================

class DexDaemon:
    """
    Main DEX daemon - watches Polygon and auto-attests/releases
    """

    def __init__(self, config: Config, cli_path: str = "bathron-cli"):
        self.config = config
        self.cli_path = cli_path
        self.bathron = BATHRONRPC(cli_path=cli_path, testnet=True)
        self.polygon = PolygonWatcher(
            config.polygon_rpc,
            config.usdc_contract,
            config.polygon_confirmations
        )
        self.processed_takes = set()  # Track already processed takes

    def get_lot_conditions(self, outpoint: str) -> Optional[Dict]:
        """Get LOT conditions (payment address, price)"""
        try:
            lot = self.bathron.lot_get(outpoint)
            if not lot:
                return None

            # Parse conditions from blob if available
            conditions_blob = lot.get("conditions_blob")
            if conditions_blob:
                try:
                    conditions_json = bytes.fromhex(conditions_blob).decode('utf-8')
                    return json.loads(conditions_json)
                except:
                    pass

            return None
        except Exception as e:
            logging.error(f"Failed to get LOT {outpoint}: {e}")
            return None

    def process_pending_takes(self):
        """Process all pending takes"""
        try:
            pending = self.bathron.lot_get_pending_takes()
        except Exception as e:
            logging.error(f"Failed to get pending takes: {e}")
            return

        if not pending:
            logging.debug("No pending takes")
            return

        logging.info(f"Processing {len(pending)} pending take(s)")

        for take in pending:
            outpoint = take.get("lot_outpoint", "")
            # Normalize outpoint format
            if outpoint.startswith("COutPoint("):
                # Parse "COutPoint(1475644f23, 0)" format
                import re
                match = re.match(r"COutPoint\(([^,]+),\s*(\d+)\)", outpoint)
                if match:
                    outpoint = f"{match.group(1)}:{match.group(2)}"

            swap_id = take.get("swap_id", "")

            # Skip if already processed
            if swap_id in self.processed_takes:
                continue

            self.process_single_take(outpoint, take)

    def process_single_take(self, outpoint: str, take: Dict):
        """Process a single pending take"""
        swap_id = take.get("swap_id", "unknown")
        logging.info(f"Processing take {swap_id[:16]}... for LOT {outpoint}")

        # Get LOT conditions
        conditions = self.get_lot_conditions(outpoint)
        if not conditions:
            logging.warning(f"Cannot get conditions for LOT {outpoint}")
            return

        payment_address = conditions.get("payment_address")
        price = conditions.get("price")
        quote_asset = conditions.get("quote_asset", "USDC")

        if not payment_address or not price:
            logging.warning(f"Missing payment_address or price in conditions")
            return

        if quote_asset != "USDC":
            logging.debug(f"Skipping non-USDC take (asset: {quote_asset})")
            return

        # Calculate expected amount
        try:
            price_float = float(price)
            expected_amount = int(price_float * 1_000_000)  # USDC has 6 decimals
        except:
            logging.error(f"Invalid price: {price}")
            return

        # We need the quote_tx_hash - check if it's in the take
        # For now, we need to get it from somewhere...
        # The take should have the tx_hash from lot_take call
        quote_tx_hash = take.get("quote_tx_hash")
        if not quote_tx_hash:
            logging.debug(f"No quote_tx_hash in take, cannot verify")
            return

        # Verify payment on Polygon
        logging.info(f"Verifying Polygon payment {quote_tx_hash[:16]}...")
        payment = self.polygon.verify_payment(quote_tx_hash, payment_address, expected_amount)

        if not payment:
            logging.debug(f"Payment not yet confirmed")
            return

        logging.info(f"Payment CONFIRMED: {payment['amount_usdc']:.2f} USDC from {payment['from']}")

        # Attest!
        try:
            result = self.bathron.lot_attest(outpoint, quote_tx_hash)
            logging.info(f"Attestation result: {result}")

            if result.get("quorum_reached"):
                logging.info("QUORUM REACHED - Attempting release...")
                self.try_release(outpoint)

        except Exception as e:
            logging.error(f"Attestation failed: {e}")

    def try_release(self, outpoint: str):
        """Try to release a LOT"""
        try:
            result = self.bathron.lot_try_release(outpoint)
            if result.get("released"):
                txid = result.get("txid", "unknown")
                logging.info(f"LOT RELEASED! TXID: {txid}")
                self.processed_takes.add(outpoint)
            else:
                reason = result.get("reason", "unknown")
                logging.warning(f"Release failed: {reason}")
        except Exception as e:
            logging.error(f"Release failed: {e}")

    def check_releasable_lots(self):
        """Check if any LOTs have quorum and can be released"""
        try:
            pending = self.bathron.lot_get_pending_takes()
            for take in pending:
                outpoint = take.get("lot_outpoint", "")
                if outpoint.startswith("COutPoint("):
                    import re
                    match = re.match(r"COutPoint\(([^,]+),\s*(\d+)\)", outpoint)
                    if match:
                        outpoint = f"{match.group(1)}:{match.group(2)}"

                # Check attestation count
                lot = self.bathron.lot_get(outpoint)
                if lot and lot.get("attestation_count", 0) >= 3:
                    logging.info(f"LOT {outpoint} has quorum, trying release...")
                    self.try_release(outpoint)
        except Exception as e:
            logging.error(f"Failed to check releasable LOTs: {e}")

    def run(self):
        """Main daemon loop"""
        logging.info("=" * 60)
        logging.info("DEX Daemon starting...")
        logging.info(f"  BATHRON CLI: {self.cli_path}")
        logging.info(f"  Polygon RPC: {self.config.polygon_rpc}")
        logging.info(f"  USDC Contract: {self.config.usdc_contract}")
        logging.info(f"  Poll interval: {self.config.poll_interval}s")
        logging.info("=" * 60)

        # Test connections
        try:
            height = self.bathron.getblockcount()
            logging.info(f"BATHRON connected - block height: {height}")
        except Exception as e:
            logging.error(f"Failed to connect to BATHRON: {e}")
            return

        poly_block = self.polygon.get_block_number()
        if poly_block:
            logging.info(f"Polygon connected - block height: {poly_block}")
        else:
            logging.error("Failed to connect to Polygon")
            return

        logging.info("Starting main loop...")

        while True:
            try:
                self.process_pending_takes()
                self.check_releasable_lots()
            except KeyboardInterrupt:
                logging.info("Shutting down...")
                break
            except Exception as e:
                logging.error(f"Error in main loop: {e}")

            time.sleep(self.config.poll_interval)


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(description="DEX Daemon for BATHRON")
    parser.add_argument("--cli", default="bathron-cli", help="Path to bathron-cli binary")
    parser.add_argument("--polygon-rpc", default="https://polygon-bor-rpc.publicnode.com", help="Polygon RPC URL")
    parser.add_argument("--poll-interval", type=int, default=30, help="Poll interval in seconds")
    parser.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    parser.add_argument("--once", action="store_true", help="Run once and exit (for testing)")

    args = parser.parse_args()

    # Setup logging
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S"
    )

    config = Config(
        polygon_rpc=args.polygon_rpc,
        poll_interval=args.poll_interval,
        log_level=args.log_level
    )

    daemon = DexDaemon(config, cli_path=args.cli)

    if args.once:
        daemon.process_pending_takes()
        daemon.check_releasable_lots()
    else:
        daemon.run()


if __name__ == "__main__":
    main()
