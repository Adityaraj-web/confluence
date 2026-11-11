"""Venues for the CONFLUENCE reference model (V2-00).

A venue is anything a swap can buy from: a maker's Aqua XYC strategy or one tick range of a v4 pool. Both are
constant-product curves with reserves X (input token), Y (output token) and a fee on the input:

    out(a) = Y * g * a / (X + g * a)        g = 1 - fee

Three kinds of arithmetic live here, and the names say which:

* ``*_real``  : decimal.Decimal at 60 significant digits. Used for the closed form and its comparisons.
* ``*_int``   : integers that mirror the contracts (SwapVM's fee and XYC rounding for makers).
* ``sqrt_price_at_tick``, ``compute_swap_step``, ``pool_swap_exact_in/out``: exact ports of Uniswap v4
  (TickMath, SqrtPriceMath, SwapMath, Pool.swap) so pool-only amounts match the chain to the wei.

Python standard library only.
"""

from decimal import Decimal, getcontext
from typing import NamedTuple, Optional

getcontext().prec = 60

Q96 = 1 << 96
E9 = 10**9  # SwapVM fee scale: 1e9 = 100%
PIPS = 10**6  # v4 fee scale: 1e6 = 100%
MIN_TICK = -887272
MAX_TICK = 887272
MIN_SQRT_PRICE = 4295128739
MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342
MAX_TICK_RANGES = 8  # ARCHITECTURE-v2 section 5
MAX_UINT256 = 2**256 - 1


# --------------------------------------------------------------------------- integer helpers


def mul_div(a, b, d):
    """FullMath.mulDiv: floor(a * b / d)."""
    return (a * b) // d


def mul_div_up(a, b, d):
    """FullMath.mulDivRoundingUp."""
    return -((-(a * b)) // d)


def div_up(a, d):
    """UnsafeMath.divRoundingUp."""
    return -((-a) // d)


# --------------------------------------------------------------------------- constant-product venues


class Venue(NamedTuple):
    """A constant-product venue. ``cap`` is in input units for exact input and in output units for exact
    output; None means no cap. ``x``/``y`` may be int or Decimal."""

    x: object
    y: object
    fee_e9: int
    cap: Optional[object] = None


def gamma(v):
    return Decimal(E9 - v.fee_e9) / Decimal(E9)


def cp_out_real(v, a):
    """Output for gross input ``a`` (Decimal, no rounding)."""
    g = gamma(v)
    x, y, a = Decimal(v.x), Decimal(v.y), Decimal(a)
    return y * g * a / (x + g * a)


def cp_in_real(v, b):
    """Gross input needed for output ``b`` (Decimal, no rounding)."""
    g = gamma(v)
    x, y, b = Decimal(v.x), Decimal(v.y), Decimal(b)
    return x * b / (g * (y - b))


def cp_out_int(v, a):
    """SwapVM exact-in: flat fee rounded up on the input, then XYC rounded down (F02 `_expectedOut`)."""
    net = a - div_up(a * v.fee_e9, E9)
    return (net * v.y) // (v.x + net)


def cp_in_int(v, b):
    """Gross input for exact output ``b``: XYC input rounded up, then the fee grossed up, rounded up."""
    net = div_up(b * v.x, v.y - b)
    return div_up(net * E9, E9 - v.fee_e9)


# --------------------------------------------------------------------------- Uniswap v4 ports

_TICK_RATIOS = [
    (0x2, 0xFFF97272373D413259A46990580E213A),
    (0x4, 0xFFF2E50F5F656932EF12357CF3C7FDCC),
    (0x8, 0xFFE5CACA7E10E4E61C3624EAA0941CD0),
    (0x10, 0xFFCB9843D60F6159C9DB58835C926644),
    (0x20, 0xFF973B41FA98C081472E6896DFB254C0),
    (0x40, 0xFF2EA16466C96A3843EC78B326B52861),
    (0x80, 0xFE5DEE046A99A2A811C461F1969C3053),
    (0x100, 0xFCBE86C7900A88AEDCFFC83B479AA3A4),
    (0x200, 0xF987A7253AC413176F2B074CF7815E54),
    (0x400, 0xF3392B0822B70005940C7A398E4B70F3),
    (0x800, 0xE7159475A2C29B7443B29C7FA6E889D9),
    (0x1000, 0xD097F3BDFD2022B8845AD8F792AA5825),
    (0x2000, 0xA9F746462D870FDF8A65DC1F90E061E5),
    (0x4000, 0x70D869A156D2A1B890BB3DF62BAF32F7),
    (0x8000, 0x31BE135F97D08FD981231505542FCFA6),
    (0x10000, 0x9AA508B5B7A84E1C677DE54F3E99BC9),
    (0x20000, 0x5D6AF8DEDB81196699C329225EE604),
    (0x40000, 0x2216E584F5FA1EA926041BEDFE98),
    (0x80000, 0x48A170391F7DC42444E8FA2),
]


def sqrt_price_at_tick(tick):
    """TickMath.getSqrtPriceAtTick, bit for bit."""
    abs_tick = abs(tick)
    if abs_tick > MAX_TICK:
        raise ValueError(f"tick {tick} out of range")
    price = 0xFFFCB933BD6FAD37AA2D162D1A594001 if abs_tick & 1 else 1 << 128
    for bit, ratio in _TICK_RATIOS:
        if abs_tick & bit:
            price = (price * ratio) >> 128
    if tick > 0:
        price = MAX_UINT256 // price
    return (price + (1 << 32) - 1) >> 32


def tick_at_sqrt_price(sqrt_price):
    """The greatest tick whose sqrt price is <= ``sqrt_price`` (what `initialize` returns)."""
    lo, hi = MIN_TICK, MAX_TICK
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if sqrt_price_at_tick(mid) <= sqrt_price:
            lo = mid
        else:
            hi = mid - 1
    return lo


def liquidity_for_amounts(sqrt_p, sqrt_a, sqrt_b, amount0, amount1):
    """v4-periphery LiquidityAmounts.getLiquidityForAmounts."""
    if sqrt_a > sqrt_b:
        sqrt_a, sqrt_b = sqrt_b, sqrt_a

    def l0(a, b, amt):
        if a > b:
            a, b = b, a
        return mul_div(amt, mul_div(a, b, Q96), b - a)

    def l1(a, b, amt):
        if a > b:
            a, b = b, a
        return mul_div(amt, Q96, b - a)

    if sqrt_p <= sqrt_a:
        return l0(sqrt_a, sqrt_b, amount0)
    if sqrt_p < sqrt_b:
        return min(l0(sqrt_p, sqrt_b, amount0), l1(sqrt_a, sqrt_p, amount1))
    return l1(sqrt_a, sqrt_b, amount1)


def amount0_delta(sqrt_a, sqrt_b, liquidity, round_up):
    if sqrt_a > sqrt_b:
        sqrt_a, sqrt_b = sqrt_b, sqrt_a
    n1 = liquidity << 96
    n2 = sqrt_b - sqrt_a
    if round_up:
        return div_up(mul_div_up(n1, n2, sqrt_b), sqrt_a)
    return mul_div(n1, n2, sqrt_b) // sqrt_a


def amount1_delta(sqrt_a, sqrt_b, liquidity, round_up):
    diff = abs(sqrt_a - sqrt_b)
    amount = mul_div(liquidity, diff, Q96)
    if round_up and (liquidity * diff) % Q96 > 0:
        amount += 1
    return amount


def _next_sqrt_from_amount0_add(sqrt_p, liquidity, amount):
    if amount == 0:
        return sqrt_p
    n1 = liquidity << 96
    return mul_div_up(n1, sqrt_p, n1 + amount * sqrt_p)


def _next_sqrt_from_amount0_remove(sqrt_p, liquidity, amount):
    if amount == 0:
        return sqrt_p
    n1 = liquidity << 96
    product = amount * sqrt_p
    if not n1 > product:
        raise ValueError("PriceOverflow")
    return mul_div_up(n1, sqrt_p, n1 - product)


def _next_sqrt_from_amount1_add(sqrt_p, liquidity, amount):
    return sqrt_p + (amount << 96) // liquidity


def _next_sqrt_from_amount1_remove(sqrt_p, liquidity, amount):
    quotient = div_up(amount << 96, liquidity)
    if not sqrt_p > quotient:
        raise ValueError("NotEnoughLiquidity")
    return sqrt_p - quotient


def next_sqrt_from_input(sqrt_p, liquidity, amount_in, zero_for_one):
    if zero_for_one:
        return _next_sqrt_from_amount0_add(sqrt_p, liquidity, amount_in)
    return _next_sqrt_from_amount1_add(sqrt_p, liquidity, amount_in)


def next_sqrt_from_output(sqrt_p, liquidity, amount_out, zero_for_one):
    if zero_for_one:
        return _next_sqrt_from_amount1_remove(sqrt_p, liquidity, amount_out)
    return _next_sqrt_from_amount0_remove(sqrt_p, liquidity, amount_out)


class Step(NamedTuple):
    sqrt_next: int
    amount_in: int
    amount_out: int
    fee_amount: int


def compute_swap_step(sqrt_cur, sqrt_target, liquidity, amount_remaining, fee_pips):
    """SwapMath.computeSwapStep. ``amount_remaining`` < 0 means exact input, as in Solidity."""
    zero_for_one = sqrt_cur >= sqrt_target
    exact_in = amount_remaining < 0
    if exact_in:
        less_fee = mul_div(-amount_remaining, PIPS - fee_pips, PIPS)
        amount_in = (
            amount0_delta(sqrt_target, sqrt_cur, liquidity, True)
            if zero_for_one
            else amount1_delta(sqrt_cur, sqrt_target, liquidity, True)
        )
        if less_fee >= amount_in:
            sqrt_next = sqrt_target
            fee_amount = amount_in if fee_pips == PIPS else mul_div_up(amount_in, fee_pips, PIPS - fee_pips)
        else:
            amount_in = less_fee
            sqrt_next = next_sqrt_from_input(sqrt_cur, liquidity, less_fee, zero_for_one)
            fee_amount = -amount_remaining - amount_in
        amount_out = (
            amount1_delta(sqrt_next, sqrt_cur, liquidity, False)
            if zero_for_one
            else amount0_delta(sqrt_cur, sqrt_next, liquidity, False)
        )
    else:
        amount_out = (
            amount1_delta(sqrt_target, sqrt_cur, liquidity, False)
            if zero_for_one
            else amount0_delta(sqrt_cur, sqrt_target, liquidity, False)
        )
        if amount_remaining >= amount_out:
            sqrt_next = sqrt_target
        else:
            amount_out = amount_remaining
            sqrt_next = next_sqrt_from_output(sqrt_cur, liquidity, amount_out, zero_for_one)
        amount_in = (
            amount0_delta(sqrt_next, sqrt_cur, liquidity, True)
            if zero_for_one
            else amount1_delta(sqrt_cur, sqrt_next, liquidity, True)
        )
        fee_amount = mul_div_up(amount_in, fee_pips, PIPS - fee_pips)
    return Step(sqrt_next, amount_in, amount_out, fee_amount)


class PoolState(NamedTuple):
    """The slice of a v4 pool a swap reads. ``ticks`` is ((tick, liquidityNet), ...) of initialised ticks."""

    sqrt_price: int
    liquidity: int
    tick: int
    fee_pips: int
    ticks: tuple
    tick_spacing: int


def _next_initialized(state_ticks, tick, zero_for_one):
    """The tick the swap loop runs into next, or None. zeroForOne: greatest initialised tick <= tick;
    otherwise the least initialised tick > tick (as in TickBitmap.nextInitializedTickWithinOneWord)."""
    if zero_for_one:
        c = [t for t, _ in state_ticks if t <= tick]
        return max(c) if c else None
    c = [t for t, _ in state_ticks if t > tick]
    return min(c) if c else None


def _next_in_word(state, tick, zero_for_one):
    """TickBitmap.nextInitializedTickWithinOneWord: (tick, initialised). The nearest initialised tick in the
    same 256-compressed-tick word as the search start, or that word's edge when there is none. The swap loop
    steps to the edge too, and each step rounds on its own, so the exact walk must do the same."""
    sp = state.tick_spacing
    initialised = {t for t, _ in state.ticks}
    compressed = tick // sp  # floors toward -inf, like TickBitmap.compress
    if zero_for_one:
        low = (compressed >> 8) << 8
        for c in range(compressed, low - 1, -1):
            if c * sp in initialised:
                return c * sp, True
        return low * sp, False
    start = compressed + 1
    high = ((start >> 8) << 8) + 255
    for c in range(start, high + 1):
        if c * sp in initialised:
            return c * sp, True
    return high * sp, False


def _net(state_ticks, tick):
    return dict(state_ticks)[tick]


class SwapResult(NamedTuple):
    amount_in: int  # gross, fee included
    amount_out: int
    sqrt_price: int
    liquidity: int
    tick: int
    crossed: int  # initialised ticks crossed
    steps: int  # swap-loop steps (computeSwapStep calls), word-edge stops included


def _pool_swap(state, amount, zero_for_one, exact_in, sqrt_limit, word_edges=True):
    """``word_edges=False`` jumps straight to the nearest initialised tick; it exists only so a test can show
    that the difference is real (a swap that crosses a word edge differs by wei)."""
    if sqrt_limit is None:
        sqrt_limit = MIN_SQRT_PRICE + 1 if zero_for_one else MAX_SQRT_PRICE - 1
    sqrt_p, liq, tick = state.sqrt_price, state.liquidity, state.tick
    remaining = amount  # positive: input left (exact in) or output left (exact out)
    total_in = total_out = crossed = steps = 0
    while remaining != 0 and sqrt_p != sqrt_limit:
        if word_edges:
            tick_next, initialised = _next_in_word(state, tick, zero_for_one)
        else:
            tick_next = _next_initialized(state.ticks, tick, zero_for_one)
            initialised = tick_next is not None
            if tick_next is None:
                tick_next = MIN_TICK if zero_for_one else MAX_TICK
        tick_next = max(MIN_TICK, min(MAX_TICK, tick_next))
        sqrt_next_tick = sqrt_price_at_tick(tick_next)
        target = (
            max(sqrt_next_tick, sqrt_limit) if zero_for_one else min(sqrt_next_tick, sqrt_limit)
        )
        step = compute_swap_step(sqrt_p, target, liq, -remaining if exact_in else remaining, state.fee_pips)
        steps += 1
        if exact_in:
            remaining -= step.amount_in + step.fee_amount
        else:
            remaining -= step.amount_out
        total_in += step.amount_in + step.fee_amount
        total_out += step.amount_out
        sqrt_p = step.sqrt_next
        if sqrt_p == sqrt_next_tick:
            if initialised and tick_next in dict(state.ticks):
                net = _net(state.ticks, tick_next)
                liq += -net if zero_for_one else net
                crossed += 1
            tick = tick_next - 1 if zero_for_one else tick_next
        # else: the swap ended inside the range; the loop exits because `remaining` is 0
    return SwapResult(total_in, total_out, sqrt_p, liq, tick, crossed, steps)


def pool_swap_exact_in(state, amount_in, zero_for_one, sqrt_limit=None, word_edges=True):
    """v4 Pool.swap with amountSpecified = -amount_in, fee on the input, no protocol fee."""
    return _pool_swap(state, amount_in, zero_for_one, True, sqrt_limit, word_edges)


def pool_swap_exact_out(state, amount_out, zero_for_one, sqrt_limit=None, word_edges=True):
    """v4 Pool.swap with amountSpecified = +amount_out."""
    return _pool_swap(state, amount_out, zero_for_one, False, sqrt_limit, word_edges)


# --------------------------------------------------------------------------- the pool as venues


class Segment(NamedTuple):
    """One tick range, as a constant-product venue in the swap's direction. ``cap_in`` is the gross input
    that moves the price to the end of the range; ``cap_out`` is the output at that point. Both None on the
    last segment the walk is allowed to build (the pool takes the rest)."""

    x: object
    y: object
    fee_e9: int
    cap_in: Optional[object]
    cap_out: Optional[object]
    liquidity: int


def pool_segments(state, zero_for_one, max_ranges=MAX_TICK_RANGES, integer=False):
    """The pool's tick ranges in the swap's direction, up to ``max_ranges`` with liquidity.

    A segment is a liquidity range between initialised ticks. The exact walk (`pool_swap_*`) also stops at the
    256-tick word edges of v4's tick bitmap, but those stops split no range: liquidity and the curve are the
    same on both sides, so the solver sees one segment. How V2-02's on-chain PoolVenue counts ranges toward
    MAX_TICK_RANGES is that spec's decision.

    ``integer=False``: Decimal reserves (L / sqrtP and L * sqrtP) and caps. ``integer=True``: floored reserves
    and the integer caps from the v4 delta functions (what PoolVenue will read on chain)."""
    segs = []
    sqrt_p, liq, tick = state.sqrt_price, state.liquidity, state.tick
    sqrt_limit = MIN_SQRT_PRICE + 1 if zero_for_one else MAX_SQRT_PRICE - 1
    guard = len(state.ticks) + 2
    while guard > 0:
        guard -= 1
        tick_next = _next_initialized(state.ticks, tick, zero_for_one)
        if tick_next is None:
            target = sqrt_limit
        else:
            sqrt_t = sqrt_price_at_tick(tick_next)
            target = max(sqrt_t, sqrt_limit) if zero_for_one else min(sqrt_t, sqrt_limit)
        if liq > 0 and sqrt_p != target:
            segs.append(_segment(sqrt_p, liq, target, zero_for_one, state.fee_pips, integer))
            if len(segs) == max_ranges:
                segs[-1] = segs[-1]._replace(cap_in=None, cap_out=None)
                break
        if tick_next is None:
            break
        net = _net(state.ticks, tick_next)
        liq += -net if zero_for_one else net
        sqrt_p = target
        tick = tick_next - 1 if zero_for_one else tick_next
    return segs


def _segment(sqrt_p, liq, target, zero_for_one, fee_pips, integer):
    if zero_for_one:
        net_in = amount0_delta(target, sqrt_p, liq, True)
        out = amount1_delta(target, sqrt_p, liq, False)
    else:
        net_in = amount1_delta(sqrt_p, target, liq, True)
        out = amount0_delta(sqrt_p, target, liq, False)
    cap_in = mul_div_up(net_in, PIPS, PIPS - fee_pips)
    if integer:
        if zero_for_one:
            x, y = mul_div(liq, Q96, sqrt_p), mul_div(liq, sqrt_p, Q96)
        else:
            x, y = mul_div(liq, sqrt_p, Q96), mul_div(liq, Q96, sqrt_p)
    else:
        sp = Decimal(sqrt_p) / Decimal(Q96)
        lq = Decimal(liq)
        x, y = (lq / sp, lq * sp) if zero_for_one else (lq * sp, lq / sp)
        cap_in, out = Decimal(cap_in), Decimal(out)
    return Segment(x, y, fee_pips * 1000, cap_in, out, liq)


# --------------------------------------------------------------------------- the v1 demo pool

V1_TICK_SPACING = 60
V1_HALF_RANGE = 600
V1_FEE_PIPS = 3000
V1_SEED_USDC = 2_500 * 10**6
V1_SEED_MUMB = 2_500 * 10**18


def floor_to_spacing(tick, spacing):
    return (tick // spacing) * spacing  # Python floors toward -inf, like PoolBase._floorToSpacing


def v1_demo_pool(usdc_is_currency0):
    """The pool PoolBase._createPool builds (F04): MUMB/USDC at 1 MUMB = 1 USDC, fee 0.30%, spacing 60,
    one position of about 2,500 of each token over the anchor tick (floored to the spacing) plus/minus 600."""
    sqrt_p = Q96 * 10**6 if usdc_is_currency0 else Q96 // 10**6
    tick = tick_at_sqrt_price(sqrt_p)
    centre = floor_to_spacing(tick, V1_TICK_SPACING)
    lower, upper = centre - V1_HALF_RANGE, centre + V1_HALF_RANGE
    a0, a1 = (V1_SEED_USDC, V1_SEED_MUMB) if usdc_is_currency0 else (V1_SEED_MUMB, V1_SEED_USDC)
    liq = liquidity_for_amounts(sqrt_p, sqrt_price_at_tick(lower), sqrt_price_at_tick(upper), a0, a1)
    return PoolState(sqrt_p, liq, tick, V1_FEE_PIPS, ((lower, liq), (upper, -liq)), V1_TICK_SPACING)
