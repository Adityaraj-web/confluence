// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {ConfluenceLens} from "../../src/ConfluenceLens.sol";
import {ConfluenceSplitter, LegStatus, Plan} from "../../src/ConfluenceSplitter.sol";
import {ConfluenceSplitterOut} from "../../src/ConfluenceSplitterOut.sol";
import {MakerVenue} from "../../src/libraries/MakerVenue.sol";
import {PoolVenue} from "../../src/libraries/PoolVenue.sol";
import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {SplitBase} from "../base/SplitBase.t.sol";

/// @notice V2-09: quoting parity. The Lens (view, breakdown) and the real V4Quoter (runs the hook inside a reverting
///         unlock) must equal a real swap from the same `vm.snapshotState()`, to the wei.
contract V209QuotingTest is SplitBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Uniswap's V4Quoter, deployed on mainnet at FORK_BLOCK (the spec's [VERIFY]: no deploy needed).
    IV4Quoter internal constant QUOTER = IV4Quoter(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203);
    /// @dev 7 slots: the largest in-test registry is 6; `GAS_RESERVE + MIN_LEG_GAS` = 330,000 is the hook's precheck.
    uint256 internal constant HOOK_PRECHECK = 330_000;
    /// @dev A tx gas limit that cannot leave 330,000 at the hook: below it the hook's own precheck trips.
    uint256 internal constant CLEARLY_LESS = 320_000;
    /// @dev Gas the pool side of a swap and the router need on top of the hook's bound (pool-only swap: 240,012).
    uint256 internal constant POOL_SIDE_GAS = 300_000;

    ConfluenceLens internal lens;

    /// @dev The Lens, deployed on first use (`SplitBase.setUp` is not virtual, and a contract made before the fork is
    ///      selected would not exist on it).
    function L() internal returns (ConfluenceLens) {
        if (address(lens).code.length == 0) lens = new ConfluenceLens();
        return lens;
    }

    // =====================================================================================================
    // Helpers
    // =====================================================================================================

    function _spec(bool exactIn, uint256 amount) internal pure returns (int256) {
        // casting to 'int256' is safe: the amounts used here are far below 2^255
        // forge-lint: disable-next-line(unsafe-typecast)
        return exactIn ? -int256(amount) : int256(amount);
    }

    function _runMode(PoolKey memory k, bool exactIn, bool zfo, uint256 amount) internal returns (Run memory r) {
        (address tIn, address tOut) = _io(k, zfo);
        uint256 inB = IERC20(tIn).balanceOf(trader);
        uint256 outB = IERC20(tOut).balanceOf(trader);
        vm.recordLogs();
        _swap(k, trader, zfo, _spec(exactIn, amount), "");
        (r.legs, r.emitted) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
        r.paid = inB - IERC20(tIn).balanceOf(trader);
        r.got = IERC20(tOut).balanceOf(trader) - outB;
    }

    function _poolOnlyMode(PoolKey memory k, bool exactIn, bool zfo, uint256 amount) internal returns (Run memory r) {
        uint256 s = vm.snapshotState();
        _unregisterAll(k);
        r = _runMode(k, exactIn, zfo, amount);
        require(vm.revertToStateAndDelete(s), "revert failed");
    }

    /// @dev V4Quoter's number: the output for exact input, the input for exact output. `ok` false when it reverted.
    function _v4(PoolKey memory k, bool exactIn, bool zfo, uint256 amount) internal returns (bool ok, uint256 q) {
        IV4Quoter.QuoteExactSingleParams memory p = IV4Quoter.QuoteExactSingleParams(k, zfo, uint128(amount), "");
        if (exactIn) {
            try QUOTER.quoteExactInputSingle(p) returns (uint256 o, uint256) {
                return (true, o);
            } catch {
                return (false, 0);
            }
        }
        try QUOTER.quoteExactOutputSingle(p) returns (uint256 i, uint256) {
            return (true, i);
        } catch {
            return (false, 0);
        }
    }

    function _amountFor(bool exactIn, bool zfo) internal pure returns (uint256) {
        if (exactIn) return zfo ? 1_000 * USDC_1 : 1_000 * MUMB_1;
        return zfo ? 990 * MUMB_1 : 990 * USDC_1;
    }

    /// @dev 0, 1, 3 or 6 makers on `keyV2` (the shapes of V2-07's gas log).
    function _makerSet(uint256 n) internal {
        if (n == 1) {
            _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        } else if (n >= 3) {
            _threeMakers();
            if (n == 6) {
                _joinM(keyV2, makers[3], 50_000e18, 50_000e6, _p());
                _joinM(keyV2, makers[4], 1_000e18, 1_000e6, _p());
                _joinM(keyV2, makers[5], 30_000e18, 30_000e6, _pf(FEE_100));
            }
        }
    }

    /// @dev The quote against the swap: totals, and each leg's maker, hash, input, output and status. `strict` also
    ///      requires the pool's side to match (not the case where the pool-only walk ends before the liquidity does).
    function _same(ConfluenceLens.Breakdown memory q, Run memory r, bool exactIn, bool strict, string memory ctx)
        internal
        view
    {
        assertEq(q.exactIn, exactIn, string.concat(ctx, ": mode"));
        assertEq(q.legs.length, r.legs.length, string.concat(ctx, ": one entry per slot read"));
        for (uint256 i; i < q.legs.length; i++) {
            assertEq(q.legs[i].strategyHash, r.legs[i].strategyHash, string.concat(ctx, ": hash"));
            assertEq(q.legs[i].status, r.legs[i].status, string.concat(ctx, ": status ", vm.toString(i)));
            assertEq(q.legs[i].amountIn, r.legs[i].amountIn, string.concat(ctx, ": leg in ", vm.toString(i)));
            assertEq(q.legs[i].amountOut, r.legs[i].amountOut, string.concat(ctx, ": leg out ", vm.toString(i)));
        }
        if (strict) {
            assertEq(q.totalIn, r.paid, string.concat(ctx, ": total in"));
            assertEq(q.totalOut, r.got, string.concat(ctx, ": total out"));
        }
    }

    function _anyLeg(ConfluenceLens.Breakdown memory q) internal pure returns (bool) {
        for (uint256 i; i < q.legs.length; i++) {
            if (q.legs[i].amountIn > 0) return true;
        }
        return false;
    }

    function _unhookedTwin() internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: keyV2.currency0,
            currency1: keyV2.currency1,
            fee: keyV2.fee,
            tickSpacing: keyV2.tickSpacing,
            hooks: IHooks(address(0))
        });
        (uint160 sqrtP,,,) = manager.getSlot0(idV2);
        manager.initialize(k, sqrtP);
        Pos[] memory pos = _v1Positions();
        deal(USDC, deployer, 1e15);
        vm.startPrank(deployer);
        mumb.mint(deployer, 1e27);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        mumb.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: pos[0].lower,
                tickUpper: pos[0].upper,
                liquidityDelta: int256(uint256(pos[0].liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();
    }

    /// @dev What a maker's break looks like on the pool: 0 docked, 1 drained of MUMB, 2 MUMB allowance revoked.
    function _breakMaker(M memory m, uint256 kind) internal {
        vm.startPrank(m.who);
        if (kind == 0) {
            IAqua(AQUA).dock(ROUTER, m.hash, _tokens());
        } else if (kind == 1) {
            mumb.transfer(address(0xdead), mumb.balanceOf(m.who));
        } else {
            mumb.approve(AQUA, 0);
        }
        vm.stopPrank();
    }

    function _swapAtGas(PoolKey memory k, bool zfo, uint256 amount, uint256 gasLimit)
        internal
        returns (bool ok, ConfluenceHook.Leg[] memory legs)
    {
        vm.recordLogs();
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        try swapRouter.swap{gas: gasLimit}(
            k,
            IPoolManager.SwapParams({zeroForOne: zfo, amountSpecified: -int256(amount), sqrtPriceLimitX96: _lim(zfo)}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ok = true;
        } catch {}
        vm.stopPrank();
        (legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
    }

    // =====================================================================================================
    // Spec acceptance
    // =====================================================================================================

    /// @dev The V4Quoter is deployed at FORK_BLOCK on the canonical PoolManager (the spec's [VERIFY]).
    function test_V209_v4QuoterIsDeployed() public view {
        assertGt(address(QUOTER).code.length, 0, "V4Quoter has code at FORK_BLOCK");
        (bool ok, bytes memory ret) = address(QUOTER).staticcall(abi.encodeWithSignature("poolManager()"));
        assertTrue(ok, "poolManager() answers");
        assertEq(abi.decode(ret, (address)), address(manager), "it serves the canonical PoolManager");
    }

    /// @dev V4Quoter runs the real hook: its total equals a real swap's, exact in and out, both directions, 0/1/3/6
    ///      makers, from one snapshot; and the Lens total equals V4Quoter's.
    function test_V209_v4QuoterEqualsSwap() public {
        _initExact(keyV2);
        uint256 s = vm.snapshotState();
        uint256[4] memory ns = [uint256(0), 1, 3, 6];
        for (uint256 m; m < 2; m++) {
            bool exactIn = m == 0;
            for (uint256 d; d < 2; d++) {
                bool zfo = d == 0;
                for (uint256 j; j < 4; j++) {
                    _makerSet(ns[j]);
                    uint256 amount = _amountFor(exactIn, zfo);
                    string memory ctx = string.concat(
                        exactIn ? "in" : "out", zfo ? " 0>1 " : " 1>0 ", vm.toString(ns[j]), " makers"
                    );
                    (bool ok, uint256 v4) = _v4(keyV2, exactIn, zfo, amount);
                    assertTrue(ok, string.concat(ctx, ": V4Quoter answers"));
                    ConfluenceLens.Breakdown memory q = L().quote(keyV2, zfo, _spec(exactIn, amount));
                    Run memory r = _runMode(keyV2, exactIn, zfo, amount);
                    assertEq(v4, exactIn ? r.got : r.paid, string.concat(ctx, ": V4Quoter == swap"));
                    assertEq(exactIn ? q.totalOut : q.totalIn, v4, string.concat(ctx, ": Lens == V4Quoter"));
                    vm.revertToState(s);
                }
            }
        }
    }

    /// @dev The Lens equals a real swap: total in, total out, and each leg, exact in and out, both directions, 0/1/3/6
    ///      makers, from one snapshot. A quote with a leg is exact (`poolExact`).
    function test_V209_lensEqualsSwap() public {
        _initExact(keyV2);
        uint256 s = vm.snapshotState();
        uint256[4] memory ns = [uint256(0), 1, 3, 6];
        for (uint256 m; m < 2; m++) {
            bool exactIn = m == 0;
            for (uint256 d; d < 2; d++) {
                bool zfo = d == 0;
                for (uint256 j; j < 4; j++) {
                    _makerSet(ns[j]);
                    uint256 amount = _amountFor(exactIn, zfo);
                    string memory ctx = string.concat(
                        exactIn ? "in" : "out", zfo ? " 0>1 " : " 1>0 ", vm.toString(ns[j]), " makers"
                    );
                    ConfluenceLens.Breakdown memory q = L().quote(keyV2, zfo, _spec(exactIn, amount));
                    Run memory r = _runMode(keyV2, exactIn, zfo, amount);
                    _same(q, r, exactIn, true, ctx);
                    assertEq(q.legs.length, ns[j], string.concat(ctx, ": one entry per registered slot"));
                    if (ns[j] > 0) assertTrue(_anyLeg(q), string.concat(ctx, ": the premise: a leg is planned"));
                    if (_anyLeg(q)) assertTrue(q.poolExact, string.concat(ctx, ": a legged quote is exact"));
                    assertGe(q.gainBps, 0, string.concat(ctx, ": never worse"));
                    vm.revertToState(s);
                }
            }
        }
    }

    /// @dev With no maker usable the Lens's number is the pool's own: equal to a real swap on a twin pool with no hook.
    function test_V209_lensPoolOnlyEqualsUnhookedSwap() public {
        _initExact(keyV2);
        PoolKey memory twin = _unhookedTwin();
        uint256 s = vm.snapshotState();
        for (uint256 m; m < 2; m++) {
            bool exactIn = m == 0;
            for (uint256 d; d < 2; d++) {
                bool zfo = d == 0;
                uint256 amount = _amountFor(exactIn, zfo);
                ConfluenceLens.Breakdown memory q = L().quote(keyV2, zfo, _spec(exactIn, amount));
                (address tIn, address tOut) = _io(twin, zfo);
                uint256 inB = IERC20(tIn).balanceOf(trader);
                uint256 outB = IERC20(tOut).balanceOf(trader);
                _swap(twin, trader, zfo, _spec(exactIn, amount), "");
                string memory ctx = string.concat(exactIn ? "in" : "out", zfo ? " 0>1" : " 1>0");
                assertEq(q.totalIn, inB - IERC20(tIn).balanceOf(trader), string.concat(ctx, ": in"));
                assertEq(q.totalOut, IERC20(tOut).balanceOf(trader) - outB, string.concat(ctx, ": out"));
                assertEq(q.legs.length, 0, string.concat(ctx, ": no makers"));
                assertEq(q.gainBps, 0, string.concat(ctx, ": no gain"));
                // and the same on the real hooked pool with no maker: the hook is a no-op without makers
                assertEq(exactIn ? q.poolOnlyOut : q.poolOnlyIn, exactIn ? q.totalOut : q.totalIn, "pool-only field");
                vm.revertToState(s);
            }
        }
    }

    // =====================================================================================================
    // Status reporting
    // =====================================================================================================

    function _expectStatuses(PoolKey memory k, bool zfo, uint256 amount, string memory ctx)
        internal
        returns (uint256 seen)
    {
        ConfluenceLens.Breakdown memory q = L().quote(k, zfo, _spec(true, amount));
        Run memory r = _runMode(k, true, zfo, amount);
        _same(q, r, true, false, ctx);
        for (uint256 i; i < r.legs.length; i++) {
            seen |= 1 << r.legs[i].status;
        }
    }

    /// @dev FILLED and every SKIP code a view can see, each equal to the swap's own event. SKIP_REVERT and SKIP_GAS are
    ///      execution-time outcomes: see `test_V209_lensBlindToExecutionRevert` and `test_V209_lensMinHookGas`.
    function test_V209_lensReportsEachStatus() public {
        _initExact(keyV2);
        (int24 snap,,) = hookV2.anchorOf(idV2);
        uint256 s = vm.snapshotState();
        uint256 seen;
        uint256 amount = 1_000 * USDC_1;

        // A: FILLED, MIN_LEG (a 1,000-deep maker), BAND (priced 4% off), UNDERFUNDED three ways: docked, drained, revoked.
        M[] memory ms = new M[](6);
        ms[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        ms[1] = _joinM(keyV2, makers[1], 1_000e18, 1_000e6, _p());
        ms[2] = _joinM(keyV2, makers[2], _mumbAt(100_000 * USDC_1, snap + 400), 100_000 * USDC_1, _p());
        ms[3] = _joinM(keyV2, makers[3], 100_000e18, 100_000e6, _p());
        ms[4] = _joinM(keyV2, makers[4], 100_000e18, 100_000e6, _p());
        ms[5] = _joinM(keyV2, makers[5], 100_000e18, 100_000e6, _p());
        _breakMaker(ms[3], 0);
        _breakMaker(ms[4], 1);
        _breakMaker(ms[5], 2);
        seen |= _expectStatuses(keyV2, true, amount, "A");
        vm.revertToState(s);

        // B: DRIFT (driftTicks 1 after a push, next block) and MATH (a reserve above 2^128).
        StrategyTemplate.Params memory tight = _p();
        tight.driftTicks = 1;
        _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        _joinM(keyV2, makers[1], 100_000e18, 100_000e6, tight);
        _joinM(keyV2, makers[2], uint256(type(uint128).max) + 1, 100_000e6, _p());
        _swap(keyV2, trader, true, -int256(5 * USDC_1), "");
        _nextBlock(1);
        seen |= _expectStatuses(keyV2, true, amount, "B");
        vm.revertToState(s);

        // C: a registered hash that no longer matches the rebuilt order (storage tampered): UNDERFUNDED.
        _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        _joinM(keyV2, makers[1], 100_000e18, 100_000e6, _p());
        bytes32 arr = keccak256(abi.encode(PoolId.unwrap(idV2), uint256(1)));
        vm.store(address(hookV2), bytes32(uint256(keccak256(abi.encode(arr))) + 3 + 2), bytes32(uint256(0xbad)));
        assertEq(hookV2.strategiesOf(idV2)[1].strategyHash, bytes32(uint256(0xbad)), "premise: the hash is tampered");
        seen |= _expectStatuses(keyV2, true, amount, "C");
        vm.revertToState(s);

        // D: NOT_BETTER (a thin maker cannot take the part of the swap past a truncated walk).
        PoolKey memory k = _gapKey();
        _initExact(k);
        StrategyTemplate.Params memory wide = _p();
        wide.bandBps = 600;
        _joinM(k, makers[0], 2_000e18, 2_000e6, wide);
        uint256 walked = _walked(k, true);
        {
            ConfluenceLens.Breakdown memory q = L().quote(k, true, _spec(true, walked + 100 * USDC_1));
            assertFalse(q.poolExact, "past the walk the pool-only quote is not exact");
            Run memory r = _runMode(k, true, true, walked + 100 * USDC_1);
            _same(q, r, true, false, "D");
            seen |= 1 << r.legs[0].status;
        }
        vm.revertToState(s);

        // E: PLAN (the splitter returns garbage).
        _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        vm.mockCall(address(splitter), abi.encodeWithSelector(ConfluenceSplitter.planExactIn.selector), "garbage");
        seen |= _expectStatuses(keyV2, true, amount, "E");
        vm.clearMockedCalls();

        uint256 want = (1 << LegStatus.FILLED) | (1 << LegStatus.SKIP_BAND) | (1 << LegStatus.SKIP_DRIFT)
            | (1 << LegStatus.SKIP_UNDERFUNDED) | (1 << LegStatus.SKIP_MIN_LEG) | (1 << LegStatus.SKIP_MATH)
            | (1 << LegStatus.SKIP_NOT_BETTER) | (1 << LegStatus.SKIP_PLAN);
        assertEq(seen & want, want, "every status a view can see was reached by a real swap");
    }

    /// @dev What a view cannot see: the router refusing a planned leg at fill time. The Lens says FILLED, the swap
    ///      SKIP_REVERT, and V4Quoter (which runs the hook) equals the swap.
    function test_V209_lensBlindToExecutionRevert() public {
        _initExact(keyV2);
        M[] memory ms = new M[](1);
        ms[0] = _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        uint256 amount = 1_000 * USDC_1;
        Plan memory p = _plan(keyV2, true, amount);
        _mockLegRevert(keyV2, ms[0], true, p.amountIn[0], p.amountOut[0]);
        ConfluenceLens.Breakdown memory q = L().quote(keyV2, true, _spec(true, amount));
        (bool ok, uint256 v4) = _v4(keyV2, true, true, amount);
        Run memory r = _runMode(keyV2, true, true, amount);
        assertEq(q.legs[0].status, LegStatus.FILLED, "the Lens assumes the planned leg fills");
        assertEq(r.legs[0].status, LegStatus.SKIP_REVERT, "the swap's router call reverted");
        assertTrue(ok, "V4Quoter answers");
        assertEq(v4, r.got, "V4Quoter equals the swap");
        assertGt(q.totalOut, r.got, "the Lens's blend is better than the pool-only fallback it did not see");
    }

    // =====================================================================================================
    // The hook's decision, reproduced
    // =====================================================================================================

    function _poolOnlyBoth(
        bytes memory ret,
        bool reverts,
        bytes4 sel,
        address target,
        bool exactIn,
        bool zfo,
        uint256 amount,
        Run memory po,
        string memory ctx
    ) internal {
        uint256 s = vm.snapshotState();
        if (reverts) vm.mockCallRevert(target, abi.encodeWithSelector(sel), "garbage");
        else vm.mockCall(target, abi.encodeWithSelector(sel), ret);
        ConfluenceLens.Breakdown memory q = L().quote(keyV2, zfo, _spec(exactIn, amount));
        Run memory r = _runMode(keyV2, exactIn, zfo, amount);
        for (uint256 i; i < r.legs.length; i++) {
            assertEq(r.legs[i].status, LegStatus.SKIP_PLAN, string.concat(ctx, ": the swap refused the plan"));
        }
        _same(q, r, exactIn, true, ctx);
        assertEq(q.planCode, LegStatus.SKIP_PLAN, string.concat(ctx, ": the Lens refused it too"));
        assertEq(r.got, po.got, string.concat(ctx, ": pool-only output"));
        assertEq(r.paid, po.paid, string.concat(ctx, ": pool-only input"));
        vm.clearMockedCalls();
        vm.revertToState(s);
    }

    /// @dev The same forged plans V2-07 and V2-08 feed the hook: every one is refused by the Lens as by the swap, and
    ///      quoted as the real pool-only swap. Wrong lengths, a revert and a 100 kB return never make the Lens revert.
    function test_V209_lensMatchesHookOnForgedPlans() public {
        _initExact(keyV2);
        _fourMakers();
        uint256 amount = 1_000 * USDC_1;
        Plan memory p = _plan(keyV2, true, amount);
        Run memory po = _poolOnlyMode(keyV2, true, true, amount);
        bytes4 selIn = ConfluenceSplitter.planExactIn.selector;
        address sp = address(splitter);
        _poolOnlyBoth(abi.encode(uint256(1)), false, selIn, sp, true, true, amount, po, "32 bytes");
        _poolOnlyBoth(new bytes(100_000), false, selIn, sp, true, true, amount, po, "100 kB");
        _poolOnlyBoth(bytes.concat(abi.encode(p), hex"00"), false, selIn, sp, true, true, amount, po, "one byte long");
        _poolOnlyBoth("", true, selIn, sp, true, true, amount, po, "reverts");

        Plan memory q = _copy(p);
        q.poolIn += 1;
        _poolOnlyBoth(abi.encode(q), false, selIn, sp, true, true, amount, po, "sum != amount");
        q = _copy(p);
        q.capIn[0] = q.amountIn[0] - 1;
        _poolOnlyBoth(abi.encode(q), false, selIn, sp, true, true, amount, po, "leg over its cap");
        q = _copy(p);
        q.capMin[0] = q.amountIn[0] + 1;
        _poolOnlyBoth(abi.encode(q), false, selIn, sp, true, true, amount, po, "leg under its smallest fill");
        q = _copy(p);
        q.status[0] = 10;
        _poolOnlyBoth(abi.encode(q), false, selIn, sp, true, true, amount, po, "bad status");
        q = _copy(p);
        q.amountIn[5] = 10 * USDC_1;
        q.capIn[5] = 10 * USDC_1;
        q.poolIn -= 10 * USDC_1;
        _poolOnlyBoth(abi.encode(q), false, selIn, sp, true, true, amount, po, "nonexistent slot");
        q = _copy(p);
        q.poolOut = 0;
        _poolOnlyBoth(abi.encode(q), false, selIn, sp, true, true, amount, po, "not better");
        q = _copy(p);
        q.truncated = 1;
        q.walked = q.poolIn - 1;
        _poolOnlyBoth(abi.encode(q), false, selIn, sp, true, true, amount, po, "truncated past the walk");
        q = _copy(p);
        q.amountOut[0] = uint256(uint128(type(int128).max)) + 1;
        _poolOnlyBoth(abi.encode(q), false, selIn, sp, true, true, amount, po, "output over int128");

        // Exact output, both directions' worth of the same checks on the second splitter.
        uint256 b = 990 * MUMB_1;
        (int24 sn, int56 em,) = hookV2.anchorOfX(idV2);
        Plan memory o = splitterOut.planExactOut(keyV2, true, _lim(true), b, sn, em);
        Run memory poOut = _poolOnlyMode(keyV2, false, true, b);
        bytes4 selOut = ConfluenceSplitterOut.planExactOut.selector;
        address so = address(splitterOut);
        _poolOnlyBoth("garbage", false, selOut, so, false, true, b, poOut, "out: wrong length");
        q = _copy(o);
        q.tail = 1;
        _poolOnlyBoth(abi.encode(q), false, selOut, so, false, true, b, poOut, "out: tail");
        q = _copy(o);
        q.walked = b - 1;
        _poolOnlyBoth(abi.encode(q), false, selOut, so, false, true, b, poOut, "out: truncated walk");
        q = _copy(o);
        q.poolOnlyOut = 1;
        _poolOnlyBoth(abi.encode(q), false, selOut, so, false, true, b, poOut, "out: not better");
        q = _copy(o);
        q.poolIn += 1;
        _poolOnlyBoth(abi.encode(q), false, selOut, so, false, true, b, poOut, "out: sum");
    }

    /// @dev A splitter that burns all its gas is cut off at `PLAN_GAS_CAP`: SKIP_PLAN, the real pool-only number.
    function test_V209_lensRejectedPlanIsPoolOnly() public {
        _initExact(keyV2);
        _threeMakers();
        uint256 amount = 1_000 * USDC_1;
        Run memory po = _poolOnlyMode(keyV2, true, true, amount);
        vm.etch(address(splitter), _burnerCode());
        ConfluenceLens.Breakdown memory q = L().quote(keyV2, true, _spec(true, amount));
        Run memory r = _runMode(keyV2, true, true, amount);
        _same(q, r, true, true, "burning splitter");
        assertEq(q.planCode, LegStatus.SKIP_PLAN, "cut off");
        assertEq(q.totalOut, po.got, "pool-only");
    }

    /// @dev Exact output the pool cannot give in full stays pool-only (D-36): a partial fill. The Lens reports it
    ///      without guessing (`poolExact` false: the walk cannot tell its own bound from the end) and V4Quoter refuses.
    function test_V209_lensPoolShortExactOutIsPoolOnly() public {
        _initExact(keyV2);
        _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        uint256 b = 3_000 * MUMB_1; // the seed pool holds about 2,500 MUMB
        ConfluenceLens.Breakdown memory q = L().quote(keyV2, true, _spec(false, b));
        (bool ok,) = _v4(keyV2, false, true, b);
        Run memory r = _runMode(keyV2, false, true, b);
        assertLt(r.got, b, "premise: a partial fill");
        assertFalse(ok, "V4Quoter reverts NotEnoughLiquidity on a partial fill");
        assertEq(q.legs[0].status, LegStatus.SKIP_NOT_BETTER, "the plan is pool-only");
        assertFalse(q.poolExact, "past the walk: not exact");
        _same(q, r, false, true, "pool short"); // the seed pool has no liquidity past its walk, so the walked total is the swap's
    }

    // =====================================================================================================
    // Past the walk: V4Quoter is the authority
    // =====================================================================================================

    /// @dev A large pool-only swap past the 8-segment walk on a pool with liquidity beyond it: the Lens says it is not
    ///      exact, and V4Quoter equals the real swap to the wei, exact in and out, both directions.
    function test_V209_pastTheWalkV4QuoterIsExact() public {
        PoolKey memory k = _gapKey();
        _initExact(k);
        uint256 s = vm.snapshotState();
        for (uint256 m; m < 2; m++) {
            bool exactIn = m == 0;
            for (uint256 d; d < 2; d++) {
                bool zfo = d == 0;
                PoolVenue.Pool memory pool = PoolVenue.read(manager, k.toId(), k.tickSpacing, zfo, _lim(zfo));
                uint256 walkedAmt;
                for (uint256 i; i < pool.segments.length; i++) {
                    walkedAmt += exactIn ? pool.segments[i].capIn : pool.segments[i].capOut;
                }
                uint256 amount = walkedAmt + (exactIn ? (zfo ? 100 * USDC_1 : 100 * MUMB_1) : (zfo ? 100 * MUMB_1 : 100 * USDC_1));
                string memory ctx = string.concat(exactIn ? "in" : "out", zfo ? " 0>1" : " 1>0");
                ConfluenceLens.Breakdown memory q = L().quote(k, zfo, _spec(exactIn, amount));
                (bool ok, uint256 v4) = _v4(k, exactIn, zfo, amount);
                Run memory r = _runMode(k, exactIn, zfo, amount);
                assertTrue(pool.truncated, string.concat(ctx, ": premise: the walk is truncated"));
                assertFalse(q.poolExact, string.concat(ctx, ": the Lens says it is not exact"));
                assertFalse(q.poolOnlyExact, string.concat(ctx, ": nor the pool-only reference"));
                assertTrue(ok, string.concat(ctx, ": V4Quoter answers"));
                assertEq(v4, exactIn ? r.got : r.paid, string.concat(ctx, ": V4Quoter == swap, to the wei"));
                vm.revertToState(s);
            }
        }
    }

    // =====================================================================================================
    // The anchor
    // =====================================================================================================

    /// @dev Before a block's first swap the Lens quotes at the anchor that swap will store, so quote == swap. A quote
    ///      taken in block N and a swap in block N+1 after the price moved in N can differ: the swap's snapshot is the
    ///      moved price, so a maker priced at the old price is out of band.
    function test_V209_lensAcrossNewBlock() public {
        _initExact(keyV2);
        _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
        uint256 amount = 100 * USDC_1;
        uint256 s = vm.snapshotState();

        // 1. A quote before the first swap of a new block equals that swap.
        _nextBlock(30);
        ConfluenceLens.Breakdown memory q1 = L().quote(keyV2, true, _spec(true, amount));
        assertFalse(q1.anchorFresh, "the anchor is lazily computed: no swap yet this block");
        Run memory r1 = _runMode(keyV2, true, true, amount);
        _same(q1, r1, true, true, "quote before the block's first swap");
        assertEq(q1.legs[0].status, LegStatus.FILLED, "premise: the maker fills");
        vm.revertToState(s);

        // 2. A quote in block N, then the price moves in N, then a swap in N+1: the snapshot moved.
        ConfluenceLens.Breakdown memory q2 = L().quote(keyV2, true, _spec(true, amount));
        assertEq(q2.legs[0].status, LegStatus.FILLED, "quoted fill");
        _swap(keyV2, trader, true, -int256(1_000 * USDC_1), ""); // moves the price a long way, same block
        _nextBlock(1);
        Run memory r2 = _runMode(keyV2, true, true, amount);
        assertTrue(r2.legs[0].status != LegStatus.FILLED, "the maker is out of band of the new snapshot");
        ConfluenceLens.Breakdown memory q3 = L().quote(keyV2, true, _spec(true, amount));
        assertEq(q3.legs[0].status, r2.legs[0].status, "a fresh quote shows what the swap did");
    }

    // =====================================================================================================
    // Maker limits
    // =====================================================================================================

    function _code(MakerVenue.Status st) internal pure returns (uint8) {
        if (st == MakerVenue.Status.OK) return LegStatus.FILLED;
        if (st == MakerVenue.Status.SKIP_BAND) return LegStatus.SKIP_BAND;
        if (st == MakerVenue.Status.SKIP_DRIFT) return LegStatus.SKIP_DRIFT;
        if (st == MakerVenue.Status.SKIP_UNDERFUNDED) return LegStatus.SKIP_UNDERFUNDED;
        return LegStatus.SKIP_MATH;
    }

    /// @dev The Lens's limits equal a direct `MakerVenue` read (both modes, both directions), with a docked, a drained
    ///      and a band-skipped maker among them, and do not depend on any trade size (they come from 1-wei plans).
    function test_V209_makerLimitsEqualLibraryRead() public {
        _initExact(keyV2);
        (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
        _threeMakers();
        M memory docked = _joinM(keyV2, makers[3], 100_000e18, 100_000e6, _p());
        M memory drained = _joinM(keyV2, makers[4], 100_000e18, 100_000e6, _p());
        _joinM(keyV2, makers[5], _mumbAt(100_000 * USDC_1, snap + 400), 100_000 * USDC_1, _p());
        _breakMaker(docked, 0);
        _breakMaker(drained, 1);
        ConfluenceHook.Slot[] memory slots = hookV2.strategiesOf(idV2);
        MakerVenue.Entry[] memory es = new MakerVenue.Entry[](slots.length);
        for (uint256 i; i < slots.length; i++) {
            es[i] = MakerVenue.Entry(slots[i].maker, slots[i].params, slots[i].strategyHash);
        }
        ConfluenceLens.MakerLimit[] memory lim = L().makerLimits(keyV2);
        assertEq(lim.length, 6, "one per registered slot");
        for (uint256 d; d < 2; d++) {
            bool zfo = d == 0;
            MakerVenue.Maker[] memory mi = MakerVenue.read(manager, keyV2, _guard(), es, zfo, snap, emaX);
            MakerVenue.Maker[] memory mo = MakerVenue.readOut(manager, keyV2, _guard(), es, zfo, snap, emaX);
            for (uint256 i; i < 6; i++) {
                ConfluenceLens.Side memory sd = zfo ? lim[i].zeroForOne : lim[i].oneForZero;
                string memory c = string.concat(zfo ? "0>1 slot " : "1>0 slot ", vm.toString(i));
                assertEq(lim[i].maker, slots[i].maker, string.concat(c, ": maker"));
                assertEq(lim[i].strategyHash, slots[i].strategyHash, string.concat(c, ": hash"));
                assertEq(sd.statusIn, _code(mi[i].status), string.concat(c, ": status in"));
                assertEq(sd.minIn, mi[i].capMin, string.concat(c, ": min in"));
                assertEq(sd.maxIn, mi[i].capIn, string.concat(c, ": max in"));
                assertEq(sd.statusOut, _code(mo[i].status), string.concat(c, ": status out"));
                assertEq(sd.minOut, mo[i].capMin, string.concat(c, ": min out"));
                assertEq(sd.maxOut, mo[i].capOut, string.concat(c, ": max out"));
            }
        }
        assertEq(lim[3].zeroForOne.statusIn, LegStatus.SKIP_UNDERFUNDED, "docked");
        assertEq(lim[5].zeroForOne.statusIn, LegStatus.SKIP_BAND, "out of band");
        assertEq(lim[0].zeroForOne.statusIn, LegStatus.FILLED, "usable");
        assertGt(lim[0].zeroForOne.maxIn, 0, "with a cap");
    }

    // =====================================================================================================
    // Gas
    // =====================================================================================================

    /// @dev `minHookGas` is a SUFFICIENT bound (not tight) on the gas the hook needs at entry to run every planned leg
    ///      without SKIP_GAS. At the bound plus the pool's own cost every leg fills; below the hook's own precheck
    ///      (`GAS_RESERVE + MIN_LEG_GAS` = 330,000 at the plan) every slot is SKIP_GAS.
    function test_V209_lensMinHookGas() public {
        _initExact(keyV2);
        uint256 s = vm.snapshotState();
        uint256 amount = 1_000 * USDC_1;
        for (uint256 n = 1; n <= 3; n++) {
            _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _p());
            if (n > 1) _joinM(keyV2, makers[1], 100_000e18, 100_000e6, _pf(FEE_050));
            if (n > 2) _joinM(keyV2, makers[2], 100_000e18, 100_000e6, _pf(FEE_005));
            ConfluenceLens.Breakdown memory q = L().quote(keyV2, true, _spec(true, amount));
            uint256 legs;
            for (uint256 i; i < q.legs.length; i++) {
                if (q.legs[i].amountIn > 0) legs++;
            }
            assertEq(legs, n, "premise: every maker has a leg");
            console2.log(string.concat("minHookGas, ", vm.toString(n), " legs:"), q.minHookGas);

            uint256 s2 = vm.snapshotState();
            (bool ok, ConfluenceHook.Leg[] memory l) = _swapAtGas(keyV2, true, amount, q.minHookGas + POOL_SIDE_GAS);
            assertTrue(ok, "the swap passes at the bound");
            assertEq(_countStatus(l, LegStatus.FILLED), n, "every planned leg fills at the bound");
            vm.revertToState(s2);

            (ok, l) = _swapAtGas(keyV2, true, amount, CLEARLY_LESS);
            assertTrue(ok, "the pool-only swap still passes below the precheck");
            assertEq(_countStatus(l, LegStatus.SKIP_GAS), n, "every slot is SKIP_GAS below the hook's precheck");
            vm.revertToState(s);
        }
        assertLt(CLEARLY_LESS, HOOK_PRECHECK, "320,000 is under GAS_RESERVE + MIN_LEG_GAS");
        assertEq(hookV2.GAS_RESERVE() + hookV2.MIN_LEG_GAS(), HOOK_PRECHECK, "the hook's own precheck");
    }

    function test_V209_lensSize() public {
        assertLt(address(L()).code.length, 24_576, "under EIP-170");
    }

    // =====================================================================================================
    // Fuzz
    // =====================================================================================================

    /// @dev Random amount, direction, mode and maker set (0 to 6, some broken): the Lens equals the swap (totals, each
    ///      leg and status) and V4Quoter equals the swap, from one snapshot.
    function testFuzz_V209_lensEqualsSwap(
        uint256 seed,
        bool exactIn,
        bool zfo,
        uint256 amountRaw,
        uint8 nRaw,
        uint8 brokenMask
    ) public {
        _initExact(keyV2);
        (int24 snap,,) = hookV2.anchorOf(idV2);
        uint256 n = bound(nRaw, 0, MAX_FUZZ_MAKERS);
        uint32[5] memory fees = [uint32(500_000), 1_000_000, 3_000_000, 5_000_000, 10_000_000];
        M[] memory ms = new M[](n);
        for (uint256 i; i < n; i++) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            uint256 usdcRaw = bound(h, 1_000, 200_000) * USDC_1;
            int24 off = int24(int256(bound(h >> 64, 0, 300))) - 150;
            ms[i] = _joinM(keyV2, makers[i], _mumbAt(usdcRaw, snap + off), usdcRaw, _pf(fees[(h >> 128) % 5]));
        }
        for (uint256 i; i < n; i++) {
            if ((brokenMask >> i) & 1 == 1) _breakMaker(ms[i], (seed >> (8 * i)) % 3);
        }
        uint256 unit = (exactIn == zfo) ? USDC_1 : MUMB_1; // exact in: the input's unit; exact out: the output's
        uint256 amount = bound(amountRaw, 1, 3_000 * unit);
        ConfluenceLens.Breakdown memory q = L().quote(keyV2, zfo, _spec(exactIn, amount));
        (bool ok, uint256 v4) = _v4(keyV2, exactIn, zfo, amount);
        Run memory r = _runMode(keyV2, exactIn, zfo, amount);
        _same(q, r, exactIn, true, "fuzz");
        if (_anyLeg(q)) assertTrue(q.poolExact, "a legged quote is exact");
        if (ok) {
            assertEq(v4, exactIn ? r.got : r.paid, "V4Quoter == swap");
        } else {
            assertTrue(exactIn ? r.paid < amount : r.got < amount, "V4Quoter refuses only a partial fill");
        }
    }
}
