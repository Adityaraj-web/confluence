// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IConfluenceHookView, LegStatus, Plan} from "./ConfluenceSplitter.sol";
import {MakerVenue} from "./libraries/MakerVenue.sol";
import {PoolVenue} from "./libraries/PoolVenue.sol";
import {SplitMath} from "./libraries/SplitMath.sol";

/// @title ConfluenceSplitterOut
/// @notice Plans one EXACT-OUTPUT swap for `ConfluenceHook` (V2-08, D-36): reads the pool (`PoolVenue`) and every
///         registered maker (`MakerVenue.readOut`) at the hook's post-update anchor, solves the cheapest split of the
///         output (`SplitMath.solveExactOut`), keeps at most `MAX_LEGS` legs of at least `MIN_LEG_BPS` of the output and
///         the maker's smallest fill, trims them to the PoolManager's balance of the input token, and quotes the pool for
///         the hook's never-worse check.
/// @dev Stateless and immutable: no storage, no immutables, no owner, one external `view`, the selector `planExactOut`
///      only. It is a second contract because the exact-output planner does not fit beside the exact-input one under
///      EIP-170 (D-36, amending D-35); `ConfluenceSplitter` is unchanged from V2-07. It returns the V2-07 `Plan`,
///      `PLAN_WORDS` static words, with the exact-output meanings below. "Specified" is the output the trader asked for.
///        - `poolIn`: the pool's share of the output;
///        - `amountOut[i]`, `amountIn[i]`: leg `i`'s output and gross input (the router's strict threshold);
///        - `capMin[i]`, `capIn[i]`: the smallest and largest output of one fill of maker `i`, as read;
///        - `poolOut`: the INPUT the pool needs for `poolIn`; `poolOnlyOut`: the input pool-only needs for the whole
///          output, over the walked segments;
///        - `tail`: always 0 (no estimate past the walk);
///        - `walked`: the output the walked segments give; `truncated`: 1 if the walk stopped before the limit.
///      If the walked segments cannot give the whole output, the swap stays pool-only: every planned leg becomes
///      `SKIP_NOT_BETTER`. The walk cannot tell the end of the liquidity from its own bound (D-30), so it never guesses
///      what lies beyond it (D-36; a product gap recorded in PROGRESS).
contract ConfluenceSplitterOut {
    using PoolIdLibrary for PoolKey;

    /// @notice Most maker legs per swap (each is one router call); the same as `ConfluenceSplitter.MAX_LEGS`.
    uint256 public constant MAX_LEGS = 3;
    /// @notice Smallest leg, in basis points of the swap's output.
    uint256 public constant MIN_LEG_BPS = 50;
    /// @notice Solves per plan: the first, and one more after dropping legs (D-35).
    uint256 public constant MAX_SOLVES = 2;
    /// @notice Words in an encoded `Plan`.
    uint256 public constant PLAN_WORDS = 36;

    uint256 private constant BPS = 10_000;

    /// @notice The split of the output `amountOut` for a swap on `key` in direction `zeroForOne` with the swap's own
    ///         price limit, at the anchor (`snapTick`, `emaTickX`) the hook stored for this block. Anyone may call (it is
    ///         a view); `ConfluenceHook.beforeSwap` calls it with a gas cap and checks the result.
    /// @dev Reads the registry, the guard and the PoolManager back from `key.hooks`. Sets every planned leg to
    ///      `FILLED` and every other slot to its skip code. If its own never-worse check fails, every leg becomes
    ///      `SKIP_NOT_BETTER` and the pool takes everything.
    function planExactOut(
        PoolKey calldata key,
        bool zeroForOne,
        uint160 sqrtPriceLimitX96,
        uint256 amountOut,
        int24 snapTick,
        int56 emaTickX
    ) external view returns (Plan memory p) {
        IConfluenceHookView h = IConfluenceHookView(address(key.hooks));
        IPoolManager pm = h.poolManager();
        PoolId id = key.toId();
        PoolVenue.Pool memory pool = PoolVenue.readTo(pm, id, key.tickSpacing, zeroForOne, sqrtPriceLimitX96, amountOut, false);
        MakerVenue.Maker[] memory ms =
            MakerVenue.readOut(pm, key, h.bandGuard(), h.strategiesOf(id), zeroForOne, snapTick, emaTickX);

        uint256 n = Math.min(ms.length, MakerVenue.MAX_MAKERS);
        bool[] memory live = new bool[](ms.length);
        for (uint256 i; i < n; i++) {
            p.capMin[i] = ms[i].capMin;
            p.capIn[i] = ms[i].capOut;
            p.status[i] = _code(ms[i].status);
            live[i] = ms[i].status == MakerVenue.Status.OK;
        }

        // Solve, drop, solve again once.
        SplitMath.Venue[] memory pv = PoolVenue.venues(pool, false);
        uint256[] memory b;
        uint256[] memory idx;
        for (uint256 s; s < MAX_SOLVES; s++) {
            SplitMath.Venue[] memory mv;
            (mv, idx) = _venues(ms, live);
            (b,) = SplitMath.solveExactOut(pv, mv, amountOut);
            if (!_drop(ms, live, idx, b, amountOut, p)) break;
        }
        _legs(ms, live, idx, b, amountOut, IERC20(Currency.unwrap(zeroForOne ? key.currency0 : key.currency1)), pm, p);

        uint256 given = _quotes(pool, amountOut, p);
        if (p.poolIn == amountOut) return p;
        // Not provably cheaper: the walked segments cannot give the whole output (the comparison with pool-only is
        // undefined past the walk), or the split's input is above pool-only's.
        bool better = given >= amountOut;
        if (better) {
            uint256 makersIn = 0;
            for (uint256 i; i < n; i++) {
                makersIn += p.amountIn[i];
            }
            better = p.poolOut + makersIn <= p.poolOnlyOut;
        }
        if (!better) {
            for (uint256 i; i < n; i++) {
                if (p.amountIn[i] == 0) continue;
                p.status[i] = LegStatus.SKIP_NOT_BETTER;
                p.amountIn[i] = 0;
                p.amountOut[i] = 0;
            }
            p.poolIn = amountOut;
            (p.poolOut,,) = PoolVenue.quoteExactOut(pool, amountOut);
        }
    }

    /// @dev The live makers as SplitMath venues, capped at their largest output, and their slot indices.
    function _venues(MakerVenue.Maker[] memory ms, bool[] memory live)
        private
        pure
        returns (SplitMath.Venue[] memory v, uint256[] memory index)
    {
        uint256 len = Math.min(ms.length, MakerVenue.MAX_MAKERS);
        uint256 k = 0;
        for (uint256 i; i < len; i++) {
            if (live[i]) k++;
        }
        v = new SplitMath.Venue[](k);
        index = new uint256[](k);
        k = 0;
        for (uint256 i; i < len; i++) {
            if (!live[i]) continue;
            v[k] = SplitMath.Venue({x: ms[i].x, y: ms[i].y, feeE9: ms[i].feeE9, cap: ms[i].capOut});
            index[k++] = i;
        }
    }

    /// @dev Drops shares that are zero, under the maker's smallest fill or under `MIN_LEG_BPS`, then all but the
    ///      `MAX_LEGS` largest. True if any was dropped.
    function _drop(
        MakerVenue.Maker[] memory ms,
        bool[] memory live,
        uint256[] memory idx,
        uint256[] memory b,
        uint256 amount,
        Plan memory p
    ) private pure returns (bool dropped) {
        uint256 kept = 0;
        uint256 m = Math.min(idx.length, MakerVenue.MAX_MAKERS);
        for (uint256 j; j < m; j++) {
            uint256 i = idx[j];
            if (_tooSmall(b[j + 1], ms[i].capMin, amount)) {
                live[i] = false;
                p.status[i] = LegStatus.SKIP_MIN_LEG;
                dropped = true;
            } else {
                kept++;
            }
        }
        for (uint256 r = 0; r < MakerVenue.MAX_MAKERS && kept > MAX_LEGS; r++) {
            uint256 worst = type(uint256).max;
            uint256 at = 0;
            for (uint256 j; j < m; j++) {
                if (live[idx[j]] && b[j + 1] < worst) (worst, at) = (b[j + 1], idx[j]);
            }
            live[at] = false;
            p.status[at] = LegStatus.SKIP_MIN_LEG;
            kept--;
            dropped = true;
        }
    }

    /// @dev The final legs: the last solve's output shares of the makers still live, largest first. The hook takes the
    ///      legs' total INPUT from the PoolManager before the trader pays, so a leg whose gross input is more than is
    ///      left of its balance of the input token is trimmed to the output of an exact-input fill of what is left (its
    ///      exact-output gross is at most that, `MakerVenue.capsOut`). A leg trimmed under its smallest fill or
    ///      `MIN_LEG_BPS` is dropped. The pool takes the rest of the output.
    function _legs(
        MakerVenue.Maker[] memory ms,
        bool[] memory live,
        uint256[] memory idx,
        uint256[] memory b,
        uint256 amount,
        IERC20 tokenIn,
        IPoolManager pm,
        Plan memory p
    ) private view {
        uint256 pmLeft = tokenIn.balanceOf(address(pm));
        uint256 sumOut = 0;
        uint256 m = Math.min(idx.length, MakerVenue.MAX_MAKERS);
        for (uint256 r; r < MakerVenue.MAX_MAKERS; r++) {
            uint256 best = 0;
            uint256 at = type(uint256).max;
            for (uint256 j; j < m; j++) {
                uint256 i = idx[j];
                if (live[i] && p.amountIn[i] == 0 && b[j + 1] > best) (best, at) = (b[j + 1], i);
            }
            if (at == type(uint256).max) break;
            live[at] = false; // handled
            (, uint256 gross) = MakerVenue.quoteExactOut(ms[at], best);
            uint256 x = best;
            if (gross > pmLeft) (, x) = MakerVenue.quoteExactIn(ms[at], pmLeft);
            if (_tooSmall(x, ms[at].capMin, amount)) {
                p.status[at] = LegStatus.SKIP_MIN_LEG;
                continue;
            }
            (, gross) = MakerVenue.quoteExactOut(ms[at], x);
            p.amountOut[at] = x;
            p.amountIn[at] = gross;
            p.status[at] = LegStatus.FILLED;
            pmLeft -= gross;
            sumOut += x;
        }
        p.poolIn = amount - sumOut;
    }

    /// @dev The pool quotes for the never-worse check (carry-overs 5 and 6). Returns the output the walked segments gave.
    function _quotes(PoolVenue.Pool memory pool, uint256 amount, Plan memory p) private pure returns (uint256 given) {
        uint256 len = pool.segments.length;
        for (uint256 i = 0; i < len && i < PoolVenue.MAX_TICK_RANGES; i++) {
            p.walked += pool.segments[i].capOut;
        }
        p.truncated = pool.truncated ? 1 : 0;
        (p.poolOut,,) = PoolVenue.quoteExactOut(pool, p.poolIn);
        (p.poolOnlyOut, given,) = PoolVenue.quoteExactOut(pool, amount);
    }

    function _tooSmall(uint256 x, uint256 capMin, uint256 amount) private pure returns (bool) {
        return x == 0 || x < capMin || x * BPS < amount * MIN_LEG_BPS;
    }

    function _code(MakerVenue.Status s) private pure returns (uint256) {
        if (s == MakerVenue.Status.OK) return LegStatus.FILLED;
        if (s == MakerVenue.Status.SKIP_BAND) return LegStatus.SKIP_BAND;
        if (s == MakerVenue.Status.SKIP_DRIFT) return LegStatus.SKIP_DRIFT;
        if (s == MakerVenue.Status.SKIP_UNDERFUNDED) return LegStatus.SKIP_UNDERFUNDED;
        return LegStatus.SKIP_MATH;
    }
}
