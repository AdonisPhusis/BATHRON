// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BATHRON_HTLC
 * @notice Hash Time-Locked Contract for PIV2 cross-chain atomic swaps
 * @dev Used for trustless KPIV <-> USDC/ETH/tokens swaps
 *
 * Flow:
 *   1. Taker generates secret S, computes H = SHA256(S)
 *   2. LP creates LOT on PIV2 with hashlock H
 *   3. Taker locks tokens here with same hashlock H
 *   4. Taker reveals S on PIV2 to claim KPIV
 *   5. LP (or anyone) sees S, calls claim(S) here to get tokens
 *   6. If no claim before timelock, Taker can refund
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract BATHRON_HTLC is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct Swap {
        address lp;           // Recipient when claimed (LP address)
        address taker;        // Creator of the swap (can refund after timelock)
        address token;        // ERC20 token address (or address(0) for native)
        uint256 amount;       // Amount locked
        bytes32 hashlock;     // SHA256(secret) - same as PIV2 LOT
        uint256 timelock;     // Unix timestamp after which refund is allowed
        bool claimed;         // True if LP claimed with preimage
        bool refunded;        // True if Taker refunded after timelock
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice All swaps indexed by swapId
    mapping(bytes32 => Swap) public swaps;

    /// @notice Minimum timelock duration (1 hour)
    uint256 public constant MIN_TIMELOCK = 1 hours;

    /// @notice Maximum timelock duration (30 days)
    uint256 public constant MAX_TIMELOCK = 30 days;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event Locked(
        bytes32 indexed swapId,
        address indexed lp,
        address indexed taker,
        address token,
        uint256 amount,
        bytes32 hashlock,
        uint256 timelock
    );

    event Claimed(
        bytes32 indexed swapId,
        bytes32 preimage  // The secret S - NOW PUBLIC
    );

    event Refunded(
        bytes32 indexed swapId
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error SwapExists();
    error SwapNotFound();
    error SwapCompleted();
    error InvalidHashlock();
    error InvalidPreimage();
    error InvalidTimelock();
    error TimelockNotExpired();
    error TimelockExpired();
    error InvalidAmount();
    error InvalidAddress();
    error TransferFailed();

    // ═══════════════════════════════════════════════════════════════════════════
    // MAIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Lock ERC20 tokens in an HTLC
     * @param swapId Unique identifier for this swap (suggest: keccak256(lp, taker, hashlock, nonce))
     * @param lp Address that will receive tokens when claiming with preimage
     * @param token ERC20 token address to lock
     * @param amount Amount of tokens to lock
     * @param hashlock SHA256 hash of the secret (must match PIV2 LOT)
     * @param timelock Unix timestamp after which Taker can refund
     */
    function lock(
        bytes32 swapId,
        address lp,
        address token,
        uint256 amount,
        bytes32 hashlock,
        uint256 timelock
    ) external nonReentrant {
        // Validations
        if (swaps[swapId].amount != 0) revert SwapExists();
        if (lp == address(0)) revert InvalidAddress();
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (hashlock == bytes32(0)) revert InvalidHashlock();
        if (timelock <= block.timestamp + MIN_TIMELOCK) revert InvalidTimelock();
        if (timelock > block.timestamp + MAX_TIMELOCK) revert InvalidTimelock();

        // Transfer tokens to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Store swap
        swaps[swapId] = Swap({
            lp: lp,
            taker: msg.sender,
            token: token,
            amount: amount,
            hashlock: hashlock,
            timelock: timelock,
            claimed: false,
            refunded: false
        });

        emit Locked(swapId, lp, msg.sender, token, amount, hashlock, timelock);
    }

    /**
     * @notice Lock native ETH/MATIC in an HTLC
     * @param swapId Unique identifier for this swap
     * @param lp Address that will receive ETH when claiming with preimage
     * @param hashlock SHA256 hash of the secret
     * @param timelock Unix timestamp after which Taker can refund
     */
    function lockETH(
        bytes32 swapId,
        address lp,
        bytes32 hashlock,
        uint256 timelock
    ) external payable nonReentrant {
        // Validations
        if (swaps[swapId].amount != 0) revert SwapExists();
        if (lp == address(0)) revert InvalidAddress();
        if (msg.value == 0) revert InvalidAmount();
        if (hashlock == bytes32(0)) revert InvalidHashlock();
        if (timelock <= block.timestamp + MIN_TIMELOCK) revert InvalidTimelock();
        if (timelock > block.timestamp + MAX_TIMELOCK) revert InvalidTimelock();

        // Store swap (token = address(0) for native)
        swaps[swapId] = Swap({
            lp: lp,
            taker: msg.sender,
            token: address(0),
            amount: msg.value,
            hashlock: hashlock,
            timelock: timelock,
            claimed: false,
            refunded: false
        });

        emit Locked(swapId, lp, msg.sender, address(0), msg.value, hashlock, timelock);
    }

    /**
     * @notice Claim tokens by revealing the preimage
     * @dev Anyone can call this, but tokens go to swap.lp
     * @dev The preimage is emitted in the event - becomes PUBLIC
     * @param swapId The swap to claim
     * @param preimage The secret S where SHA256(S) == hashlock
     */
    function claim(bytes32 swapId, bytes32 preimage) external nonReentrant {
        Swap storage s = swaps[swapId];

        // Validations
        if (s.amount == 0) revert SwapNotFound();
        if (s.claimed || s.refunded) revert SwapCompleted();
        if (block.timestamp >= s.timelock) revert TimelockExpired();

        // Verify preimage: SHA256(preimage) must equal hashlock
        if (sha256(abi.encodePacked(preimage)) != s.hashlock) revert InvalidPreimage();

        // Mark as claimed
        s.claimed = true;

        // Transfer to LP
        if (s.token == address(0)) {
            // Native ETH/MATIC
            (bool success, ) = s.lp.call{value: s.amount}("");
            if (!success) revert TransferFailed();
        } else {
            // ERC20
            IERC20(s.token).safeTransfer(s.lp, s.amount);
        }

        // Emit event with preimage - THIS MAKES THE SECRET PUBLIC
        emit Claimed(swapId, preimage);
    }

    /**
     * @notice Refund tokens to Taker after timelock expires
     * @dev Only possible after timelock, anyone can call but tokens go to swap.taker
     * @param swapId The swap to refund
     */
    function refund(bytes32 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];

        // Validations
        if (s.amount == 0) revert SwapNotFound();
        if (s.claimed || s.refunded) revert SwapCompleted();
        if (block.timestamp < s.timelock) revert TimelockNotExpired();

        // Mark as refunded
        s.refunded = true;

        // Transfer to Taker
        if (s.token == address(0)) {
            // Native ETH/MATIC
            (bool success, ) = s.taker.call{value: s.amount}("");
            if (!success) revert TransferFailed();
        } else {
            // ERC20
            IERC20(s.token).safeTransfer(s.taker, s.amount);
        }

        emit Refunded(swapId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get swap details
     * @param swapId The swap ID
     * @return lp LP address
     * @return taker Taker address
     * @return token Token address (address(0) for native)
     * @return amount Amount locked
     * @return hashlock The hashlock
     * @return timelock Refund timestamp
     * @return claimed Whether claimed
     * @return refunded Whether refunded
     */
    function getSwap(bytes32 swapId) external view returns (
        address lp,
        address taker,
        address token,
        uint256 amount,
        bytes32 hashlock,
        uint256 timelock,
        bool claimed,
        bool refunded
    ) {
        Swap storage s = swaps[swapId];
        return (s.lp, s.taker, s.token, s.amount, s.hashlock, s.timelock, s.claimed, s.refunded);
    }

    /**
     * @notice Check if a swap exists and is active (not claimed/refunded)
     * @param swapId The swap ID
     * @return True if swap exists and is active
     */
    function isActive(bytes32 swapId) external view returns (bool) {
        Swap storage s = swaps[swapId];
        return s.amount > 0 && !s.claimed && !s.refunded;
    }

    /**
     * @notice Check if a preimage is valid for a swap
     * @param swapId The swap ID
     * @param preimage The preimage to check
     * @return True if SHA256(preimage) == hashlock
     */
    function verifyPreimage(bytes32 swapId, bytes32 preimage) external view returns (bool) {
        return sha256(abi.encodePacked(preimage)) == swaps[swapId].hashlock;
    }

    /**
     * @notice Calculate time remaining until refund is possible
     * @param swapId The swap ID
     * @return Seconds until refund (0 if already possible)
     */
    function timeUntilRefund(bytes32 swapId) external view returns (uint256) {
        uint256 timelock = swaps[swapId].timelock;
        if (block.timestamp >= timelock) return 0;
        return timelock - block.timestamp;
    }

    /**
     * @notice Generate a swapId from parameters
     * @dev Recommended way to create unique swapIds
     * @param lp LP address
     * @param taker Taker address
     * @param hashlock The hashlock
     * @param nonce A unique nonce (e.g. block.timestamp or random)
     * @return The swapId
     */
    function computeSwapId(
        address lp,
        address taker,
        bytes32 hashlock,
        uint256 nonce
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(lp, taker, hashlock, nonce));
    }
}
