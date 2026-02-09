# PIV2 Explorer Configuration

## Deployment

**Server**: Seed node (57.131.33.151)
**URL**: http://57.131.33.151:3001/
**Technology**: PHP built-in server (php -S)

## Local Files (source of truth)

```
contrib/explorer/
├── piv2-explorer.php   # Main explorer script
├── easybitcoin.php     # Bitcoin RPC library
├── logo.png            # PIVX logo
├── favicon.png         # Browser favicon
├── deploy_explorer.sh  # Deploy & restart script
└── EXPLORER.md         # This file
```

## Quick Deploy

```bash
# From PIV2-Core root
./contrib/explorer/deploy_explorer.sh
```

This script:
1. Copies all files to VPS (~/explorer/)
2. Stops existing PHP server
3. Starts new PHP server on port 3001
4. Verifies deployment

## Configuration (in piv2-explorer.php)

```php
// RPC Connection
const RPC_HOST = '127.0.0.1';
const RPC_PORT = 27170;        // Testnet RPC port
const RPC_USER = 'testuser';
const RPC_PASS = 'testpass123';

// Display
const COIN_NAME = 'PIVX 2.0';
const COIN_TICKER = 'PIV2';
const NETWORK = 'Testnet';
const BLOCKS_PER_LIST = 15;    // Blocks shown per page
const REFRESH_TIME = 30;       // Auto-refresh interval (seconds)
```

## Start/Stop Commands

```bash
# SSH to Seed
ssh -i ~/.ssh/id_ed25519_vps ubuntu@57.131.33.151

# Start explorer (from explorer directory)
cd ~/PIV2-Core/contrib/explorer
nohup php -S 0.0.0.0:3001 > /dev/null 2>&1 &

# Check if running
ss -tlnp | grep 3001
# or
pgrep -f "php -S.*3001"

# Stop explorer
pkill -f "php -S.*3001"

# View logs (if needed)
php -S 0.0.0.0:3001 2>&1 | tee explorer.log
```

## Deploy Updates

```bash
# From local machine - pull latest code on Seed
ssh -i ~/.ssh/id_ed25519_vps ubuntu@57.131.33.151 "cd ~/PIV2-Core && git pull"

# Restart explorer to apply changes
ssh -i ~/.ssh/id_ed25519_vps ubuntu@57.131.33.151 "pkill -f 'php -S.*3001'; cd ~/PIV2-Core/contrib/explorer && nohup php -S 0.0.0.0:3001 > /dev/null 2>&1 &"
```

## Features

- **Home page**: Network stats + latest blocks (auto-refresh)
- **Block view**: Block details + transactions
- **Transaction view**: Inputs/outputs with values
- **Address view**: Balance + transaction history (scans last 100 blocks)
- **Search**: By block hash, tx hash, block height, or address

## Auto-Refresh

- Enabled only on home page (`$page === 'home'`)
- Uses `<meta http-equiv="refresh">` (full page reload)
- Interval: 30 seconds (configurable via `REFRESH_TIME`)

## Troubleshooting

### Explorer not loading
```bash
# Check if PHP server is running
ssh -i ~/.ssh/id_ed25519_vps ubuntu@57.131.33.151 "ss -tlnp | grep 3001"

# Check if daemon is running
ssh -i ~/.ssh/id_ed25519_vps ubuntu@57.131.33.151 "~/piv2-cli -testnet getblockcount"
```

### RPC errors
- Verify daemon is running on Seed
- Check RPC credentials match piv2.conf
- Testnet RPC port: 27170

### Port 3001 not accessible
- Check firewall: `sudo ufw status`
- Allow port: `sudo ufw allow 3001/tcp`
