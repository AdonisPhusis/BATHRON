#!/usr/bin/env python3
"""
Compare Order Book vs True AMM models for BATHRON Cold Lots

This script demonstrates the fundamental difference between:
1. Order Book Model: LP sets prices, matcher finds best LOTs
2. AMM Model: Formula determines price, virtual reserves track state
"""

class OrderBookModel:
    """
    LOTs with individual prices = Order Book
    LP must set prices, no automatic pricing
    """

    def __init__(self):
        # Each LOT has: owner, amount, price (KHU per BTC)
        self.lots = []
        self.executed_trades = []

    def add_lot(self, owner, amount_khu, price_khu_per_btc):
        """LP creates a LOT at a specific price"""
        self.lots.append({
            'owner': owner,
            'amount': amount_khu,
            'price': price_khu_per_btc,
            'available': True
        })

    def get_best_price(self, side='buy_khu'):
        """Get best available price"""
        available = [l for l in self.lots if l['available']]
        if not available:
            return None
        if side == 'buy_khu':
            # Buyer wants lowest price (most KHU per BTC)
            return max(available, key=lambda x: x['price'])
        else:
            return min(available, key=lambda x: x['price'])

    def execute_swap(self, btc_amount):
        """
        Swap BTC → KHU using order book matching
        Returns KHU received
        """
        khu_received = 0
        btc_remaining = btc_amount

        # Sort by best price for buyer (highest KHU/BTC)
        available = sorted(
            [l for l in self.lots if l['available']],
            key=lambda x: x['price'],
            reverse=True
        )

        for lot in available:
            if btc_remaining <= 0:
                break

            # How much BTC needed to buy this LOT?
            btc_needed = lot['amount'] / lot['price']

            if btc_remaining >= btc_needed:
                # Take whole LOT
                khu_received += lot['amount']
                btc_remaining -= btc_needed
                lot['available'] = False
            else:
                # Partial fill (if LOTs were divisible)
                khu_partial = btc_remaining * lot['price']
                khu_received += khu_partial
                lot['amount'] -= khu_partial
                btc_remaining = 0

        return khu_received, btc_amount - btc_remaining

    def show_orderbook(self):
        print("\n=== ORDER BOOK MODEL ===")
        print("LOTs available (sorted by price):")
        available = sorted(
            [l for l in self.lots if l['available']],
            key=lambda x: x['price'],
            reverse=True
        )
        for lot in available[:10]:
            print(f"  {lot['amount']:.0f} KHU @ {lot['price']:,.0f} KHU/BTC ({lot['owner']})")


class AMMModel:
    """
    True AMM with virtual reserves
    Formula determines price automatically
    """

    def __init__(self):
        self.khu_pool = 0           # Real KHU (LOTs)
        self.btc_virtual = 0        # Virtual reserve (just a number!)
        self.k = 0                  # Constant product

    def initialize(self, khu_amount, initial_btc_virtual):
        """
        Set up pool with real KHU and virtual BTC reserve
        """
        self.khu_pool = khu_amount
        self.btc_virtual = initial_btc_virtual
        self.k = self.khu_pool * self.btc_virtual

    def get_price(self):
        """Current price from formula"""
        if self.btc_virtual == 0:
            return 0
        return self.khu_pool / self.btc_virtual

    def quote_swap(self, btc_in):
        """Calculate KHU output for given BTC input"""
        new_btc = self.btc_virtual + btc_in
        new_khu = self.k / new_btc
        khu_out = self.khu_pool - new_khu
        return khu_out

    def execute_swap(self, btc_in):
        """
        Execute swap:
        - BTC is NOT received (stays with trader)
        - Virtual reserve is incremented
        - Real KHU is released from pool
        """
        khu_out = self.quote_swap(btc_in)

        # Update state
        self.btc_virtual += btc_in      # Virtual increment
        self.khu_pool -= khu_out        # Real decrement

        return khu_out

    def show_state(self):
        print("\n=== AMM MODEL ===")
        print(f"KHU Pool (REAL):     {self.khu_pool:,.2f} KHU")
        print(f"BTC Reserve (VIRTUAL): {self.btc_virtual:.4f} BTC")
        print(f"k (constant):          {self.k:,.0f}")
        print(f"Price:                 {self.get_price():,.2f} KHU/BTC")


def demo_comparison():
    print("="*70)
    print("ORDER BOOK vs AMM MODEL COMPARISON")
    print("="*70)

    # === ORDER BOOK MODEL ===
    ob = OrderBookModel()

    # LPs create LOTs at different prices
    print("\n[ORDER BOOK] LPs create LOTs with individual prices:")
    ob.add_lot("Alice", 10000, 40000)   # 10k KHU @ 40,000
    ob.add_lot("Alice", 10000, 40000)
    ob.add_lot("Bob", 10000, 40100)     # Slightly more expensive
    ob.add_lot("Bob", 10000, 40100)
    ob.add_lot("Carol", 10000, 39900)   # Cheaper!
    ob.add_lot("Carol", 10000, 39900)

    ob.show_orderbook()

    # Trader swaps 0.1 BTC
    print("\n[ORDER BOOK] Trader swaps 0.1 BTC:")
    khu_received, btc_used = ob.execute_swap(0.1)
    print(f"  → Received: {khu_received:,.2f} KHU")
    print(f"  → Used: {btc_used:.4f} BTC")
    print(f"  → Effective price: {khu_received/btc_used:,.2f} KHU/BTC")
    print(f"  → Best LOTs matched first (Carol's @ 39,900)")

    # === AMM MODEL ===
    amm = AMMModel()

    # Initialize with same total liquidity
    print("\n[AMM] Initialize pool:")
    amm.initialize(60000, 1.5)  # 60k KHU, 1.5 BTC virtual
    amm.show_state()

    # Trader swaps 0.1 BTC
    print("\n[AMM] Trader swaps 0.1 BTC:")
    khu_out = amm.execute_swap(0.1)
    print(f"  → Received: {khu_out:,.2f} KHU")
    print(f"  → Effective price: {khu_out/0.1:,.2f} KHU/BTC")
    print(f"  → Price determined by formula, not LP choice")

    amm.show_state()

    # === KEY INSIGHT ===
    print("\n" + "="*70)
    print("KEY INSIGHT: WHERE DOES THE BTC GO?")
    print("="*70)
    print("""
    ORDER BOOK MODEL:
    ─────────────────
    1. Trader locks BTC in HTLC
    2. LP (Carol) receives BTC when claiming HTLC
    3. Carol now has 0.025 BTC instead of 1000 KHU
    4. BTC flows: Trader → LP
    5. It's a REAL trade between two parties

    AMM MODEL (Virtual Reserves):
    ─────────────────────────────
    1. Trader locks BTC in HTLC
    2. ??? Who receives the BTC ???

    Options:
    A) BTC goes to LP pro-rata → Complex, LP must claim
    B) BTC goes to MN multisig → Custody risk
    C) BTC stays with trader → "Proof of Lock" model
    D) BTC goes to "reserve address" → Need custody

    PROBLEM: AMM needs someone to HOLD the external asset!
    """)

    print("\n" + "="*70)
    print("HYBRID SOLUTION: AMM Pricing + Order Book Settlement")
    print("="*70)
    print("""
    Combine both models:

    1. PRICING: Use AMM formula (x*y=k) for price discovery
       - No LP needs to set prices manually
       - Price adjusts automatically with volume

    2. SETTLEMENT: Use Order Book mechanism for BTC flow
       - When trader buys KHU, specific LP's LOT is matched
       - That LP receives the BTC (via HTLC)
       - LP is the counterparty, not "the pool"

    Flow:
    ─────
    1. Trader wants 4000 KHU
    2. AMM formula says: costs 0.1 BTC at current price
    3. System matches with LP_Alice's LOT (oldest/random)
    4. LP_Alice's LOT releases 4000 KHU to Trader
    5. LP_Alice claims 0.1 BTC from HTLC
    6. Virtual reserve updates for price tracking
    7. LP_Alice is now "out" (has BTC instead of KHU)

    Result:
    - Price discovery: AMM (automatic)
    - Settlement: Order Book (LP ↔ Trader)
    - Custody: None (LP holds BTC, not protocol)
    """)


def demo_hybrid_model():
    print("\n" + "="*70)
    print("HYBRID MODEL SIMULATION")
    print("="*70)

    class HybridPool:
        def __init__(self):
            # AMM state (for pricing)
            self.khu_total = 0
            self.btc_virtual = 0

            # Order book state (for settlement)
            self.lots = []  # {owner, amount, deposit_time}

        def deposit(self, owner, amount_khu):
            """LP deposits KHU into pool"""
            self.khu_total += amount_khu
            self.lots.append({
                'owner': owner,
                'amount': amount_khu,
                'time': len(self.lots)  # Simple ordering
            })
            print(f"[DEPOSIT] {owner} added {amount_khu:,} KHU")

        def set_initial_price(self, price_khu_per_btc):
            """Set initial price by setting virtual BTC"""
            self.btc_virtual = self.khu_total / price_khu_per_btc
            print(f"[INIT] Price set to {price_khu_per_btc:,} KHU/BTC")
            print(f"       Virtual BTC reserve: {self.btc_virtual:.4f}")

        def get_price(self):
            return self.khu_total / self.btc_virtual if self.btc_virtual > 0 else 0

        def swap_btc_to_khu(self, btc_in, trader_name):
            """
            Hybrid swap:
            - Price from AMM formula
            - Settlement via specific LP's LOT
            """
            # 1. Calculate output using AMM formula
            k = self.khu_total * self.btc_virtual
            new_btc = self.btc_virtual + btc_in
            new_khu = k / new_btc
            khu_out = self.khu_total - new_khu

            # 2. Find LP to match (FIFO - oldest first)
            matched_lp = None
            for lot in self.lots:
                if lot['amount'] >= khu_out:
                    matched_lp = lot
                    break

            if not matched_lp:
                print(f"[ERROR] No single LOT large enough for {khu_out:.2f} KHU")
                return

            # 3. Execute settlement
            old_price = self.get_price()
            matched_lp['amount'] -= khu_out
            self.khu_total -= khu_out
            self.btc_virtual = new_btc

            print(f"\n[SWAP] {trader_name}: {btc_in} BTC → {khu_out:,.2f} KHU")
            print(f"       Price: {old_price:,.2f} → {self.get_price():,.2f} KHU/BTC")
            print(f"       Matched with: {matched_lp['owner']}")
            print(f"       {matched_lp['owner']} receives {btc_in} BTC (via HTLC claim)")
            print(f"       {matched_lp['owner']} remaining: {matched_lp['amount']:,.2f} KHU")

        def status(self):
            print(f"\n[POOL STATUS]")
            print(f"  Total KHU: {self.khu_total:,.2f}")
            print(f"  Virtual BTC: {self.btc_virtual:.4f}")
            print(f"  Price: {self.get_price():,.2f} KHU/BTC")
            print(f"  LPs:")
            for lot in self.lots:
                if lot['amount'] > 0:
                    print(f"    {lot['owner']}: {lot['amount']:,.2f} KHU")

    # Demo
    pool = HybridPool()

    # LPs deposit
    pool.deposit("Alice", 30000)
    pool.deposit("Bob", 20000)
    pool.deposit("Carol", 10000)

    # Set initial price
    pool.set_initial_price(40000)

    pool.status()

    # Swaps
    pool.swap_btc_to_khu(0.1, "Trader1")
    pool.swap_btc_to_khu(0.5, "Trader2")
    pool.swap_btc_to_khu(0.2, "Trader3")

    pool.status()

    print("\n" + "="*70)
    print("CONCLUSION")
    print("="*70)
    print("""
    Le modèle HYBRID combine:

    ✓ AMM Pricing: Prix automatique via x*y=k
    ✓ Order Book Settlement: LP spécifique reçoit le BTC
    ✓ No Custody: Pas de "pool BTC", LP claim directement
    ✓ Cold LP: LP peut être cold (MN 8/12 release)

    C'est un ORDER BOOK avec PRICING AMM automatique!
    """)


if __name__ == "__main__":
    demo_comparison()
    demo_hybrid_model()
