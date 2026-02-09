# BATHRON HTLC Smart Contracts

Smart contracts for cross-chain atomic swaps between BATHRON (M1) and EVM chains (Base, Ethereum, etc.).

## Architecture

```
BATHRON Chain                            EVM Chain (Base/ETH)
────────────                             ──────────────────────

LOT (HTLC script)                        BATHRON_HTLC.sol
├── hashlock H                           ├── hashlock H (same!)
├── taker_pubkey                         ├── lp address
├── lp_pubkey                            ├── taker address
└── expiry (CLTV)                        └── timelock

Taker reveals S on BATHRON ──────────► LP uses S to claim on EVM
     (claims M1)                            (claims USDC/tokens)
```

## Flow

1. **Taker** generates secret `S`, computes `H = SHA256(S)`
2. **LP** creates LOT on BATHRON with hashlock `H`
3. **Taker** locks USDC/tokens on EVM with same hashlock `H`
4. **Taker** reveals `S` on BATHRON to claim M1
5. **LP** (or anyone) sees `S` in BATHRON tx, uses it to claim on EVM
6. If no claim before timeout, **Taker** can refund on EVM

## Installation

```bash
cd contrib/dex/contracts
npm install
```

## Testing

```bash
# Run all tests
npm test

# Run with coverage
npm run test:coverage

# Run local node for manual testing
npm run node
```

## Deployment

### 1. Setup Environment

Create `.env` file:

```bash
# Required for deployment
PRIVATE_KEY=your_private_key_here

# RPC URLs (optional, has defaults)
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org

# For contract verification (optional)
BASESCAN_API_KEY=your_api_key
ETHERSCAN_API_KEY=your_api_key
```

### 2. Deploy

```bash
# Deploy to Base Sepolia testnet
npm run deploy:sepolia

# Deploy to local hardhat node
npm run deploy:localhost
```

### 3. Verify (optional)

```bash
npx hardhat verify --network sepolia <CONTRACT_ADDRESS>
```

## Contract Interface

### Lock ERC20 Tokens

```solidity
function lock(
    bytes32 swapId,      // Unique swap ID
    address lp,          // LP address (receives on claim)
    address token,       // ERC20 token address
    uint256 amount,      // Amount to lock
    bytes32 hashlock,    // SHA256(secret) - same as BATHRON
    uint256 timelock     // Unix timestamp for refund
) external;
```

### Lock Native ETH

```solidity
function lockETH(
    bytes32 swapId,
    address lp,
    bytes32 hashlock,
    uint256 timelock
) external payable;
```

### Claim with Preimage

```solidity
// Anyone can call, tokens go to swap.lp
// Preimage is emitted in event (becomes PUBLIC)
function claim(bytes32 swapId, bytes32 preimage) external;
```

### Refund After Timeout

```solidity
// Anyone can call, tokens go to swap.taker
// Only works after timelock expires
function refund(bytes32 swapId) external;
```

### View Functions

```solidity
function getSwap(bytes32 swapId) external view returns (...);
function isActive(bytes32 swapId) external view returns (bool);
function verifyPreimage(bytes32 swapId, bytes32 preimage) external view returns (bool);
function timeUntilRefund(bytes32 swapId) external view returns (uint256);
function computeSwapId(address lp, address taker, bytes32 hashlock, uint256 nonce) external pure returns (bytes32);
```

## Security Considerations

### Timelock

- **MIN_TIMELOCK**: 1 hour (prevents griefing)
- **MAX_TIMELOCK**: 30 days (prevents forever-lock)
- **Important**: EVM timelock MUST be shorter than BATHRON expiry!

### Why?

If Taker reveals `S` on BATHRON just before BATHRON expiry:
- Taker claims M1
- LP must claim on EVM before EVM timeout
- If EVM timeout >= BATHRON expiry -> LP might not have time -> LP loses!

**Rule**: `timelock_evm = expiry_bathron - safety_margin`

Recommended: 1-2 days margin.

### SHA256 vs Keccak256

This contract uses **SHA256** (not keccak256) for hashlock verification.

Why? BATHRON (Bitcoin-like) uses SHA256 in scripts. Using the same hash function ensures compatibility.

```solidity
// In contract:
sha256(abi.encodePacked(preimage)) == hashlock

// In BATHRON script:
OP_SHA256 <H> OP_EQUALVERIFY
```

## Deployed Contracts

| Network | Address | Explorer |
|---------|---------|----------|
| Base Sepolia | `0x2493EaaaBa6B129962c8967AaEE6bF11D0277756` | [Basescan](https://sepolia.basescan.org/address/0x2493EaaaBa6B129962c8967AaEE6bF11D0277756) |

## Integration with BATHRON

### Python Example

```python
from web3 import Web3

# Connect to Base
w3 = Web3(Web3.HTTPProvider('https://sepolia.base.org'))
htlc = w3.eth.contract(address=HTLC_ADDRESS, abi=HTLC_ABI)

# Lock USDC
swap_id = w3.keccak(text=f"{lp_addr}{taker_addr}{hashlock}{nonce}")
tx = htlc.functions.lock(
    swap_id,
    lp_address,
    usdc_address,
    amount,
    hashlock,  # Same H as BATHRON LOT
    int(time.time()) + 86400  # +1 day
).build_transaction({...})

# Claim with preimage (after seeing it on BATHRON)
tx = htlc.functions.claim(swap_id, preimage).build_transaction({...})
```

## License

MIT
