"""
BATHRON 2.0 DEX SDK - Standard LOT Sizes

This module defines the standard HTLC lot sizes and provides utilities
for splitting arbitrary amounts into standard-sized lots.

Architecture:
    - Core (protocol): Accepts ANY positive KPIV amount (permissionless)
    - SDK (policy): Enforces standard sizes by default for better UX

Standard Sizes:
    1 KPIV      - Micro (testing, tiny swaps)
    10 KPIV     - Small retail
    100 KPIV    - Medium retail
    1,000 KPIV  - Large retail / small whale
    10,000 KPIV - Whale / institutional

Benefits of standardization:
    - Better liquidity pooling (orders match easier)
    - Privacy (uniform amounts = less traceability)
    - Simpler UX (clear choices for users)
    - Aggregated orderbook depth

Expert Mode:
    LPs can bypass SDK and use Core RPC directly for non-standard sizes.
    Non-standard lots may have lower visibility in default UI.
"""

from typing import List, Tuple
from decimal import Decimal

# ═══════════════════════════════════════════════════════════════════════════════
# STANDARD LOT SIZES (in KPIV, descending for greedy algorithm)
# ═══════════════════════════════════════════════════════════════════════════════

STANDARD_SIZES: List[int] = [10000, 1000, 100, 10, 1]

# Human-readable labels
SIZE_LABELS = {
    1: "Micro",
    10: "Small",
    100: "Medium",
    1000: "Large",
    10000: "Whale"
}

# Default maximum lots per swap (to prevent spam/complexity)
DEFAULT_MAX_LOTS = 20


# ═══════════════════════════════════════════════════════════════════════════════
# GREEDY SPLIT ALGORITHM
# ═══════════════════════════════════════════════════════════════════════════════

def split_amount(amount: int) -> List[int]:
    """
    Split amount into standard lot sizes using greedy algorithm.

    The greedy approach works optimally for our size set {1, 10, 100, 1000, 10000}
    because each size is a multiple of 10 of the previous one.

    Args:
        amount: Integer KPIV amount to split

    Returns:
        List of standard lot sizes that sum to amount

    Raises:
        ValueError: If amount is not positive

    Examples:
        >>> split_amount(55)
        [10, 10, 10, 10, 10, 1, 1, 1, 1, 1]

        >>> split_amount(1234)
        [1000, 100, 100, 10, 10, 10, 1, 1, 1, 1]

        >>> split_amount(10000)
        [10000]

        >>> split_amount(100)
        [100]
    """
    if not isinstance(amount, int):
        raise TypeError(f"Amount must be integer, got {type(amount)}")
    if amount <= 0:
        raise ValueError(f"Amount must be positive, got {amount}")

    lots = []
    remaining = amount

    for size in STANDARD_SIZES:
        while remaining >= size:
            lots.append(size)
            remaining -= size

    # Should never happen with our size set (1 is included)
    if remaining != 0:
        raise ValueError(f"Cannot split {amount} into standard sizes (remaining: {remaining})")

    return lots


def split_amount_grouped(amount: int) -> List[Tuple[int, int]]:
    """
    Split amount and return grouped counts.

    Args:
        amount: Integer KPIV amount to split

    Returns:
        List of (size, count) tuples

    Examples:
        >>> split_amount_grouped(55)
        [(10, 5), (1, 5)]

        >>> split_amount_grouped(1234)
        [(1000, 1), (100, 2), (10, 3), (1, 4)]
    """
    lots = split_amount(amount)

    grouped = []
    current_size = None
    current_count = 0

    for lot in lots:
        if lot == current_size:
            current_count += 1
        else:
            if current_size is not None:
                grouped.append((current_size, current_count))
            current_size = lot
            current_count = 1

    if current_size is not None:
        grouped.append((current_size, current_count))

    return grouped


def split_amount_optimized(amount: int, max_lots: int = DEFAULT_MAX_LOTS) -> List[int]:
    """
    Split with maximum lot count limit.

    If greedy produces too many lots, raises error with suggestions
    for nearby amounts that split more efficiently.

    Args:
        amount: Integer KPIV amount to split
        max_lots: Maximum number of lots allowed (default: 20)

    Returns:
        List of standard lot sizes

    Raises:
        ValueError: If split requires more than max_lots

    Examples:
        >>> split_amount_optimized(100)
        [100]

        >>> split_amount_optimized(99, max_lots=5)
        ValueError: Amount 99 requires 18 lots (max 5). Consider: [100, 90, 110]
    """
    lots = split_amount(amount)

    if len(lots) > max_lots:
        suggestions = suggest_clean_amounts(amount, max_lots)
        raise ValueError(
            f"Amount {amount} requires {len(lots)} lots (max {max_lots}). "
            f"Consider: {suggestions}"
        )

    return lots


# ═══════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

def suggest_clean_amounts(amount: int, max_lots: int = 10, search_range: int = 20) -> List[int]:
    """
    Suggest nearby amounts that split into fewer lots.

    Args:
        amount: Original amount
        max_lots: Maximum lots to consider "clean"
        search_range: How far to search in each direction

    Returns:
        List of suggested amounts (sorted by distance from original)
    """
    suggestions = []

    for delta in range(-search_range, search_range + 1):
        test = amount + delta
        if test > 0:
            lots = split_amount(test)
            if len(lots) <= max_lots:
                suggestions.append((abs(delta), test, len(lots)))

    # Sort by distance, then by lot count
    suggestions.sort(key=lambda x: (x[0], x[2]))

    # Return just the amounts (deduplicated)
    return [s[1] for s in suggestions[:5]]


def count_lots(amount: int) -> int:
    """Count how many lots an amount would require."""
    return len(split_amount(amount))


def is_standard_size(amount: int) -> bool:
    """Check if amount is a single standard lot size."""
    return amount in STANDARD_SIZES


def get_size_label(size: int) -> str:
    """Get human-readable label for a lot size."""
    return SIZE_LABELS.get(size, f"{size} KPIV")


def format_split(amount: int) -> str:
    """
    Format split as human-readable string.

    Examples:
        >>> format_split(55)
        "5×10 + 5×1 KPIV (10 lots)"

        >>> format_split(100)
        "1×100 KPIV (1 lot)"
    """
    grouped = split_amount_grouped(amount)
    parts = [f"{count}×{size}" for size, count in grouped]
    total_lots = sum(count for _, count in grouped)
    lot_word = "lot" if total_lots == 1 else "lots"
    return f"{' + '.join(parts)} KPIV ({total_lots} {lot_word})"


# ═══════════════════════════════════════════════════════════════════════════════
# VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

def validate_amount(amount: int, max_lots: int = DEFAULT_MAX_LOTS) -> Tuple[bool, str]:
    """
    Validate if amount can be processed within lot limits.

    Args:
        amount: Amount to validate
        max_lots: Maximum allowed lots

    Returns:
        (is_valid, message) tuple
    """
    if not isinstance(amount, int):
        return False, f"Amount must be integer, got {type(amount).__name__}"

    if amount <= 0:
        return False, "Amount must be positive"

    lot_count = count_lots(amount)

    if lot_count > max_lots:
        suggestions = suggest_clean_amounts(amount, max_lots)
        return False, f"Requires {lot_count} lots (max {max_lots}). Try: {suggestions}"

    return True, f"OK: {format_split(amount)}"


def validate_amount_decimal(amount: Decimal, max_lots: int = DEFAULT_MAX_LOTS) -> Tuple[bool, str]:
    """
    Validate decimal amount (must be whole number).

    Args:
        amount: Decimal amount in KPIV
        max_lots: Maximum allowed lots

    Returns:
        (is_valid, message) tuple
    """
    if amount != int(amount):
        return False, f"Amount must be whole KPIV, got {amount}"

    return validate_amount(int(amount), max_lots)


# ═══════════════════════════════════════════════════════════════════════════════
# ORDERBOOK AGGREGATION
# ═══════════════════════════════════════════════════════════════════════════════

def aggregate_orderbook(lots: List[dict]) -> dict:
    """
    Aggregate orderbook by standard sizes.

    Args:
        lots: List of LOT objects with 'size' field

    Returns:
        Dict mapping size -> total available

    Example:
        >>> lots = [{"size": 10}, {"size": 10}, {"size": 100}]
        >>> aggregate_orderbook(lots)
        {10: 20, 100: 100}
    """
    aggregated = {size: 0 for size in STANDARD_SIZES}

    for lot in lots:
        size = lot.get("size", 0)
        if size in aggregated:
            aggregated[size] += size
        else:
            # Non-standard size - add to closest bucket or "other"
            pass

    # Remove empty buckets
    return {k: v for k, v in aggregated.items() if v > 0}


# ═══════════════════════════════════════════════════════════════════════════════
# CLI TESTING
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    # Test cases
    test_amounts = [1, 10, 55, 99, 100, 123, 1000, 1234, 9999, 10000, 12345]

    print("=" * 60)
    print("HTLC LOT SIZE SPLIT TEST")
    print("=" * 60)
    print(f"Standard sizes: {STANDARD_SIZES}")
    print()

    for amount in test_amounts:
        lots = split_amount(amount)
        grouped = split_amount_grouped(amount)
        print(f"{amount:>6} KPIV → {format_split(amount)}")

    print()
    print("=" * 60)
    print("VALIDATION TEST (max 10 lots)")
    print("=" * 60)

    for amount in [50, 55, 99, 100, 199]:
        valid, msg = validate_amount(amount, max_lots=10)
        status = "✓" if valid else "✗"
        print(f"{amount:>6} KPIV: {status} {msg}")
