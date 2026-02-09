#!/usr/bin/env python3
"""
Compare different AMM formulas and their price curves
"""
import math

def constant_product(x, y, dx):
    """
    Standard Uniswap: x * y = k
    Price impact increases linearly with trade size
    """
    k = x * y
    new_x = x + dx
    new_y = k / new_x
    dy = y - new_y
    return dy, dy/dx  # output, effective price

def constant_product_squared(x, y, dx):
    """
    x² * y² = k  (equivalent to xy = √k)
    Same curve shape as constant_product, just different k
    """
    k = (x * y) ** 2
    new_x = x + dx
    # (new_x)² * (new_y)² = k
    # new_y = √(k) / new_x = xy / new_x
    new_y = math.sqrt(k) / new_x
    dy = y - new_y
    return dy, dy/dx

def stableswap(x, y, dx, A=100):
    """
    Curve StableSwap: optimized for 1:1 pairs
    A = amplification coefficient (higher = flatter curve near 1:1)

    Simplified formula: A*n^n * sum(x) + D = A*D*n^n + D^(n+1)/(n^n * prod(x))
    For 2 assets: concentrates liquidity around 1:1 ratio
    """
    # Simplified approximation for demo
    n = 2
    D = x + y  # Total liquidity (simplified)

    # Near 1:1, behaves like constant sum (x + y = k)
    # Far from 1:1, behaves like constant product

    # Hybrid formula (approximation)
    ratio = min(x, y) / max(x, y) if max(x, y) > 0 else 1

    # Weight between constant sum and constant product based on ratio
    # When ratio ~1: mostly constant sum (low slippage)
    # When ratio far from 1: mostly constant product (high slippage)
    weight = ratio ** A  # A controls how quickly we switch

    # Constant sum output
    dy_sum = dx

    # Constant product output
    k = x * y
    new_x = x + dx
    dy_prod = y - k / new_x

    # Weighted combination
    dy = weight * dy_sum + (1 - weight) * dy_prod

    return dy, dy/dx if dx > 0 else 0

def concentrated_liquidity(x, y, dx, price_low=0.95, price_high=1.05):
    """
    Uniswap v3 style: liquidity concentrated in price range
    More capital efficient but complex
    """
    # Current price
    price = y / x if x > 0 else 1

    # If trade moves price outside range, use constant product
    k = x * y
    new_x = x + dx
    new_y = k / new_x
    dy = y - new_y

    # Concentration multiplier (simplified)
    range_width = price_high - price_low
    concentration = 1 / range_width  # Narrower range = more concentrated

    # In-range trades get better rates
    if price_low <= price <= price_high:
        dy = dy * (1 + (concentration - 1) * 0.5)  # Simplified boost

    return dy, dy/dx if dx > 0 else 0


def compare_formulas():
    """Compare all formulas with same initial state"""

    print("\n" + "="*70)
    print("AMM FORMULA COMPARISON")
    print("="*70)

    # Initial state: 1M KHU paired with 25 BTC (price = 40,000 KHU/BTC)
    x_khu = 1_000_000
    y_btc = 25

    print(f"\nInitial State:")
    print(f"  KHU Pool: {x_khu:,}")
    print(f"  BTC Reserve: {y_btc}")
    print(f"  Price: {x_khu/y_btc:,.0f} KHU/BTC")

    # Test swaps of different sizes
    test_swaps = [
        (0.1, "Small (0.1 BTC)"),
        (1.0, "Medium (1 BTC)"),
        (5.0, "Large (5 BTC)"),
    ]

    print("\n" + "-"*70)
    print("SWAP: BTC → KHU")
    print("-"*70)

    for dx, label in test_swaps:
        print(f"\n{label}:")
        print(f"{'Formula':<25} {'KHU Out':>12} {'Eff. Price':>15} {'Slippage':>10}")
        print("-"*62)

        ideal_price = x_khu / y_btc
        ideal_out = dx * ideal_price

        # Constant Product (standard)
        dy, price = constant_product(y_btc, x_khu, dx)
        slippage = (1 - dy/ideal_out) * 100
        print(f"{'x·y = k (Uniswap)':<25} {dy:>12,.0f} {price:>15,.0f} {slippage:>9.2f}%")

        # Constant Product Squared
        dy2, price2 = constant_product_squared(y_btc, x_khu, dx)
        slippage2 = (1 - dy2/ideal_out) * 100
        print(f"{'x²·y² = k':<25} {dy2:>12,.0f} {price2:>15,.0f} {slippage2:>9.2f}%")

        # StableSwap (not ideal for BTC/KHU but shows the difference)
        dy3, price3 = stableswap(y_btc, x_khu, dx, A=10)
        slippage3 = (1 - dy3/ideal_out) * 100
        print(f"{'StableSwap (A=10)':<25} {dy3:>12,.0f} {price3:>15,.0f} {slippage3:>9.2f}%")

    # Now test with a stable pair (USDC/KHU should be ~1:1)
    print("\n" + "="*70)
    print("STABLE PAIR: USDC/KHU (target 1:1)")
    print("="*70)

    x_khu = 1_000_000
    y_usdc = 1_000_000  # 1:1 ratio

    print(f"\nInitial State:")
    print(f"  KHU Pool: {x_khu:,}")
    print(f"  USDC Reserve: {y_usdc:,}")
    print(f"  Price: {x_khu/y_usdc:.4f} KHU/USDC")

    test_swaps_stable = [
        (1000, "Small (1k USDC)"),
        (10000, "Medium (10k USDC)"),
        (100000, "Large (100k USDC)"),
    ]

    print("\n" + "-"*70)
    print("SWAP: USDC → KHU")
    print("-"*70)

    for dx, label in test_swaps_stable:
        print(f"\n{label}:")
        print(f"{'Formula':<25} {'KHU Out':>12} {'Eff. Price':>15} {'Slippage':>10}")
        print("-"*62)

        ideal_out = dx  # For 1:1 pair

        # Constant Product
        dy, price = constant_product(y_usdc, x_khu, dx)
        slippage = (1 - dy/ideal_out) * 100
        print(f"{'x·y = k (Uniswap)':<25} {dy:>12,.0f} {price:>15,.4f} {slippage:>9.2f}%")

        # StableSwap - much better for stables!
        dy3, price3 = stableswap(y_usdc, x_khu, dx, A=100)
        slippage3 = (1 - dy3/ideal_out) * 100
        print(f"{'StableSwap (A=100)':<25} {dy3:>12,.0f} {price3:>15,.4f} {slippage3:>9.2f}%")

    print("\n" + "="*70)
    print("CONCLUSION")
    print("="*70)
    print("""
    x·y = k (Constant Product):
    ✓ Simple, battle-tested
    ✓ Works for any price ratio
    ✗ High slippage for large trades
    ✗ Capital inefficient for stable pairs

    x²·y² = k:
    = Mathematically equivalent to x·y = k (same curve)
    = No practical difference

    StableSwap (Curve):
    ✓ Low slippage for stable pairs (USDC/KHU)
    ✓ Concentrates liquidity around 1:1
    ✗ Needs amplification tuning per pair
    ✗ Bad for volatile pairs (BTC/KHU)

    RECOMMENDATION for BATHRON:
    → Use x·y = k for volatile pairs (BTC/KHU, ETH/KHU)
    → Consider StableSwap for stable pairs (USDC/KHU) later
    → Start simple, optimize later
    """)


if __name__ == "__main__":
    compare_formulas()
