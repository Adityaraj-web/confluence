// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ConfluenceSplitter, LegStatus, Plan} from "../ConfluenceSplitter.sol";
import {ConfluenceSplitterOut} from "../ConfluenceSplitterOut.sol";
import {MakerVenue} from "./MakerVenue.sol";
import {PoolVenue} from "./PoolVenue.sol";

/// @title PlanCheck
/// @notice The hook's decision about a splitter's plan, in one place (V2-09, D-37): the capped call to the splitter,
///         and the checks on what it returns. `ConfluenceHook` runs it on every swap; `ConfluenceLens` runs the same
///         code to quote, so a plan the hook would refuse is quoted as pool-only by the same lines. Moved verbatim out
///         of the hook (`_plan`, `_checkPlan`); the only change is that the constants live here and the hook aliases
///         them.
/// @dev Internal and stateless; both functions are `view`. The PoolManager's balance of the input token is read inside
///      `check`, only for a plan that has legs (D-35), exactly as the hook always did.
library PlanCheck {
    /// @notice Most maker legs per swap; a plan with more is refused.
    uint256 internal constant MAX_LEGS = 3;
    /// @notice Smallest leg, in basis points of the swap's specified amount; a plan with a smaller one is refused.
    uint256 internal constant MIN_LEG_BPS = 50;
    /// @notice Gas kept back for the rest of the swap after the plan and after each leg (D-20, V2-07).
    uint256 internal constant GAS_RESERVE = 170_000;
    /// @notice Least gas a leg is started with.
    uint256 internal constant MIN_LEG_GAS = 160_000;
    /// @notice Most gas one leg's router call may use.
    uint256 internal constant LEG_GAS_CAP = 640_000;
    /// @notice Most gas the splitter call may use.
    uint256 internal constant PLAN_GAS_CAP = 1_700_000;
    /// @notice Bytes of an encoded `Plan`; any other return length means pool-only.
    uint256 internal constant PLAN_BYTES = 36 * 32;
    /// @dev Worst-case gas of one swap-loop step of the pool that crosses an initialised tick (V2-11, lever 8): cold
    ///      reads, two fresh tick slots written, both fee-growth globals nonzero. Measured 55,873 (first crossing) and
    ///      51,523 to 53,330 after it (`test_V211_stepCost`); 60,000 keeps 7% on the worst.
    uint256 internal constant STEP_GAS = 60_000;
    /// @dev The reserve for a walk that did not cover the amount (its crossings are unknown) and for the gate before the
    ///      plan call (the crossings are not known until it returns): `GAS_RESERVE` plus `PoolVenue.MAX_TICK_STEPS` steps.
    uint256 internal constant RESERVE_MAX = GAS_RESERVE + STEP_GAS * PoolVenue.MAX_TICK_STEPS;

    uint256 private constant _BPS = 10_000;
    // casting to 'uint128' is safe: int128 max is positive
    // forge-lint: disable-next-line(unsafe-typecast)
    uint256 private constant _MAX_INT128 = uint256(uint128(type(int128).max));

    /// @notice STUB (V2-11 red step).
    function reserve(Plan memory) internal pure returns (uint256) {
        return GAS_RESERVE;
    }

    /// @dev Calls the splitter with a gas cap (low-level, so malformed data cannot revert), then checks the plan.
    /// Returns `LegStatus.FILLED` for a plan to run, `SKIP_GAS` or `SKIP_PLAN` for pool-only. `target` is the
    /// splitter for the swap's mode (the caller picks it); `exactIn` picks the function.
    function plan(
        address target,
        IPoolManager poolManager,
        PoolKey calldata key,
        bool zeroForOne,
        uint160 sqrtPriceLimitX96,
        uint256 amount,
        int24 snapTick,
        int56 emaTickX,
        uint256 n,
        bool exactIn
    ) internal view returns (uint8 code, Plan memory p) {
        uint256 g = gasleft();
        if (g < GAS_RESERVE + MIN_LEG_GAS) return (LegStatus.SKIP_GAS, p);
        // The two plan functions take the same arguments; only the selector differs.
        bytes memory data = abi.encodeWithSelector(
            exactIn ? ConfluenceSplitter.planExactIn.selector : ConfluenceSplitterOut.planExactOut.selector,
            key,
            zeroForOne,
            sqrtPriceLimitX96,
            amount,
            snapTick,
            emaTickX
        );
        bytes memory ret = new bytes(PLAN_BYTES);
        uint256 gasCap = Math.min(g - GAS_RESERVE, PLAN_GAS_CAP);
        uint256 len = PLAN_BYTES;
        bool ok;
        assembly ("memory-safe") {
            // Nothing is copied unless the return is exactly `len` bytes long.
            ok := staticcall(gasCap, target, add(data, 0x20), mload(data), 0, 0)
            ok := and(ok, eq(returndatasize(), len))
            if ok { returndatacopy(add(ret, 0x20), 0, len) }
        }
        if (!ok) return (LegStatus.SKIP_PLAN, p);
        // Exactly PLAN_BYTES of static words: this decode cannot revert.
        p = abi.decode(ret, (Plan));
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        if (!check(p, poolManager, tokenIn, amount, n, exactIn)) return (LegStatus.SKIP_PLAN, p);
        return (LegStatus.FILLED, p);
    }

    /// @dev The hook's own checks on a plan (D-35, D-36): valid codes; each leg for a registered slot, within the maker's
    /// [capMin, capIn] as read and at least `MIN_LEG_BPS`, in the swap's specified units (input for exact input, output
    /// for exact output); at most `MAX_LEGS`; the legs and the pool's share sum to the amount; the legs' total input
    /// within the PoolManager's balance of the input token (read here, only when the plan has legs); the other side
    /// within int128; no pool share past a truncated walk, and for exact output no plan unless the walked segments give
    /// the whole output; and the split's quoted other side no worse than pool-only's (at least the output plus the
    /// tail bound for exact input, at most the input for exact output, whose tail is 0). Every operation is bounded so
    /// that no plan can make it revert.
    function check(Plan memory p, IPoolManager poolManager, address tokenIn, uint256 amount, uint256 n, bool exactIn)
        internal
        view
        returns (bool)
    {
        uint256 sumSp = 0;
        uint256 sumOt = 0;
        uint256 count = 0;
        for (uint256 i; i < MakerVenue.MAX_MAKERS; i++) {
            (uint256 sp, uint256 ot) = exactIn ? (p.amountIn[i], p.amountOut[i]) : (p.amountOut[i], p.amountIn[i]);
            if (i < n && p.status[i] > LegStatus.MAX_CODE) return false;
            if (sp == 0) {
                if (ot != 0 && !exactIn) return false;
                continue;
            }
            if (i >= n || sp > amount || sp < p.capMin[i] || sp > p.capIn[i]) return false;
            if (sp * _BPS < amount * MIN_LEG_BPS || ot > _MAX_INT128 || (ot == 0 && !exactIn)) return false;
            count++;
            sumSp += sp;
            sumOt += ot;
        }
        if (count == 0) return true;
        if (count > MAX_LEGS || sumSp > amount || p.poolIn != amount - sumSp || sumOt > _MAX_INT128) return false;
        // forge-lint: disable-next-line(calls-loop)
        if ((exactIn ? sumSp : sumOt) > IERC20(tokenIn).balanceOf(address(poolManager))) return false;
        if (p.poolOut > _MAX_INT128 || p.poolOnlyOut > _MAX_INT128 || p.tail > _MAX_INT128) return false;
        if (p.truncated != 0 && p.poolIn > p.walked) return false;
        if (exactIn) return p.poolOut + sumOt >= p.poolOnlyOut + p.tail;
        // Exact output: the walked segments must give the whole output (no estimate past the walk, D-36).
        return p.tail == 0 && p.walked >= amount && p.poolOut + sumOt <= p.poolOnlyOut;
    }
}
