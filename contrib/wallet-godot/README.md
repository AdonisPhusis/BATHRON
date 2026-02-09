# PIV2 Wallet (Godot)

Lightweight wallet GUI for PIVX 2.0 — **Thin client architecture**.

## Architecture

```
┌─────────────────────┐                    ┌─────────────────────┐
│   PIV2 Wallet       │   JSON-RPC         │      piv2d          │
│   (this app)        │◄──────────────────►│   (daemon)          │
│                     │   localhost:51475   │                     │
│ ❌ NO wallet.dat    │                    │ ✅ wallet.dat       │
│ ❌ NO private keys  │                    │ ✅ private keys     │
└─────────────────────┘                    └─────────────────────┘
```

**Security:** All sensitive data stays on the daemon. This wallet is just a GUI.

## Requirements

- piv2d daemon running (locally or remote)
- For local: automatic cookie authentication
- For remote: RPC username/password + HTTPS

## Build from Source

```bash
# Install Godot 4.3+
# On macOS: brew install godot
# On Linux: download from godotengine.org

# Export for your platform
cd contrib/wallet-godot
godot --headless --export-release "macOS" export/piv2-wallet.zip
godot --headless --export-release "Linux" export/piv2-wallet.x86_64
godot --headless --export-release "Windows" export/piv2-wallet.exe
```

## Pre-built Binaries

Export size: ~50 MB per platform

| Platform | File | Notes |
|----------|------|-------|
| macOS | piv2-wallet.zip | Universal (Intel + M1/M2/M3/M4) |
| Linux | piv2-wallet.x86_64 | x86_64, glibc 2.17+ |
| Windows | piv2-wallet.exe | Windows 10+ |

## Usage

1. Start piv2d daemon:
   ```bash
   piv2d -daemon
   # or for testnet:
   piv2d -testnet -daemon
   ```

2. Launch PIV2 Wallet (double-click or run from terminal)

3. Wallet auto-connects via cookie auth (localhost)

## Features

- **Balance Display:** M0 (spendable) and M1 (locked receipts)
- **Lock:** Convert M0 → M1 (creates settlement receipt)
- **Unlock:** Convert M1 → M0 (redeems receipt)
- **Receipts List:** View all M1 receipts with outpoints
- **Network Status:** Block height, peer count

## Configuration

Settings stored in `user://settings.cfg`:
- RPC host/port
- UI theme
- Refresh interval

**NEVER stored:** passwords, passphrases, private keys

## Development

```bash
# Open in Godot Editor
godot project.godot

# Run in editor
F5

# Export all platforms
godot --headless --export-release "macOS" export/piv2-wallet.zip
godot --headless --export-release "Linux" export/piv2-wallet.x86_64
godot --headless --export-release "Windows" export/piv2-wallet.exe
```

## License

MIT License - Same as PIVX 2.0
