#!/usr/bin/env python3
"""
BATHRON Pivot Pool AMM Simulator
Demonstrates pricing mechanics with unified KHU liquidity
"""

class PivotPool:
    def __init__(self):
        # Central KHU pool
        self.khu_total = 0

        # External reserves (virtual)
        # {ticker: {reserve: amount, weight: bps, decimals: int}}
        self.reserves = {}

        # LP positions
        self.lp_positions = {}  # {id: {amount, shares}}

        # Fees
        self.FEE_BPS = 30  # 0.30%

    def add_reserve(self, ticker, weight_bps, decimals=8):
        """Add new external asset reserve"""
        self.reserves[ticker] = {
            'reserve': 0,
            'weight': weight_bps,
            'decimals': decimals
        }
        print(f"[POOL] Added reserve {ticker} with weight {weight_bps/100}%")

    def deposit_khu(self, lp_id, amount):
        """LP deposits KHU into pool"""
        self.khu_total += amount

        # Calculate shares (simplified - proportional)
        total_before = self.khu_total - amount
        if total_before == 0:
            shares = 10000  # 100% for first depositor
        else:
            shares = int((amount / self.khu_total) * 10000)

        self.lp_positions[lp_id] = {'amount': amount, 'shares': shares}
        print(f"[LP] {lp_id} deposited {amount:,} KHU, shares: {shares/100}%")
        print(f"[POOL] Total KHU: {self.khu_total:,}")

    def seed_reserve(self, ticker, amount):
        """Seed external reserve (for simulation)"""
        if ticker not in self.reserves:
            print(f"[ERROR] Unknown reserve {ticker}")
            return
        self.reserves[ticker]['reserve'] = amount
        print(f"[POOL] Seeded {ticker} reserve: {amount:,}")

    def get_virtual_khu(self, ticker):
        """Get virtual KHU allocation for an asset"""
        if ticker not in self.reserves:
            return 0
        return int(self.khu_total * self.reserves[ticker]['weight'] / 10000)

    def get_price(self, ticker):
        """Get price of asset in KHU"""
        if ticker not in self.reserves:
            return 0
        res = self.reserves[ticker]
        if res['reserve'] == 0:
            return 0
        khu_virtual = self.get_virtual_khu(ticker)
        # price = khu_virtual / reserve
        return khu_virtual / res['reserve']

    def quote_swap(self, asset_in, amount_in, asset_out):
        """Get quote for swap without executing"""

        # Case 1: X -> KHU
        if asset_out == "KHU" and asset_in in self.reserves:
            res = self.reserves[asset_in]
            khu_virtual = self.get_virtual_khu(asset_in)

            # Constant product: (reserve + delta_in) * (khu - delta_out) = k
            k = res['reserve'] * khu_virtual
            new_reserve = res['reserve'] + amount_in
            new_khu = k / new_reserve
            khu_out = khu_virtual - new_khu

            # Apply fee
            fee = khu_out * self.FEE_BPS / 10000
            khu_out_after_fee = khu_out - fee

            return {
                'amount_out': khu_out_after_fee,
                'fee': fee,
                'price_before': self.get_price(asset_in),
                'price_after': (new_khu) / new_reserve,
                'slippage_bps': int((1 - khu_out_after_fee / (amount_in * self.get_price(asset_in))) * 10000)
            }

        # Case 2: KHU -> X
        if asset_in == "KHU" and asset_out in self.reserves:
            res = self.reserves[asset_out]
            khu_virtual = self.get_virtual_khu(asset_out)

            k = res['reserve'] * khu_virtual
            new_khu = khu_virtual + amount_in
            new_reserve = k / new_khu
            asset_out_amount = res['reserve'] - new_reserve

            # Apply fee
            fee = asset_out_amount * self.FEE_BPS / 10000
            out_after_fee = asset_out_amount - fee

            return {
                'amount_out': out_after_fee,
                'fee': fee,
                'price_before': 1 / self.get_price(asset_out) if self.get_price(asset_out) > 0 else 0,
                'price_after': new_khu / new_reserve,
                'slippage_bps': int(abs(1 - (out_after_fee * self.get_price(asset_out)) / amount_in) * 10000)
            }

        # Case 3: X -> Y (cross-swap via KHU)
        if asset_in in self.reserves and asset_out in self.reserves:
            # X -> KHU
            step1 = self.quote_swap(asset_in, amount_in, "KHU")
            # KHU -> Y (using output from step1)
            step2 = self.quote_swap("KHU", step1['amount_out'], asset_out)

            return {
                'amount_out': step2['amount_out'],
                'fee': step1['fee'] + step2['fee'],
                'route': [asset_in, "KHU", asset_out],
                'intermediate_khu': step1['amount_out']
            }

        return None

    def execute_swap(self, asset_in, amount_in, asset_out):
        """Execute swap and update state"""
        quote = self.quote_swap(asset_in, amount_in, asset_out)
        if not quote:
            print(f"[ERROR] Invalid swap {asset_in} -> {asset_out}")
            return None

        # Update state based on swap direction
        if asset_out == "KHU" and asset_in in self.reserves:
            self.reserves[asset_in]['reserve'] += amount_in
            # KHU comes from pool (virtually)
            print(f"[SWAP] {amount_in} {asset_in} -> {quote['amount_out']:.2f} KHU")

        elif asset_in == "KHU" and asset_out in self.reserves:
            self.reserves[asset_out]['reserve'] -= quote['amount_out']
            # KHU goes to pool (virtually)
            print(f"[SWAP] {amount_in} KHU -> {quote['amount_out']:.6f} {asset_out}")

        return quote

    def status(self):
        """Print pool status"""
        print("\n" + "="*60)
        print("PIVOT POOL STATUS")
        print("="*60)
        print(f"Total KHU Liquidity: {self.khu_total:,}")
        print("\nReserves:")
        for ticker, res in self.reserves.items():
            khu_virtual = self.get_virtual_khu(ticker)
            price = self.get_price(ticker)
            print(f"  {ticker}:")
            print(f"    Reserve: {res['reserve']:,.6f}")
            print(f"    Weight: {res['weight']/100}%")
            print(f"    Virtual KHU: {khu_virtual:,}")
            print(f"    Price: {price:,.2f} KHU/{ticker}")

        print(f"\nLP Positions: {len(self.lp_positions)}")
        for lp_id, pos in self.lp_positions.items():
            print(f"  {lp_id}: {pos['amount']:,} KHU ({pos['shares']/100}%)")
        print("="*60 + "\n")


def demo_pivot_pool():
    """Demonstrate Pivot Pool mechanics"""

    print("\n" + "#"*60)
    print("# BATHRON PIVOT POOL AMM DEMO")
    print("#"*60 + "\n")

    # Create pool
    pool = PivotPool()

    # Add reserves with weights
    print("[SETUP] Adding reserves...")
    pool.add_reserve("BTC", 3333, decimals=8)    # 33.33%
    pool.add_reserve("USDC", 3333, decimals=6)   # 33.33%
    pool.add_reserve("ETH", 3334, decimals=18)   # 33.34%

    # DAO deposits KHU from Treasury
    print("\n[SETUP] DAO deposits from Treasury (T)...")
    pool.deposit_khu("DAO_Treasury", 1_000_000)  # 1M KHU

    # Individual LP deposits
    print("\n[SETUP] Individual LP deposits...")
    pool.deposit_khu("LP_Alice", 100_000)
    pool.deposit_khu("LP_Bob", 100_000)

    # Seed reserves (simulates cross-chain liquidity)
    print("\n[SETUP] Seeding external reserves...")
    pool.seed_reserve("BTC", 10)           # 10 BTC
    pool.seed_reserve("USDC", 400_000)     # 400k USDC
    pool.seed_reserve("ETH", 200)          # 200 ETH

    pool.status()

    # Demo swaps
    print("\n" + "-"*60)
    print("SWAP DEMOS")
    print("-"*60)

    # Swap 1: BTC -> KHU
    print("\n[QUOTE] 0.1 BTC -> KHU")
    q = pool.quote_swap("BTC", 0.1, "KHU")
    print(f"  Amount out: {q['amount_out']:,.2f} KHU")
    print(f"  Fee: {q['fee']:,.2f} KHU")
    print(f"  Price before: {q['price_before']:,.2f} KHU/BTC")
    print(f"  Price after: {q['price_after']:,.2f} KHU/BTC")
    print(f"  Slippage: {q['slippage_bps']/100:.2f}%")

    # Swap 2: KHU -> USDC
    print("\n[QUOTE] 1000 KHU -> USDC")
    q = pool.quote_swap("KHU", 1000, "USDC")
    print(f"  Amount out: {q['amount_out']:,.2f} USDC")
    print(f"  Fee: {q['fee']:,.2f} USDC")

    # Swap 3: Cross-swap BTC -> USDC
    print("\n[QUOTE] 0.1 BTC -> USDC (cross-swap)")
    q = pool.quote_swap("BTC", 0.1, "USDC")
    print(f"  Route: {' -> '.join(q['route'])}")
    print(f"  Intermediate: {q['intermediate_khu']:,.2f} KHU")
    print(f"  Amount out: {q['amount_out']:,.2f} USDC")
    print(f"  Total fee: {q['fee']:,.2f}")

    # Execute a swap and show price impact
    print("\n[EXECUTE] Large swap: 1 BTC -> KHU")
    pool.execute_swap("BTC", 1, "KHU")

    print("\n[AFTER SWAP] Price impact:")
    print(f"  New BTC price: {pool.get_price('BTC'):,.2f} KHU/BTC")
    print(f"  BTC reserve: {pool.reserves['BTC']['reserve']:,.2f}")

    pool.status()

    # Demo: What if DAO adds more liquidity?
    print("\n" + "-"*60)
    print("SCENARIO: DAO votes to add 500k more liquidity")
    print("-"*60)
    pool.deposit_khu("DAO_Treasury_v2", 500_000)

    print("\n[QUOTE] Same 1 BTC swap with more liquidity:")
    q = pool.quote_swap("BTC", 1, "KHU")
    print(f"  Amount out: {q['amount_out']:,.2f} KHU")
    print(f"  Slippage: {q['slippage_bps']/100:.2f}%")
    print("  -> Less slippage with deeper liquidity!")

    pool.status()


if __name__ == "__main__":
    demo_pivot_pool()
