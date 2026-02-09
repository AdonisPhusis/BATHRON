# DEX Demo + SDK Architecture Plan

## Vue d'Ensemble

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        Core+SDK VPS (162.19.251.75)                       │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│   ┌──────────────────┐      ┌──────────────────┐      ┌──────────────┐   │
│   │   DEX Website    │      │    SDK Server    │      │   bathrond      │   │
│   │   (Port 3002)    │◄────►│   (Port 8080)    │◄────►│   (RPC)      │   │
│   │   PHP/HTML/JS    │      │   Python Flask   │      │   Port 27170 │   │
│   └────────┬─────────┘      └────────┬─────────┘      └──────────────┘   │
│            │                         │                                    │
│            │                         │                                    │
│            ▼                         ▼                                    │
│   ┌──────────────────────────────────────────────────────────────────┐   │
│   │                      Retail Browser                               │   │
│   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐   │   │
│   │  │  MetaMask   │  │ SecretVault │  │  Orderbook UI (React)   │   │   │
│   │  │  (Polygon)  │  │ (IndexedDB) │  │  Binance-style          │   │   │
│   │  └─────────────┘  └─────────────┘  └─────────────────────────┘   │   │
│   └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Web3/ethers.js
                                    ▼
                    ┌──────────────────────────────┐
                    │       Polygon Mainnet        │
                    │  ┌────────────────────────┐  │
                    │  │  HTLC Contract         │  │
                    │  │  0x3F18...fA5F         │  │
                    │  ├────────────────────────┤  │
                    │  │  USDC Contract         │  │
                    │  │  0x3c49...3359         │  │
                    │  └────────────────────────┘  │
                    └──────────────────────────────┘
```

---

## 1. Communication SDK ↔ DEX

### 1.1 SDK Server (Python Flask)

Le SDK expose une API REST pour le DEX frontend:

```
GET  /api/lots              → Récupère les LOTs depuis bathrond (lot_list)
GET  /api/lot/<lot_id>      → Détails d'un LOT (lot_get)
GET  /api/orderbook         → Orderbook formaté (asks/bids groupés par prix)
GET  /api/swap/<hashlock>   → État d'un swap (BATHRON + Polygon)
POST /api/register_swap     → Enregistre un swap (hashlock + taker_addr)
GET  /api/price             → Prix KPIV/USDC spot (de lot_list)
```

### 1.2 Flux de Données

```
┌────────────┐     ┌────────────┐     ┌────────────┐     ┌────────────┐
│   DEX UI   │────►│ SDK Server │────►│  bathron-cli  │────►│   bathrond    │
│            │◄────│            │◄────│            │◄────│            │
└────────────┘     └────────────┘     └────────────┘     └────────────┘
      │                  │
      │                  │ (polling)
      ▼                  ▼
┌────────────┐     ┌────────────┐
│  MetaMask  │     │  Polygon   │
│  (direct)  │────►│   RPC      │
└────────────┘     └────────────┘
```

---

## 2. Structure des Fichiers

```
162.19.251.75:/home/ubuntu/
├── BATHRON-Core/                    # Node + binaries (existant)
│   └── src/
│       ├── bathrond
│       └── bathron-cli
│
├── dex-demo/                     # Site DEX (NOUVEAU)
│   ├── index.php                 # Router principal
│   ├── pages/
│   │   ├── trade.php             # Page principale (orderbook)
│   │   └── portfolio.php         # Historique swaps
│   │
│   ├── css/
│   │   └── style.css             # Binance dark theme
│   │
│   ├── js/
│   │   ├── app.js                # Logique principale
│   │   ├── orderbook.js          # Rendu orderbook
│   │   ├── metamask.js           # MetaMask integration
│   │   ├── htlc.js               # Interactions HTLC (ethers.js)
│   │   └── vault.js              # SecretVault (WebCrypto + IndexedDB)
│   │
│   └── api/
│       └── proxy.php             # Proxy vers SDK Server
│
└── sdk/                          # SDK Services (NOUVEAU)
    ├── server.py                 # API Flask principale
    ├── lp_watcher.py             # LP automation (existant, déplacé)
    ├── swap_monitor.py           # Monitor swaps en cours
    ├── config.py                 # Configuration
    └── requirements.txt          # Dépendances Python
```

---

## 3. Pages de Démonstration

### 3.1 Page Trade (Orderbook Binance-style)

```
┌─────────────────────────────────────────────────────────────────────────┐
│  ┌─────────────────────────┐                                            │
│  │  KPIV/USDC    ▼  KPIV/BTC (disabled)                                │
│  └─────────────────────────┘                                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌───────────────────────────┐    ┌────────────────────────────────┐   │
│  │       ORDERBOOK           │    │         SWAP PANEL              │   │
│  │                           │    │                                 │   │
│  │  Price     Size    Total  │    │  ┌──────────────────────────┐  │   │
│  │  ────────────────────────│    │  │ 🦊 Connect MetaMask      │  │   │
│  │  0.0510   1,250   1,250  │    │  │    0x7348...B9 ✓        │  │   │
│  │  0.0505     800   2,050  │    │  │    142.50 USDC           │  │   │
│  │  0.0502     500   2,550  │    │  └──────────────────────────┘  │   │
│  │  ─────── SPREAD 0.3% ────│    │                                 │   │
│  │  0.0498     300   2,850  │    │  Amount KPIV:                   │   │
│  │  0.0495     700   3,550  │    │  ┌──────────────────────────┐  │   │
│  │  0.0490   1,000   4,550  │    │  │ 100                      │  │   │
│  │                           │    │  └──────────────────────────┘  │   │
│  │  ────────────────────────│    │                                 │   │
│  │  Best Ask: 0.0502 USDC    │    │  Your BATHRON Address:            │   │
│  │  Best Bid: 0.0498 USDC    │    │  ┌──────────────────────────┐  │   │
│  │  24h Volume: 15,420 KPIV  │    │  │ y7XRqXgz1d8ELErDxt...   │  │   │
│  └───────────────────────────┘    │  └──────────────────────────┘  │   │
│                                    │                                 │   │
│                                    │  ═════════════════════════════  │   │
│                                    │  You Pay:      5.02 USDC       │   │
│                                    │  You Receive:  100 KPIV        │   │
│                                    │  Price:        0.0502/KPIV     │   │
│                                    │  Network:      Polygon         │   │
│                                    │  ═════════════════════════════  │   │
│                                    │                                 │   │
│                                    │  ┌──────────────────────────┐  │   │
│                                    │  │     🔒 LOCK USDC         │  │   │
│                                    │  │     (Creates HTLC)       │  │   │
│                                    │  └──────────────────────────┘  │   │
│                                    │                                 │   │
│                                    │  Status: Ready                  │   │
│                                    └────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Page Portfolio (Swaps History)

```
┌─────────────────────────────────────────────────────────────────────────┐
│  MY SWAPS                                                       Refresh │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ ACTIVE SWAPS                                                     │   │
│  ├─────────────────────────────────────────────────────────────────┤   │
│  │                                                                   │   │
│  │  Swap #7d3c60...                                       🟡 LOCKED │   │
│  │  ────────────────────────────────────────────────────────────── │   │
│  │  Paying: 10.04 USDC   |   Receiving: 200 KPIV                    │   │
│  │  LP:     0x7348...B9  |   To: y7XRq...ecka                       │   │
│  │  Hashlock: 0x79ae1d3ea1c7bfc226451ab48ee6aa47e3ac3033f7b...     │   │
│  │  Timelock: 2h 45m remaining                                      │   │
│  │                                                                   │   │
│  │  [View on Polygonscan]  [Reveal Secret]  [Cancel/Refund]         │   │
│  │                                                                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ COMPLETED SWAPS                                                  │   │
│  ├─────────────────────────────────────────────────────────────────┤   │
│  │                                                                   │   │
│  │  Swap #3c8920...   100 KPIV @ 0.05   ✓ Completed   Dec 15, 2025  │   │
│  │  Swap #a1b2c3...    50 KPIV @ 0.051  ✓ Completed   Dec 14, 2025  │   │
│  │                                                                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 4. SecretVault (Stockage S Crypté)

### 4.1 Architecture

```javascript
// vault.js - Encrypted secret storage using WebCrypto + IndexedDB

class SecretVault {
    // 1. Generate ECDH key pair on first use (stored in IndexedDB)
    // 2. Derive AES-256-GCM key from ECDH + user password
    // 3. Store secrets encrypted with metadata

    async generateSecret() {
        // Generate 32-byte random preimage (S)
        const S = crypto.getRandomValues(new Uint8Array(32));

        // Calculate hashlock H = SHA256(S)
        const H = await crypto.subtle.digest('SHA-256', S);

        // Encrypt S before storage
        const encryptedS = await this.encrypt(S);

        // Store in IndexedDB with swap metadata
        await this.store({
            hashlock: hex(H),
            encryptedSecret: encryptedS,
            created: Date.now(),
            status: 'pending'
        });

        return { S: hex(S), H: hex(H) };
    }

    async revealSecret(hashlock) {
        // Retrieve and decrypt S for claim operation
        const record = await this.get(hashlock);
        return this.decrypt(record.encryptedSecret);
    }
}
```

### 4.2 Sécurité

- **Isolation**: Chaque domaine a son propre IndexedDB
- **Encryption**: AES-256-GCM avec IV unique par secret
- **Key derivation**: PBKDF2 avec salt aléatoire
- **Pas de transmission**: S reste local jusqu'au claim

---

## 5. Flux ASK - 2-HTLC Trustless (Retail achète KPIV)

**MODÈLE: 2-HTLC (Polygon USDC + BATHRON KPIV)**

Ce modèle est **trustless des deux côtés**:
- Retail génère S, donc contrôle le timing
- LP ne peut claim USDC qu'après que Retail révèle S (en claimant KPIV)
- Aucune partie ne peut grief l'autre sans perdre ses fonds

```
┌────────────┐   ┌────────────┐   ┌────────────┐   ┌────────────┐   ┌────────────┐
│   Retail   │   │  Polygon   │   │  SDK API   │   │    BATHRON    │   │    LP      │
│   Browser  │   │   HTLC     │   │            │   │   HTLC     │   │  Watcher   │
└─────┬──────┘   └─────┬──────┘   └─────┬──────┘   └─────┬──────┘   └─────┬──────┘
      │                │                │                │                │
      │ 1. Generate S, H=SHA256(S)     │                │                │
      │────────────────────────────────►                │                │
      │    (S stored encrypted locally)                │                │
      │                │                │                │                │
      │ 2. Register: H + kpiv_addr     │                │                │
      │────────────────────────────────►                │                │
      │                │                │ (bind_hashlock)│                │
      │                │                │───────────────────────────────►│
      │                │                │                │                │
      │ 3. Lock USDC HTLC              │                │                │
      │    (H, LP_addr, timelock=4h)   │                │                │
      │───────────────►│               │                │                │
      │                │ Locked event  │                │                │
      │                │───────────────────────────────────────────────►│
      │                │                │                │                │
      │                │                │                │ 4. LP verifies │
      │                │                │                │    USDC locked │
      │                │                │                │                │
      │                │                │                │ 5. LP creates  │
      │                │                │                │    KPIV HTLC   │
      │                │                │                │    (H, 2h)     │
      │                │                │                │◄───────────────┤
      │                │                │  htlc_create   │                │
      │◄───────────────────────────────────────────────│                │
      │ (sees KPIV HTLC in orderbook)  │                │                │
      │                │                │                │                │
      │ 6. Retail claims KPIV HTLC     │                │                │
      │    (reveals S on BATHRON chain)   │                │                │
      │────────────────────────────────────────────────►│                │
      │                │                │                │ S visible      │
      │                │                │                │ on-chain       │
      │                │                │                │───────────────►│
      │                │                │                │                │
      │                │ 7. LP extracts S from BATHRON claim tx            │
      │                │◄──────────────────────────────────────────────┤
      │                │                │                │                │
      │                │ 8. LP claims USDC with S       │                │
      │                │◄───────────────────────────────────────────────┤
      │                │                │                │                │
      │ ✓ Swap Complete (both HTLCs claimed)           │                │
      ▼                ▼                ▼                ▼                ▼
```

### 5.1 Timelocks (Safety Margin)

```
USDC HTLC timelock:  4 hours (Retail → LP)
KPIV HTLC timelock:  2 hours (LP → Retail)
                     ↑
         Safety margin: LP has 2h to claim USDC after S is revealed
```

**Règle critique**: `timelock_KPIV < timelock_USDC`

Si Retail claim KPIV (révèle S), LP a encore du temps pour claim USDC.
Si Retail ne claim pas, les deux HTLCs expirent et les fonds sont refundés.

### 5.2 États du Swap

| État | Polygon USDC | BATHRON KPIV | Action |
|------|--------------|-----------|--------|
| REGISTERED | - | - | Retail a enregistré H + addr |
| USDC_LOCKED | Locked | - | LP doit créer KPIV HTLC |
| KPIV_LOCKED | Locked | Locked | Retail peut claim KPIV |
| KPIV_CLAIMED | Locked | Claimed | LP peut claim USDC (S révélé) |
| COMPLETED | Claimed | Claimed | Swap terminé |
| USDC_REFUNDED | Refunded | - | Retail a récupéré USDC |
| KPIV_REFUNDED | Locked | Refunded | LP a récupéré KPIV (timeout) |

### 5.3 Protection Anti-Grief

| Scénario | Résultat | Protection |
|----------|----------|------------|
| Retail lock USDC, LP ne répond pas | USDC refund après 4h | Timelock |
| LP lock KPIV, Retail ne claim pas | KPIV refund après 2h | Timelock |
| Retail claim KPIV mais LP offline | LP peut claim USDC plus tard | S on-chain |
| Double-spend attempt | Confirmations requises | 6 blocks BATHRON |

---

## 6. API SDK Détaillée

### 6.1 Endpoints

```python
# server.py - SDK API

from flask import Flask, jsonify, request
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

@app.route('/api/orderbook')
def get_orderbook():
    """
    Returns formatted orderbook from LOTs

    Response:
    {
        "pair": "KPIV/USDC",
        "timestamp": 1734372000,
        "asks": [
            {"price": 0.0502, "size": 500, "total": 500, "lot_id": "abc123..."},
            {"price": 0.0505, "size": 800, "total": 1300, "lot_id": "def456..."}
        ],
        "bids": [
            {"price": 0.0498, "size": 300, "total": 300, "lot_id": "ghi789..."},
            {"price": 0.0495, "size": 700, "total": 1000, "lot_id": "jkl012..."}
        ],
        "spread": 0.0004,
        "spread_pct": 0.80
    }
    """
    lots = bathron_rpc('lot_list')
    return jsonify(format_orderbook(lots, 'KPIV/USDC'))

@app.route('/api/swap/<hashlock>')
def get_swap_status(hashlock):
    """
    Returns unified swap state (BATHRON + Polygon)

    Response:
    {
        "hashlock": "0x79ae1d3e...",
        "state": "LOCKED",

        "polygon": {
            "locked": true,
            "amount_usdc": 10.04,
            "timelock": 1734375600,
            "time_remaining": 9900,
            "tx_hash": "0xabc123...",
            "claimed": false,
            "refunded": false
        },

        "bathron": {
            "kpiv_sent": true,
            "amount_kpiv": 200,
            "tx_hash": "abc123def...",
            "confirmations": 3
        },

        "next_action": "REVEAL_SECRET",
        "next_action_by": "TAKER"
    }
    """
    return jsonify(get_unified_swap_state(hashlock))

@app.route('/api/register_swap', methods=['POST'])
def register_swap():
    """
    Register a new swap (taker address for LP)

    Request:
    {
        "hashlock": "0x79ae1d3e...",
        "taker_kpiv_addr": "y7XRqXgz1d8...",
        "lot_id": "abc123..."
    }
    """
    data = request.json
    # Store in pending_swaps for LP watcher
    return jsonify({"success": True, "swap_id": data['hashlock'][:16]})
```

### 6.2 Communication avec bathrond

```python
# Dans server.py

import subprocess
import json

BATHRON_CLI = "/home/ubuntu/BATHRON-Core/src/bathron-cli"

def bathron_rpc(method, *args):
    """Execute bathron-cli RPC call"""
    cmd = [BATHRON_CLI, "-testnet", method] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise Exception(f"RPC error: {result.stderr}")
    return json.loads(result.stdout)

# Usage examples:
# lots = bathron_rpc('lot_list')
# balance = bathron_rpc('getbalances')
# tx = bathron_rpc('sendtoaddress', taker_addr, str(amount))
```

---

## 7. HTLC Contract Polygon

### 7.1 Interface

```solidity
// Deployed at 0x3F1843Bc98C526542d6112448842718adc13fA5F

interface ISimpleHTLC {
    event Locked(
        bytes32 indexed swapId,
        address indexed sender,
        address indexed recipient,
        address token,
        uint256 amount,
        bytes32 hashlock,
        uint256 timelock
    );

    event Claimed(bytes32 indexed swapId, bytes32 preimage);
    event Refunded(bytes32 indexed swapId);

    function lock(
        address recipient,
        address token,
        uint256 amount,
        bytes32 hashlock,
        uint256 timelock
    ) external returns (bytes32 swapId);

    function claim(bytes32 swapId, bytes32 preimage) external;
    function refund(bytes32 swapId) external;

    function swaps(bytes32 swapId) external view returns (
        address sender,
        address recipient,
        address token,
        uint256 amount,
        bytes32 hashlock,
        uint256 timelock,
        bool withdrawn,
        bool refunded
    );
}
```

### 7.2 Interaction JavaScript

```javascript
// htlc.js

const HTLC_ADDRESS = "0x3F1843Bc98C526542d6112448842718adc13fA5F";
const USDC_ADDRESS = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359";

async function lockUSDC(lpAddress, amountUsdc, hashlock, timelockSeconds) {
    const provider = new ethers.BrowserProvider(window.ethereum);
    const signer = await provider.getSigner();

    // 1. Approve USDC
    const usdc = new ethers.Contract(USDC_ADDRESS, ERC20_ABI, signer);
    const amountWei = ethers.parseUnits(amountUsdc.toString(), 6);
    await usdc.approve(HTLC_ADDRESS, amountWei);

    // 2. Lock in HTLC
    const htlc = new ethers.Contract(HTLC_ADDRESS, HTLC_ABI, signer);
    const timelock = Math.floor(Date.now() / 1000) + timelockSeconds;

    const tx = await htlc.lock(
        lpAddress,
        USDC_ADDRESS,
        amountWei,
        hashlock,
        timelock
    );

    const receipt = await tx.wait();
    return receipt;
}

async function claimHTLC(swapId, preimage) {
    const provider = new ethers.BrowserProvider(window.ethereum);
    const signer = await provider.getSigner();
    const htlc = new ethers.Contract(HTLC_ADDRESS, HTLC_ABI, signer);

    const tx = await htlc.claim(swapId, preimage);
    return await tx.wait();
}
```

---

## 8. Déploiement

### 8.1 Commandes

```bash
# Sur Core+SDK VPS (162.19.251.75)

# 1. Créer la structure
mkdir -p ~/dex-demo/{pages,css,js,api}
mkdir -p ~/sdk

# 2. Copier les fichiers
# (déploiement via scp depuis local)

# 3. Installer dépendances Python
cd ~/sdk
pip3 install flask flask-cors web3 requests

# 4. Démarrer les services
cd ~/sdk && nohup python3 server.py > /tmp/sdk.log 2>&1 &
cd ~/dex-demo && nohup php -S 0.0.0.0:3002 > /tmp/dex.log 2>&1 &
cd ~/sdk && nohup python3 lp_watcher.py > /tmp/lp_watcher.log 2>&1 &
```

### 8.2 Script de déploiement

Créer `contrib/testnet/deploy_dex.sh`:

```bash
#!/bin/bash
# Deploy DEX demo to Core+SDK VPS

CORE_SDK_IP="162.19.251.75"
SSH="ssh -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no"
SCP="scp -i ~/.ssh/id_ed25519_vps -o StrictHostKeyChecking=no"

# Stop services
$SSH ubuntu@$CORE_SDK_IP "pkill -f 'php.*3002' 2>/dev/null; pkill -f 'python.*server.py' 2>/dev/null"

# Copy files
$SCP -r contrib/dex-demo/* ubuntu@$CORE_SDK_IP:~/dex-demo/
$SCP -r contrib/sdk/* ubuntu@$CORE_SDK_IP:~/sdk/

# Start services
$SSH ubuntu@$CORE_SDK_IP "cd ~/sdk && nohup python3 server.py > /tmp/sdk.log 2>&1 &"
$SSH ubuntu@$CORE_SDK_IP "cd ~/dex-demo && nohup php -S 0.0.0.0:3002 > /tmp/dex.log 2>&1 &"

echo "DEX deployed: http://$CORE_SDK_IP:3002/"
```

---

## 9. Roadmap

### Phase 1 - MVP (Maintenant)
- [ ] SDK Server basique (lot_list, orderbook)
- [ ] Page Trade avec orderbook
- [ ] MetaMask connection
- [ ] SecretVault (génération S/H)
- [ ] Lock USDC flow

### Phase 2 - LP Automation
- [ ] LP Watcher intégration complète
- [ ] Détection HTLC Polygon → envoi KPIV auto
- [ ] Page Portfolio

### Phase 3 - Multi-pair
- [ ] KPIV/BTC (via LP)
- [ ] Multi-chain support

---

## 10. Sécurité

### Règles critiques

1. **Secret S**: JAMAIS transmis au serveur, reste dans IndexedDB
2. **Private Keys**: LP keys dans .env, jamais commitées
3. **Timelock**: KPIV HTLC plus long que Polygon (safety margin)
4. **Validation**: Vérifier montants avant lock
5. **Rate limiting**: Limiter appels API

### Risques mitigés

| Risque | Mitigation |
|--------|------------|
| LP ne répond pas | Timelock → refund automatique |
| Retail grief (révèle pas S) | LP garde KPIV si pas de claim |
| Front-running | Hashlock empêche vol de S |
| Double-spend | Confirmations requises |

---

*Document v1.0 - 2025-12-16*
