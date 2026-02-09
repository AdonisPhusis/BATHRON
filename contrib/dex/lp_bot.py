#!/usr/bin/env python3
"""
LP Bot - Automatic USDC claimer for BATHRON HTLC DEX

This bot monitors BATHRON blockchain for revealed preimages (htlc_claim transactions)
and automatically claims the corresponding USDC on Polygon.

Usage:
    python3 lp_bot.py [--config config.json] [--once]

Requirements:
    pip install web3 requests
"""

import json
import time
import argparse
import logging
from pathlib import Path
from typing import Optional, Dict, Any
import requests

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
log = logging.getLogger('lp_bot')

# Default configuration
DEFAULT_CONFIG = {
    "bathron_rpc": {
        "host": "127.0.0.1",
        "port": 27170,
        "user": "testuser",
        "password": "testpass123"
    },
    "polygon": {
        "rpc_url": "https://polygon-rpc.com",
        "htlc_contract": "0x3F1843Bc98C526542d6112448842718adc13fA5F",
        "chain_id": 137
    },
    "lp_wallet": {
        "private_key": "",  # Set this in config file!
        "address": ""
    },
    "poll_interval": 10,  # seconds
    "state_file": "lp_bot_state.json"
}

# HTLC Contract ABI (only claim function)
HTLC_ABI = [
    {
        "inputs": [
            {"name": "swapId", "type": "bytes32"},
            {"name": "preimage", "type": "bytes32"}
        ],
        "name": "claim",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function"
    },
    {
        "inputs": [{"name": "", "type": "bytes32"}],
        "name": "swaps",
        "outputs": [
            {"name": "lp", "type": "address"},
            {"name": "taker", "type": "address"},
            {"name": "token", "type": "address"},
            {"name": "amount", "type": "uint256"},
            {"name": "hashlock", "type": "bytes32"},
            {"name": "timelock", "type": "uint256"},
            {"name": "claimed", "type": "bool"},
            {"name": "refunded", "type": "bool"}
        ],
        "stateMutability": "view",
        "type": "function"
    }
]


def reverse_bytes32(hex_str: str) -> str:
    """
    Reverse byte order of a 32-byte hex string.

    CRITICAL: BATHRON uses Bitcoin-style display (reversed from internal bytes).
    Polygon expects bytes in natural order for sha256 verification.

    BATHRON display format: bebed079...
    EVM format (reversed): 767fd860...
    """
    clean = hex_str.replace('0x', '')
    if len(clean) != 64:
        log.error(f"reverse_bytes32: expected 64 hex chars, got {len(clean)}")
        return hex_str
    # Reverse byte order (2 hex chars per byte)
    reversed_bytes = bytes.fromhex(clean)[::-1]
    return reversed_bytes.hex()


class BATHRONRPC:
    """Simple BATHRON RPC client"""

    def __init__(self, host: str, port: int, user: str, password: str):
        self.url = f"http://{host}:{port}"
        self.auth = (user, password)
        self.id = 0

    def call(self, method: str, params: list = None) -> Any:
        self.id += 1
        payload = {
            "jsonrpc": "2.0",
            "id": self.id,
            "method": method,
            "params": params or []
        }
        try:
            resp = requests.post(self.url, json=payload, auth=self.auth, timeout=30)
            result = resp.json()
            if "error" in result and result["error"]:
                raise Exception(f"RPC error: {result['error']}")
            return result.get("result")
        except requests.exceptions.RequestException as e:
            log.error(f"RPC connection error: {e}")
            raise

    def getblockcount(self) -> int:
        return self.call("getblockcount")

    def getblockhash(self, height: int) -> str:
        return self.call("getblockhash", [height])

    def getblock(self, blockhash: str, verbosity: int = 2) -> dict:
        return self.call("getblock", [blockhash, verbosity])

    def htlc_list(self) -> list:
        return self.call("htlc_list")

    def getrawtransaction(self, txid: str, verbose: bool = True) -> dict:
        return self.call("getrawtransaction", [txid, verbose])


class PolygonClaimer:
    """Handles claiming USDC on Polygon"""

    def __init__(self, rpc_url: str, contract_address: str, private_key: str, chain_id: int = 137):
        try:
            from web3 import Web3
            from eth_account import Account
        except ImportError:
            log.error("web3 not installed. Run: pip install web3")
            raise

        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(contract_address),
            abi=HTLC_ABI
        )
        self.account = Account.from_key(private_key)
        self.chain_id = chain_id
        log.info(f"Polygon claimer initialized. LP address: {self.account.address}")

    def get_swap(self, swap_id: bytes) -> Optional[Dict]:
        """Get swap details from contract"""
        try:
            result = self.contract.functions.swaps(swap_id).call()
            return {
                "lp": result[0],
                "taker": result[1],
                "token": result[2],
                "amount": result[3],
                "hashlock": result[4].hex(),
                "timelock": result[5],
                "claimed": result[6],
                "refunded": result[7]
            }
        except Exception as e:
            log.error(f"Error getting swap: {e}")
            return None

    def claim(self, swap_id: str, preimage: str) -> Optional[str]:
        """Claim USDC from HTLC contract"""
        try:
            # CRITICAL: Convert BATHRON byte order to EVM byte order
            # BATHRON displays hashes in reversed format (Bitcoin-style)
            # Polygon expects natural byte order for sha256 verification
            swap_id_evm = reverse_bytes32(swap_id)
            preimage_evm = reverse_bytes32(preimage)

            log.info(f"Byte order conversion:")
            log.info(f"  BATHRON swap_id:  {swap_id[:16]}...")
            log.info(f"  EVM swap_id:   {swap_id_evm[:16]}...")
            log.info(f"  BATHRON preimage: {preimage[:16]}...")
            log.info(f"  EVM preimage:  {preimage_evm[:16]}...")

            # Convert to bytes32
            swap_id_bytes = bytes.fromhex(swap_id_evm)
            preimage_bytes = bytes.fromhex(preimage_evm)

            # Check if already claimed
            swap = self.get_swap(swap_id_bytes)
            if not swap:
                log.warning(f"Swap {swap_id[:16]}... not found")
                return None
            if swap["claimed"]:
                log.info(f"Swap {swap_id[:16]}... already claimed")
                return "already_claimed"
            if swap["refunded"]:
                log.warning(f"Swap {swap_id[:16]}... was refunded")
                return None

            # Build transaction
            nonce = self.w3.eth.get_transaction_count(self.account.address)
            gas_price = self.w3.eth.gas_price

            tx = self.contract.functions.claim(
                swap_id_bytes,
                preimage_bytes
            ).build_transaction({
                'from': self.account.address,
                'nonce': nonce,
                'gas': 100000,
                'gasPrice': gas_price,
                'chainId': self.chain_id
            })

            # Sign and send
            signed = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)

            log.info(f"Claim TX sent: {tx_hash.hex()}")

            # Wait for confirmation
            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

            if receipt['status'] == 1:
                log.info(f"Claim SUCCESS! TX: {tx_hash.hex()}")
                return tx_hash.hex()
            else:
                log.error(f"Claim FAILED! TX: {tx_hash.hex()}")
                return None

        except Exception as e:
            log.error(f"Claim error: {e}")
            return None


class LPBot:
    """Main LP Bot class"""

    def __init__(self, config: dict):
        self.config = config
        self.state_file = Path(config.get("state_file", "lp_bot_state.json"))
        self.state = self.load_state()

        # Initialize BATHRON RPC
        bathron_cfg = config["bathron_rpc"]
        self.bathron = BATHRONRPC(
            bathron_cfg["host"],
            bathron_cfg["port"],
            bathron_cfg["user"],
            bathron_cfg["password"]
        )

        # Initialize Polygon claimer (if private key provided)
        poly_cfg = config["polygon"]
        lp_cfg = config.get("lp_wallet", {})
        private_key = lp_cfg.get("private_key", "")

        if private_key:
            self.claimer = PolygonClaimer(
                poly_cfg["rpc_url"],
                poly_cfg["htlc_contract"],
                private_key,
                poly_cfg.get("chain_id", 137)
            )
        else:
            self.claimer = None
            log.warning("No LP private key configured - will only monitor, not claim")

    def load_state(self) -> dict:
        """Load bot state from file"""
        if self.state_file.exists():
            try:
                return json.loads(self.state_file.read_text())
            except:
                pass
        return {
            "last_height": 0,
            "claimed_swaps": [],
            "pending_claims": []
        }

    def save_state(self):
        """Save bot state to file"""
        self.state_file.write_text(json.dumps(self.state, indent=2))

    def scan_block(self, height: int) -> list:
        """Scan a block for htlc_claim transactions"""
        revealed = []

        try:
            blockhash = self.bathron.getblockhash(height)
            block = self.bathron.getblock(blockhash, 2)

            for tx in block.get("tx", []):
                # Look for htlc_claim in vout OP_RETURN or special markers
                # The preimage is revealed in the scriptSig of the claim TX

                # Check if this TX spends an HTLC output
                for vin in tx.get("vin", []):
                    if "scriptSig" in vin:
                        scriptsig = vin["scriptSig"].get("hex", "")
                        # HTLC claim scriptSig contains the preimage
                        # Format: <sig> <preimage> <1> <redeemscript>
                        # The preimage is 32 bytes (64 hex chars)

                        # Try to extract preimage from scriptSig
                        preimage = self.extract_preimage_from_scriptsig(scriptsig)
                        if preimage:
                            log.info(f"Found revealed preimage in TX {tx['txid']}: {preimage[:16]}...")
                            revealed.append({
                                "txid": tx["txid"],
                                "preimage": preimage,
                                "height": height
                            })

        except Exception as e:
            log.error(f"Error scanning block {height}: {e}")

        return revealed

    def extract_preimage_from_scriptsig(self, scriptsig_hex: str) -> Optional[str]:
        """Extract preimage from HTLC claim scriptSig"""
        # HTLC claim scriptSig format (simplified):
        # <signature> <preimage_32bytes> <OP_TRUE> <redeemscript>
        # We look for a 32-byte (64 hex char) push that could be the preimage

        try:
            data = bytes.fromhex(scriptsig_hex)
            pos = 0

            while pos < len(data):
                # Read push length
                push_len = data[pos]
                pos += 1

                if push_len == 0:
                    continue

                if push_len <= 75:
                    # Direct push
                    if push_len == 32:
                        # This could be the preimage!
                        preimage = data[pos:pos+32].hex()
                        pos += push_len

                        # Verify it's likely a preimage (not all zeros, not a pubkey, etc.)
                        if preimage != "0" * 64 and not preimage.startswith("02") and not preimage.startswith("03"):
                            return preimage
                    else:
                        pos += push_len
                elif push_len == 76:  # OP_PUSHDATA1
                    actual_len = data[pos]
                    pos += 1 + actual_len
                elif push_len == 77:  # OP_PUSHDATA2
                    actual_len = int.from_bytes(data[pos:pos+2], 'little')
                    pos += 2 + actual_len
                else:
                    # OP code, skip
                    pass

        except Exception as e:
            pass

        return None

    def check_htlc_list(self) -> list:
        """Check htlc_list for claimed lots with revealed preimages"""
        revealed = []

        try:
            lots = self.bathron.htlc_list()
            for lot in lots:
                if lot.get("status") == "claimed" and lot.get("preimage"):
                    preimage = lot["preimage"]
                    hashlock = lot["hashlock"]

                    # Skip if already processed
                    if hashlock in self.state["claimed_swaps"]:
                        continue

                    log.info(f"Found claimed LOT with preimage: {preimage[:16]}...")
                    revealed.append({
                        "hashlock": hashlock,
                        "preimage": preimage,
                        "lot": lot
                    })

        except Exception as e:
            log.error(f"Error checking htlc_list: {e}")

        return revealed

    def process_revealed_preimage(self, hashlock: str, preimage: str) -> bool:
        """Process a revealed preimage - claim on Polygon"""

        # SwapId = hashlock (we use hashlock as swapId in our implementation)
        swap_id = hashlock

        log.info(f"Processing claim for swapId: {swap_id[:16]}...")
        log.info(f"Preimage: {preimage}")

        if not self.claimer:
            log.warning("No claimer configured - skipping Polygon claim")
            self.state["claimed_swaps"].append(hashlock)
            self.save_state()
            return False

        # Claim on Polygon
        result = self.claimer.claim(swap_id, preimage)

        if result:
            log.info(f"Successfully claimed USDC for swap {swap_id[:16]}...")
            self.state["claimed_swaps"].append(hashlock)
            self.save_state()
            return True
        else:
            log.error(f"Failed to claim USDC for swap {swap_id[:16]}...")
            return False

    def run_once(self):
        """Run one iteration of the bot"""
        log.info("Checking for revealed preimages...")

        # Method 1: Check htlc_list for claimed lots
        revealed = self.check_htlc_list()

        for item in revealed:
            self.process_revealed_preimage(item["hashlock"], item["preimage"])

        if not revealed:
            log.info("No new preimages found")

    def run(self):
        """Main bot loop"""
        log.info("LP Bot starting...")
        poll_interval = self.config.get("poll_interval", 10)

        while True:
            try:
                self.run_once()
            except KeyboardInterrupt:
                log.info("Shutting down...")
                break
            except Exception as e:
                log.error(f"Error in main loop: {e}")

            time.sleep(poll_interval)


def main():
    parser = argparse.ArgumentParser(description="LP Bot - HTLC USDC Claimer")
    parser.add_argument("--config", "-c", default="lp_bot_config.json", help="Config file path")
    parser.add_argument("--once", action="store_true", help="Run once and exit")
    parser.add_argument("--claim", metavar="PREIMAGE", help="Manually claim with preimage")
    parser.add_argument("--swap-id", metavar="SWAPID", help="SwapId for manual claim (default: use hashlock)")
    args = parser.parse_args()

    # Load config
    config_path = Path(args.config)
    if config_path.exists():
        config = json.loads(config_path.read_text())
        log.info(f"Loaded config from {config_path}")
    else:
        config = DEFAULT_CONFIG.copy()
        log.warning(f"Config file not found, using defaults")
        # Save default config
        config_path.write_text(json.dumps(config, indent=2))
        log.info(f"Saved default config to {config_path}")

    # Manual claim mode
    if args.claim:
        preimage_bathron = args.claim  # In BATHRON display format

        if not args.swap_id:
            log.error("--swap-id required! Use the swapId from the Polygon lock TX")
            log.info("The swapId should be the EVM-format hashlock (reversed from BATHRON display)")
            return 1

        swap_id_bathron = args.swap_id  # In BATHRON display format (hashlock from htlc_list)

        if not config.get("lp_wallet", {}).get("private_key"):
            log.error("No LP private key in config!")
            return 1

        poly_cfg = config["polygon"]
        lp_cfg = config["lp_wallet"]

        claimer = PolygonClaimer(
            poly_cfg["rpc_url"],
            poly_cfg["htlc_contract"],
            lp_cfg["private_key"],
            poly_cfg.get("chain_id", 137)
        )

        log.info(f"BATHRON Preimage: {preimage_bathron}")
        log.info(f"BATHRON SwapId:   {swap_id_bathron}")
        log.info("(Byte order will be reversed for Polygon)")

        # The claim function handles byte order conversion internally
        result = claimer.claim(swap_id_bathron, preimage_bathron)
        return 0 if result else 1

    # Run bot
    bot = LPBot(config)

    if args.once:
        bot.run_once()
    else:
        bot.run()

    return 0


if __name__ == "__main__":
    exit(main())
