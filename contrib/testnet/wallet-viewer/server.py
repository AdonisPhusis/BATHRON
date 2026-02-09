#!/usr/bin/env python3
"""
Wallet Viewer Server for Fake User (OP3)
Serves HTML + API endpoints for balance queries
"""

import json
import subprocess
import os
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse

PORT = 8888

# CLI paths
BATHRON_CLI = os.path.expanduser("~/bathron-cli")
if not os.path.exists(BATHRON_CLI):
    BATHRON_CLI = os.path.expanduser("~/BATHRON-Core/src/bathron-cli")

BTC_CLI = os.path.expanduser("~/bitcoin/bin/bitcoin-cli")
BTC_ARGS = ["-signet", f"-datadir={os.path.expanduser('~/.bitcoin-signet')}"]

EVM_WALLET_PATH = os.path.expanduser("~/.keys/user_evm.json")


def run_cmd(cmd, timeout=10):
    """Run command and return output"""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.stdout.strip(), result.returncode == 0
    except subprocess.TimeoutExpired:
        return "Timeout", False
    except Exception as e:
        return str(e), False


def get_bathron_balances():
    """Get M0 and M1 balances from BATHRON using getwalletstate"""
    output, ok = run_cmd([BATHRON_CLI, "-testnet", "getwalletstate", "true"])

    if not ok:
        return {"m0": "Error", "m1": "Error"}

    try:
        data = json.loads(output)
        # Structure: { "m0": { "balance": X }, "m1": { "total": Y } }
        m0 = data.get("m0", {}).get("balance", 0)
        m1 = data.get("m1", {}).get("total", 0)

        # Format with thousands separator
        m0_fmt = f"{m0:,}" if isinstance(m0, (int, float)) else str(m0)
        m1_fmt = f"{m1:,}" if isinstance(m1, (int, float)) else str(m1)

        return {"m0": m0_fmt, "m1": m1_fmt}
    except json.JSONDecodeError:
        # Fallback to simple getbalance
        m0_out, _ = run_cmd([BATHRON_CLI, "-testnet", "getbalance"])
        return {"m0": m0_out, "m1": "0"}


def get_btc_balance():
    """Get BTC balance from Bitcoin Signet"""
    bal, ok = run_cmd([BTC_CLI] + BTC_ARGS + ["getbalance"])

    if not ok:
        # Try with wallet name
        bal, ok = run_cmd([BTC_CLI] + BTC_ARGS + ["-rpcwallet=fake_user", "getbalance"])

    return {"balance": bal if ok else "Not running"}


def get_evm_address():
    """Get EVM wallet address from stored file"""
    try:
        with open(EVM_WALLET_PATH, 'r') as f:
            data = json.load(f)
            return {"address": data.get("address")}
    except FileNotFoundError:
        return {"address": None, "error": "Wallet not configured"}
    except Exception as e:
        return {"address": None, "error": str(e)}


class WalletViewerHandler(SimpleHTTPRequestHandler):
    """HTTP handler with API endpoints"""

    def __init__(self, *args, **kwargs):
        # Serve from the script's directory
        super().__init__(*args, directory=os.path.dirname(os.path.abspath(__file__)), **kwargs)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        # API endpoints
        if path == '/api/bathron-balances':
            self.send_json(get_bathron_balances())
        elif path == '/api/btc-balance':
            self.send_json(get_btc_balance())
        elif path == '/api/evm-address':
            self.send_json(get_evm_address())
        elif path == '/api/status':
            self.send_json({"status": "ok", "service": "wallet-viewer"})
        elif path == '/' or path == '/index.html':
            # Serve index.html
            super().do_GET()
        else:
            # Let SimpleHTTPRequestHandler handle static files
            super().do_GET()

    def send_json(self, data):
        """Send JSON response"""
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def log_message(self, format, *args):
        """Custom logging"""
        print(f"[WalletViewer] {args[0]}")


def main():
    print(f"""
╔══════════════════════════════════════════════════════════════╗
║           WALLET VIEWER SERVER                               ║
╠══════════════════════════════════════════════════════════════╣
║  Port:     {PORT}                                              ║
║  URL:      http://51.75.31.44:{PORT}/                          ║
╚══════════════════════════════════════════════════════════════╝
""")

    print(f"BATHRON CLI: {BATHRON_CLI}")
    print(f"BTC CLI:     {BTC_CLI}")
    print(f"EVM Wallet:  {EVM_WALLET_PATH}")
    print()

    server = HTTPServer(('0.0.0.0', PORT), WalletViewerHandler)
    print(f"Server running on port {PORT}...")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == '__main__':
    main()
