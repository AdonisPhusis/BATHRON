#!/usr/bin/env python3
"""
Impermanent Loss Calculator for BATHRON Pivot Pool
"""
import math

def calculate_il(price_ratio):
    """
    Calculate Impermanent Loss based on price change ratio.

    IL Formula: IL = 2 * sqrt(price_ratio) / (1 + price_ratio) - 1

    price_ratio = new_price / initial_price
    """
    if price_ratio <= 0:
        return -1  # Total loss

    il = 2 * math.sqrt(price_ratio) / (1 + price_ratio) - 1
    return il

def demo_impermanent_loss():
    print("\n" + "="*70)
    print("IMPERMANENT LOSS (IL) - BATHRON AMM")
    print("="*70)

    print("""
    Impermanent Loss occurs when the price ratio between pooled assets changes.
    The "loss" is compared to simply holding the assets.

    Formula: IL = 2√(price_ratio) / (1 + price_ratio) - 1

    Key insight: IL is "impermanent" because if price returns to entry,
    you recover the loss. Fees can offset IL over time.
    """)

    print("-"*70)
    print("IL TABLE: How much you lose vs HODL based on price change")
    print("-"*70)
    print(f"{'Price Change':<20} {'IL %':<15} {'Value vs HODL':<20}")
    print("-"*70)

    price_changes = [
        (0.25, "-75% (crash)"),
        (0.50, "-50% (big drop)"),
        (0.75, "-25% (drop)"),
        (0.90, "-10% (small drop)"),
        (1.00, "0% (no change)"),
        (1.10, "+10% (small gain)"),
        (1.25, "+25% (gain)"),
        (1.50, "+50% (big gain)"),
        (2.00, "+100% (2x)"),
        (3.00, "+200% (3x)"),
        (5.00, "+400% (5x)"),
    ]

    for ratio, label in price_changes:
        il = calculate_il(ratio)
        value_vs_hodl = 1 + il
        print(f"{label:<20} {il*100:>+.2f}%{'':<8} {value_vs_hodl:.4f}x")

    print("\n" + "="*70)
    print("SCENARIO: LP deposits in BTC/KHU pool")
    print("="*70)

    initial_btc = 1
    initial_khu = 40_000
    initial_value = initial_btc * 40_000 + initial_khu  # 80k total

    print(f"""
    Initial deposit:
    - 1 BTC @ 40,000 KHU
    - 40,000 KHU
    - Total value: {initial_value:,} KHU

    Pool state: 1 BTC + 40,000 KHU (k = 40,000)
    """)

    scenarios = [
        (20_000, "BTC drops to 20k"),
        (40_000, "BTC stays at 40k"),
        (60_000, "BTC rises to 60k"),
        (80_000, "BTC rises to 80k"),
    ]

    print("-"*70)
    print(f"{'Scenario':<25} {'HODL Value':<15} {'LP Value':<15} {'IL':<10}")
    print("-"*70)

    for new_price, label in scenarios:
        price_ratio = new_price / 40_000

        # HODL value
        hodl_value = initial_btc * new_price + initial_khu

        # LP value (constant product rebalances)
        # At new price, pool has: sqrt(k * new_price) KHU and sqrt(k / new_price) BTC
        new_khu = math.sqrt(40_000 * new_price)
        new_btc = math.sqrt(40_000 / new_price)
        lp_value = new_btc * new_price + new_khu

        il = calculate_il(price_ratio)

        print(f"{label:<25} {hodl_value:>12,.0f} KHU {lp_value:>12,.0f} KHU {il*100:>+8.2f}%")

    print("\n" + "="*70)
    print("MITIGATING IL IN BATHRON")
    print("="*70)
    print("""
    1. FEES OFFSET IL
       - 0.30% per swap → accumulates over time
       - High volume = fees > IL

    2. PIVOT POOL ADVANTAGE
       - Single KHU deposit earns fees from ALL pairs
       - Diversified fee income vs single-pair IL

    3. KHU STABILITY
       - KHU = 1 PIV (internal parity)
       - USDC/KHU pair has minimal IL (both stable)
       - Volatile pairs (BTC) have higher IL but higher fees

    4. DAO TREASURY LP
       - T can absorb short-term IL
       - Long-term: fees compound
       - Treasury benefits from AMM volume

    5. LP CHOICE
       - LPs choose their risk tolerance
       - Single-asset deposit (KHU only) = exposure to all pairs
       - Can withdraw after timelock if IL too high
    """)

    # Calculate break-even
    print("-"*70)
    print("BREAK-EVEN: How much fees needed to offset IL")
    print("-"*70)

    fee_rate = 0.003  # 0.30%

    for ratio, label in [(0.5, "-50%"), (1.5, "+50%"), (2.0, "+100%")]:
        il = calculate_il(ratio)
        # Volume needed to generate fees = IL
        # fees = volume * fee_rate * lp_share
        # Assuming LP has 10% of pool
        lp_share = 0.10
        volume_needed = abs(il) / (fee_rate * lp_share)
        print(f"Price change {label}: IL = {il*100:+.2f}%")
        print(f"  → Need {volume_needed:.1f}x pool volume in trades to break even")
        print(f"  → At 50% daily volume: {volume_needed/0.5:.0f} days to recover")
        print()


if __name__ == "__main__":
    demo_impermanent_loss()
