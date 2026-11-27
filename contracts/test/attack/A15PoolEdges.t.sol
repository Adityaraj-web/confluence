// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {PoolVenue} from "../../src/libraries/PoolVenue.sol";
import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 (carry-over from V2-07 and V2-08): the edges of the pool leg.
///         (1) Whole-amount fills: when the makers take the WHOLE amount the hook returns a delta that zeroes the pool's
///         amount, and the PoolManager returns before its price-limit checks (`Pool.sol:320`). A swap with a `sqrtPriceLimit`
///         the pool alone refuses (`PriceLimitAlreadyExceeded`) therefore succeeds through the hook. This is behaviour, not a
///         bug: the limit bounds the pool's own price impact, the pool is untouched, and the trader's own minimum still binds.
///         (2) Never worse on a truncated walk with thin makers, both modes, 3,000 runs each on the fork.
contract A15PoolEdgesTest is AttackBase {
    using StateLibrary for IPoolManager;

    function _raw(PoolKey memory k, bool zfo, int256 spec, uint160 limit) internal returns (int128 a0, int128 a1) {
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        BalanceDelta d = swapRouter.swap(
            k,
            IPoolManager.SwapParams({zeroForOne: zfo, amountSpecified: spec, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        return (d.amount0(), d.amount1());
    }

    /// @dev External wrapper so `vm.expectPartialRevert` sees the revert of a nested call.
    function rawExternal(PoolKey memory k, bool zfo, int256 spec, uint160 limit) external {
        _raw(k, zfo, spec, limit);
    }

    /// @dev One generous maker priced 1% better than the pool, fee 0.05%, so it takes a small trade entirely.
    function _generousMaker() internal {
        _attackInit();
        _initExact(keyV2);
        (int24 snap,,) = hookV2.anchorOf(idV2);
        uint256 usdcAmt = 100_000e6;
        _joinM(keyV2, makers[0], _mumbAt(usdcAmt, snap + 100), usdcAmt, _pf(FEE_005)); // 100 ticks = 1% more MUMB per USDC
    }

    function _wholeAmountExactIn() internal {
        _generousMaker();
        uint160 bad = TickMath.MAX_SQRT_PRICE - 1; // USDC in lowers the price: this limit is on the wrong side
        int256 spec = -int256(100e6);
        (uint160 sp0,,,) = manager.getSlot0(idV2);
        uint256 s = vm.snapshotState();
        _unregisterAll(keyV2); // the pool alone refuses the limit
        vm.expectPartialRevert(Pool.PriceLimitAlreadyExceeded.selector);
        this.rawExternal(keyV2, true, spec, bad);
        require(vm.revertToStateAndDelete(s), "revert failed");

        vm.recordLogs();
        (int128 d0, int128 d1) = _raw(keyV2, true, spec, bad); // through the hook it succeeds
        (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
        (uint160 sp1,,,) = manager.getSlot0(idV2);
        (uint256 sumIn, uint256 sumOut) = _sumLegs(legs);
        assertEq(uint256(uint128(-d0)), 100e6, "the trader paid the whole amount");
        assertEq(sumIn, 100e6, "non-vacuous: the makers took the whole amount");
        assertEq(uint256(uint128(d1)), sumOut, "the trader got what the makers gave");
        assertEq(sp1, sp0, "the pool's price did not move: its limit was never needed");
        _assertClean();
    }

    function test_V210_wholeAmountExactInIgnoresAnInvalidPriceLimit() public {
        _wholeAmountExactIn();
    }

    /// @dev Exact output is different, and the difference is recorded: the exact-output splitter prices the pool leg from a
    ///      walk that ENDS at the trader's limit, and it stays pool-only unless the walked segments can give all of the
    ///      output (D-36). With a limit on the wrong side the walk is empty, so the plan is pool-only and the swap reverts
    ///      exactly as the pool alone does. With a valid limit the same maker gives the whole output (non-vacuity).
    function test_V210_wholeAmountExactOutKeepsThePriceLimit() public {
        _generousMaker();
        uint160 bad = TickMath.MAX_SQRT_PRICE - 1;
        uint256 s = vm.snapshotState();
        vm.recordLogs();
        _raw(keyV2, true, int256(100e18), TickMath.MIN_SQRT_PRICE + 1); // a valid limit
        (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
        (, uint256 sumOut) = _sumLegs(legs);
        assertEq(sumOut, 100e18, "non-vacuous: with a valid limit the maker gives the whole output");
        require(vm.revertToStateAndDelete(s), "revert failed");
        vm.expectPartialRevert(Pool.PriceLimitAlreadyExceeded.selector);
        this.rawExternal(keyV2, true, int256(100e18), bad); // through the hook: refused, as pool-only
    }

    // ---------------------------------------------------------------- truncated walk, thin makers, both modes

    /// @dev Exact input: the coverage generator of V2-07 (a truncated-walk pool, 1 to 6 thin makers with a 6% band, an
    ///      amount just past the walk) as a fuzz, 3,000 runs. The V2-07 fuzz's own domain never reached the case where the
    ///      pool's share would pass the truncated walk (0 of 24 seeds).
    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_V210_truncatedWalkNeverWorseExactIn(uint256 seed, bool zfo, uint256 amountRaw, uint8 nRaw)
        public
    {
        _neverWorseCase(seed, zfo, amountRaw, nRaw, true, true);
    }

    function _walkedOut(PoolKey memory k, bool zfo) internal view returns (uint256 w) {
        PoolVenue.Pool memory p = PoolVenue.read(manager, k.toId(), k.tickSpacing, zfo, _lim(zfo));
        for (uint256 i; i < p.segments.length; i++) {
            w += p.segments[i].capOut;
        }
    }

    function _outSwap(PoolKey memory k, bool zfo, uint256 b) internal returns (uint256 paid, uint256 got) {
        (address tIn, address tOut) = _io(k, zfo);
        uint256 inB = IERC20(tIn).balanceOf(trader);
        uint256 outB = IERC20(tOut).balanceOf(trader);
        _swap(k, trader, zfo, int256(b), "");
        paid = inB - IERC20(tIn).balanceOf(trader);
        got = IERC20(tOut).balanceOf(trader) - outB;
    }

    /// @dev Exact output on the same thin, truncated shape: the trader gets exactly B and never pays more than pool-only,
    ///      or, when the pool alone is short of B, exactly what pool-only gives (a partial fill, D-36).
    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_V210_truncatedWalkNeverWorseExactOut(uint256 seed, bool zfo, uint256 amountRaw, uint8 nRaw)
        public
    {
        PoolKey memory k = _gapKey();
        _initExact(k);
        (int24 snap,,) = hookV2.anchorOf(k.toId());
        uint256 n = bound(nRaw, 1, MAX_FUZZ_MAKERS);
        uint32[5] memory fees = [uint32(500_000), 1_000_000, 3_000_000, 5_000_000, 10_000_000];
        for (uint256 i; i < n; i++) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            uint256 usdcRaw = bound(h, 200, 3_000) * USDC_1;
            int24 off = int24(int256(bound(h >> 64, 0, 300))) - 150;
            StrategyTemplate.Params memory p = _pf(fees[(h >> 128) % 5]);
            p.bandBps = 600;
            _joinM(k, makers[i], _mumbAt(usdcRaw, snap + off), usdcRaw, p);
        }
        uint256 unit = zfo ? MUMB_1 : USDC_1; // the output token's unit
        uint256 b = _walkedOut(k, zfo) + bound(amountRaw, 1, 300) * unit;
        uint256 s = vm.snapshotState();
        _unregisterAll(k);
        (uint256 poPaid, uint256 poGot) = _outSwap(k, zfo, b);
        require(vm.revertToStateAndDelete(s), "revert failed");
        (uint256 paid, uint256 got) = _outSwap(k, zfo, b);
        if (poGot < b) {
            assertEq(got, poGot, "pool short of B: exactly pool-only (output)");
            assertEq(paid, poPaid, "pool short of B: exactly pool-only (input)");
        } else {
            assertEq(got, b, "the trader gets exactly B");
            assertLe(paid, poPaid, "never pays more than the real pool-only swap");
        }
        assertEq(IERC20(USDC).balanceOf(address(hookV2)) + mumb.balanceOf(address(hookV2)), 0, "hook holds nothing");
    }
}
