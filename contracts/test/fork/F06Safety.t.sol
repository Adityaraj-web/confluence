// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IExtruction, IStaticExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {PoolPriceBandExtruction} from "../../src/PoolPriceBandExtruction.sol";
import {ConfluenceBase} from "../base/ConfluenceBase.t.sol";

/// @notice Test-only Extruction target whose call burns all the gas it is given (`INVALID`), as a maker-chosen
/// strategy could. Not production code.
contract GasBurnExtruction is IExtruction, IStaticExtruction {
    function extruction(bool, uint256, SwapQuery calldata, SwapRegisters calldata, bytes calldata, bytes calldata)
        external
        pure
        override(IExtruction, IStaticExtruction)
        returns (uint256, uint256, SwapRegisters memory)
    {
        assembly ("memory-safe") {
            invalid()
        }
    }
}

/// @notice Test-only Extruction target that reverts with 500,000 bytes of return data. The first 256 bytes are
/// `0xdeadbeef` padded to a word, then the words 1 to 7; the rest is whatever is in memory. Not production code.
contract ReturnBombExtruction is IExtruction, IStaticExtruction {
    function extruction(bool, uint256, SwapQuery calldata, SwapRegisters calldata, bytes calldata, bytes calldata)
        external
        pure
        override(IExtruction, IStaticExtruction)
        returns (uint256, uint256, SwapRegisters memory)
    {
        // Not "memory-safe": it overwrites the free memory pointer, which is fine because it reverts at once.
        assembly {
            mstore(0x00, shl(224, 0xdeadbeef))
            mstore(0x20, 1)
            mstore(0x40, 2)
            mstore(0x60, 3)
            mstore(0x80, 4)
            mstore(0xa0, 5)
            mstore(0xc0, 6)
            mstore(0xe0, 7)
            revert(0, 500000)
        }
    }
}

/// @notice F06: Aqua can never make a v4 swap fail. Every failure of the Aqua leg unwinds, the hook emits
/// `AquaSkipped`, and the pool fills the whole swap exactly as it would with no hint.
contract F06SafetyTest is ConfluenceBase {
    uint256 internal constant SWAP_USDC = 1_000e6;
    uint256 internal constant SWAP_MUMB = 1_000e18;
    /// @dev The 60% split of F05, unchanged by F06.
    uint256 internal constant SPLIT_60_MUMB_OUT = 991_498_196_999_760_649_578;
    /// @dev Gas limit of the whole swap in `test_F06_routerOutOfGasFallsBack`: low enough that the 63/64 rule, not
    /// the hook's reserve, would decide the outcome (see the failing-state note there).
    uint256 internal constant GAS_BUDGET = 1_500_000;
    /// @dev The longest `reason` the hook emits for a router revert.
    uint256 internal constant MAX_REASON_BYTES = 256;

    // ---------------------------------------------------------------- acceptance

    /// @dev The pool price moved outside the 200 bps band, so the Extruction step reverts.
    function test_F06_bandBreachFallsBack() public {
        Snap memory s0 = _snap();
        _swapExactIn(trader, usdcForMumb(), 1_500e6, "");
        Snap memory s1 = _snap();
        uint256 moveBps = _absDiff(s1.sqrtPriceX96, s0.sqrtPriceX96) * 10_000 / s0.sqrtPriceX96;
        assertGe(moveBps, 150, "precondition: the pool price moved far outside the band");

        _assertFallsBack(
            "band breach",
            usdcForMumb(),
            -int256(500e6),
            _hint(500e6),
            PoolPriceBandExtruction.PoolPriceBandExceeded.selector,
            ""
        );
    }

    /// @dev Priya docked her strategy: Aqua refuses to read its balances.
    function test_F06_dockedStrategyFallsBack() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(mumb);
        tokens[1] = USDC;
        vm.prank(priya);
        aqua.dock(ROUTER, strategyHash, tokens);

        _assertFallsBack(
            "docked",
            usdcForMumb(),
            -int256(SWAP_USDC),
            _hint(SWAP_USDC),
            IAqua.SafeBalancesForTokenNotInActiveStrategy.selector,
            abi.encodeWithSelector(
                IAqua.SafeBalancesForTokenNotInActiveStrategy.selector, priya, ROUTER, strategyHash, USDC
            )
        );
    }

    /// @dev A hint of 200,000 USDC against her 100,000 USDC virtual balance. The XYC curve can never overdraw her
    /// balance, so what refuses the fill is the band (F06 source check, recorded in D-20).
    function test_F06_insufficientMakerBalanceFallsBack() public {
        deal(USDC, trader, 250_000e6);
        assertGt(200_000e6, SHIPPED_USDC, "precondition: the hint is above her virtual balance");

        _assertFallsBack(
            "hint above virtual balance",
            usdcForMumb(),
            -int256(200_000e6),
            _hint(200_000e6),
            PoolPriceBandExtruction.PoolPriceBandExceeded.selector,
            ""
        );
    }

    /// @dev Priya set her MUMB approval for Aqua to zero: Aqua's `pull` cannot move her tokens.
    function test_F06_makerRevokedApprovalFallsBack() public {
        vm.prank(priya);
        mumb.approve(AQUA, 0);

        _assertFallsBack(
            "revoked approval",
            usdcForMumb(),
            -int256(SWAP_USDC),
            _hint(SWAP_USDC),
            SafeERC20.SafeTransferFromFailed.selector,
            ""
        );
    }

    /// @dev No order for the pool: no router call, and the skip is reported.
    function test_F06_unregisteredOrderIsPoolOnly() public {
        vm.prank(priya);
        hook.unregisterOrder(key);

        vm.expectCall(ROUTER, abi.encodeWithSelector(ISwapVM.swap.selector), 0);
        _assertFallsBack(
            "no order",
            usdcForMumb(),
            -int256(SWAP_USDC),
            _hint(SWAP_USDC),
            ConfluenceHook.NoOrder.selector,
            abi.encodeWithSelector(ConfluenceHook.NoOrder.selector)
        );
    }

    // ---------------------------------------------------------------- extra: failures named in the spec or F05

    /// @dev Her virtual balance is intact but her wallet no longer holds the MUMB Aqua would pull.
    function test_F06_makerWalletShortFallsBack() public {
        uint256 all = mumb.balanceOf(priya);
        vm.prank(priya);
        mumb.transfer(address(0xdead), all);

        _assertFallsBack(
            "wallet short",
            usdcForMumb(),
            -int256(SWAP_USDC),
            _hint(SWAP_USDC),
            SafeERC20.SafeTransferFromFailed.selector,
            ""
        );
    }

    /// @dev F05 open issue 1: the PoolManager holds only the seed's MUMB, so `take` of more would revert.
    function test_F06_mumbHintAbovePoolManagerFallsBack() public {
        uint256 available = mumb.balanceOf(address(manager));
        assertLt(available, 3_000e18, "precondition: the PoolManager holds less MUMB than the hint");

        vm.expectCall(ROUTER, abi.encodeWithSelector(ISwapVM.swap.selector), 0);
        _assertFallsBack(
            "PoolManager short",
            mumbForUsdc(),
            -int256(3_000e18),
            _hint(3_000e18),
            ConfluenceHook.PoolManagerShort.selector,
            abi.encodeWithSelector(ConfluenceHook.PoolManagerShort.selector, available)
        );
    }

    /// @dev F05 open issue 3: a hint above `int128` max cannot be a `BeforeSwapDelta`. The swap amount is the same
    /// size, so the hint is not above the amount; the pool takes only what its liquidity can fill.
    function test_F06_hintAboveInt128FallsBack() public {
        uint256 tooLarge = uint256(uint128(type(int128).max)) + 1;

        vm.expectCall(ROUTER, abi.encodeWithSelector(ISwapVM.swap.selector), 0);
        _assertFallsBack(
            "hint above int128",
            usdcForMumb(),
            -int256(tooLarge),
            _hint(tooLarge),
            ConfluenceHook.HintTooLarge.selector,
            abi.encodeWithSelector(ConfluenceHook.HintTooLarge.selector)
        );
    }

    /// @dev A strategy whose Extruction burns all the gas it is given. The hook caps the router's gas so that a
    /// revert inside it is caught and the swap still finishes inside the same transaction.
    ///
    /// Failing-state note (recorded before the cap existed, at HEAD 961b992): with the router call uncapped, this
    /// test reverts at the 1,500,000 limit set here, and a sweep of the limits showed the swap succeeding from
    /// 2,000,000 upwards and reverting from 1,800,000 down. The trace at 1,500,000: `GasBurnExtruction` hit
    /// `InvalidFEOpcode`, the router reverted, the hook caught it, reset the approval, settled the input back and
    /// emitted `AquaSkipped(reason: 0x)`; then the PoolManager's continuation of the swap (the pool leg) ran out of
    /// gas, because the 63/64 rule had left only about 1/64 of the gas at each level above the burn. The cap in
    /// `ConfluenceHook._fill` exists to stop that.
    function test_F06_routerOutOfGasFallsBack() public {
        _shipAndRegister(address(new GasBurnExtruction()));

        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        BalanceDelta base = _swapWithGas(usdcForMumb(), -int256(SWAP_USDC), "", GAS_BUDGET);
        emit log_named_uint("gas used, pool-only swap", g0 - gasleft());
        Snap memory baseAfter = _snap();
        vm.revertToState(snap);

        Snap memory b = _snap();
        vm.recordLogs();
        g0 = gasleft();
        BalanceDelta d = _swapWithGas(usdcForMumb(), -int256(SWAP_USDC), _hint(SWAP_USDC), GAS_BUDGET);
        emit log_named_uint("gas used, swap with the gas-burning strategy", g0 - gasleft());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Snap memory a = _snap();

        assertEq(BalanceDelta.unwrap(d), BalanceDelta.unwrap(base), "same delta as pool-only");
        _assertSameState(a, baseAfter, "out of gas");
        assertEq(a.priyaMumb, b.priyaMumb, "Priya wallet MUMB");
        assertEq(a.priyaUsdc, b.priyaUsdc, "Priya wallet USDC");
        _assertHookClean();
        bytes[] memory reasons = _skips(logs);
        assertEq(reasons.length, 1, "one AquaSkipped");
        assertEq(reasons[0].length, 0, "running out of gas leaves no revert data");
    }

    /// @dev The guarantee at every gas limit, not at one: wherever the pool alone passes, the swap with an Aqua hint
    /// passes too, for a legitimate fill and for a strategy that burns all its gas. Limits run from 285,000 (the
    /// pool-only swap needs under 290,000) to 3,000,000, 5,000 apart up to 500,000, where the hook's gas checks bite.
    /// A reserve measured at one limit is not enough: at 70,000 this sweep fails at 17 of 24 limits for the burning
    /// strategy and 4 for the legitimate one, at 100,000 at 10 and 13 limits in 335,000-405,000, and passes from
    /// 105,000 (D-20).
    function test_F06_neverCostsTheSwapAtAnyGasLimit() public {
        uint256 filled = _sweepGasLimits("legit");
        assertGt(filled, 10, "precondition: the sweep includes limits where Aqua fills");

        _shipAndRegister(address(new GasBurnExtruction()));
        uint256 filledAfterBurn = _sweepGasLimits("burn");
        assertEq(filledAfterBurn, 0, "a burning strategy never fills");
    }

    /// @dev Just below `AQUA_GAS_RESERVE + MIN_AQUA_GAS` the hook skips Aqua before `take` with `InsufficientGas`,
    /// and the pool fills the whole swap. The limit is found by bisection: `lo` is the highest transaction gas limit
    /// that skips, `hi = lo + 1` the lowest that does not. Gas handed down the call frames changes by 0 or 1 per unit,
    /// so at `lo` the hook sees exactly one gas less than the threshold.
    function test_F06_gasJustBelowThresholdSkipsWithInsufficientGas() public {
        uint256 threshold = hook.AQUA_GAS_RESERVE() + hook.MIN_AQUA_GAS();
        uint256 lo = 300_000; // the pool-only swap passes here (see the sweep test) and the hook is below the threshold
        uint256 hi = 700_000; // a legitimate fill happens here

        (bool okLo, bytes[] memory skipsLo,) = _hintedAtLimit(lo);
        assertTrue(okLo && _isGasSkip(skipsLo), "precondition: 300,000 skips with InsufficientGas");
        (bool okHi, bytes[] memory skipsHi, bool filledHi) = _hintedAtLimit(hi);
        assertTrue(okHi && filledHi && skipsHi.length == 0, "precondition: 700,000 fills");

        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (, bytes[] memory skips,) = _hintedAtLimit(mid);
            if (_isGasSkip(skips)) lo = mid;
            else hi = mid;
        }

        // At `lo`: skipped with InsufficientGas, one gas under the threshold, and the pool-only result.
        uint256 snap = vm.snapshotState();
        BalanceDelta base = _swapWithGas(usdcForMumb(), -int256(SWAP_USDC), "", lo);
        Snap memory baseAfter = _snap();
        vm.revertToState(snap);

        snap = vm.snapshotState();
        Snap memory b = _snap();
        vm.recordLogs();
        BalanceDelta d = _swapWithGas(usdcForMumb(), -int256(SWAP_USDC), _hint(SWAP_USDC), lo);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Snap memory a = _snap();
        vm.revertToState(snap);

        bytes[] memory reasons = _skips(logs);
        assertEq(reasons.length, 1, "one AquaSkipped");
        assertEq(
            reasons[0],
            abi.encodeWithSelector(ConfluenceHook.InsufficientGas.selector, threshold - 1),
            "InsufficientGas, one gas under the threshold"
        );
        assertEq(BalanceDelta.unwrap(d), BalanceDelta.unwrap(base), "delta equals pool-only");
        _assertSameState(a, baseAfter, "just below the threshold");
        assertEq(a.priyaMumb, b.priyaMumb, "Priya wallet MUMB");
        assertEq(a.priyaUsdc, b.priyaUsdc, "Priya wallet USDC");
        (bool filled,,) = _findAquaFill(logs);
        assertFalse(filled, "no AquaFill");
        _assertHookClean();

        // One gas more: the hook goes ahead. The router has less than a fill needs, so it fails inside the cap and
        // the swap still passes through the pool.
        (bool okAbove, bytes[] memory skipsAbove,) = _hintedAtLimit(hi);
        assertTrue(okAbove, "the swap at the first limit that does not skip passes");
        assertFalse(_isGasSkip(skipsAbove), "no InsufficientGas at the first limit that does not skip");
    }

    /// @dev A strategy whose Extruction reverts with 500,000 bytes. The hook keeps only the first
    /// `MAX_REASON_BYTES`, so the revert data cannot be used to run the swap out of gas.
    function test_F06_returnBombFallsBack() public {
        _shipAndRegister(address(new ReturnBombExtruction()));

        bytes memory expected = abi.encodePacked(
            bytes32(bytes4(0xdeadbeef)),
            uint256(1),
            uint256(2),
            uint256(3),
            uint256(4),
            uint256(5),
            uint256(6),
            uint256(7)
        );
        assertEq(expected.length, MAX_REASON_BYTES, "precondition: expected is exactly the trimmed length");
        _assertFallsBack(
            "return bomb", usdcForMumb(), -int256(SWAP_USDC), _hint(SWAP_USDC), bytes4(0xdeadbeef), expected
        );
    }

    /// @dev Skips of a swap that asked for the Aqua leg are reported; swaps that did not ask stay silent.
    function test_F06_skipReasons() public {
        _assertFallsBack(
            "exact output",
            usdcForMumb(),
            int256(500e18),
            _hint(100e6),
            ConfluenceHook.ExactOutputNotSupported.selector,
            abi.encodeWithSelector(ConfluenceHook.ExactOutputNotSupported.selector)
        );
        _assertFallsBack(
            "hint above amount",
            usdcForMumb(),
            -int256(SWAP_USDC),
            _hint(SWAP_USDC + 1),
            ConfluenceHook.HintAboveAmount.selector,
            abi.encodeWithSelector(ConfluenceHook.HintAboveAmount.selector)
        );

        // No hint asked for: no event.
        (,, Vm.Log[] memory logs) = _swapWithLogs(usdcForMumb(), 100e6, "");
        assertEq(_skips(logs).length, 0, "empty hookData is silent");
        (,, logs) = _swapWithLogs(usdcForMumb(), 100e6, _hint(0));
        assertEq(_skips(logs).length, 0, "hint 0 is silent");
        (,, logs) = _swapWithLogs(usdcForMumb(), 100e6, new bytes(31));
        assertEq(_skips(logs).length, 0, "hookData of the wrong length is silent");
    }

    /// @dev F06 changes nothing for a fill that works: F05's 60% split, exactly.
    function test_F06_successPathUnchanged() public {
        Snap memory b = _snap();
        (int128 mumbDelta,, Vm.Log[] memory logs) = _swapWithLogs(usdcForMumb(), SWAP_USDC, _hint(600e6));
        Snap memory a = _snap();

        assertEq(a.traderMumb - b.traderMumb, SPLIT_60_MUMB_OUT, "trader MUMB");
        assertEq(int256(mumbDelta), int256(SPLIT_60_MUMB_OUT), "delta MUMB");
        (bool found, uint256 fillIn,) = _findAquaFill(logs);
        assertTrue(found, "AquaFill emitted");
        assertEq(fillIn, 600e6, "AquaFill amountIn");
        assertEq(_skips(logs).length, 0, "no AquaSkipped");
        _assertHookClean();
    }

    // ---------------------------------------------------------------- helpers

    /// @dev From one state, the swap with empty hookData (pool-only) and the swap with `hookData` must leave the
    /// same state and the same delta; Priya's wallet and Aqua balances must not move; the hook must hold nothing and
    /// have no approval left; and exactly one `AquaSkipped` for this pool must be emitted, whose reason starts with
    /// `reasonSelector` and, if `exactReason` is non-empty, equals it.
    function _assertFallsBack(
        string memory label,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData,
        bytes4 reasonSelector,
        bytes memory exactReason
    ) internal {
        uint256 snap = vm.snapshotState();
        BalanceDelta base = _swap(key, trader, zeroForOne, amountSpecified, "");
        Snap memory baseAfter = _snap();
        vm.revertToState(snap);

        Snap memory b = _snap();
        vm.recordLogs();
        BalanceDelta d = _swap(key, trader, zeroForOne, amountSpecified, hookData);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Snap memory a = _snap();

        assertEq(BalanceDelta.unwrap(d), BalanceDelta.unwrap(base), string.concat(label, ": delta equals pool-only"));
        _assertSameState(a, baseAfter, label);
        assertEq(a.priyaMumb, b.priyaMumb, string.concat(label, ": Priya wallet MUMB"));
        assertEq(a.priyaUsdc, b.priyaUsdc, string.concat(label, ": Priya wallet USDC"));
        _assertHookClean();

        (bool filled,,) = _findAquaFill(logs);
        assertFalse(filled, string.concat(label, ": no AquaFill"));
        bytes[] memory reasons = _skips(logs);
        assertEq(reasons.length, 1, string.concat(label, ": one AquaSkipped"));
        assertEq(bytes4(reasons[0]), reasonSelector, string.concat(label, ": reason selector"));
        if (exactReason.length > 0) assertEq(reasons[0], exactReason, string.concat(label, ": reason bytes"));
    }

    /// @dev Everything a swap can change, equal to the pool-only run: trader, Priya (wallet and Aqua), PoolManager,
    /// pool liquidity and price.
    function _assertSameState(Snap memory a, Snap memory expected, string memory label) internal pure {
        assertEq(a.traderMumb, expected.traderMumb, string.concat(label, ": trader MUMB"));
        assertEq(a.traderUsdc, expected.traderUsdc, string.concat(label, ": trader USDC"));
        assertEq(a.priyaMumb, expected.priyaMumb, string.concat(label, ": Priya MUMB vs pool-only"));
        assertEq(a.priyaUsdc, expected.priyaUsdc, string.concat(label, ": Priya USDC vs pool-only"));
        assertEq(a.aquaMumb, expected.aquaMumb, string.concat(label, ": Aqua MUMB"));
        assertEq(a.aquaUsdc, expected.aquaUsdc, string.concat(label, ": Aqua USDC"));
        assertEq(a.managerMumb, expected.managerMumb, string.concat(label, ": PoolManager MUMB"));
        assertEq(a.managerUsdc, expected.managerUsdc, string.concat(label, ": PoolManager USDC"));
        assertEq(a.liquidity, expected.liquidity, string.concat(label, ": pool liquidity"));
        assertEq(a.sqrtPriceX96, expected.sqrtPriceX96, string.concat(label, ": pool price"));
    }

    /// @dev The hook holds no tokens and has no approval on the router.
    function _assertHookClean() internal view {
        _assertHookHoldsNothing();
        assertEq(IERC20(USDC).allowance(address(hook), ROUTER), 0, "USDC allowance reset");
        assertEq(mumb.allowance(address(hook), ROUTER), 0, "MUMB allowance reset");
    }

    /// @dev The `reason` of every `AquaSkipped` the hook emitted for the main pool.
    function _skips(Vm.Log[] memory logs) internal view returns (bytes[] memory reasons) {
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (_isSkip(logs[i])) n++;
        }
        reasons = new bytes[](n);
        n = 0;
        for (uint256 i; i < logs.length; i++) {
            if (_isSkip(logs[i])) reasons[n++] = abi.decode(logs[i].data, (bytes));
        }
    }

    function _isSkip(Vm.Log memory log) internal view returns (bool) {
        return log.emitter == address(hook) && log.topics[0] == ConfluenceHook.AquaSkipped.selector
            && log.topics[1] == PoolId.unwrap(poolId);
    }

    /// @dev Ships a second strategy for Priya whose band step is `target`, and registers it on the hook in place of
    /// the first. `target` takes no args.
    function _shipAndRegister(address target) internal {
        ISwapVM.Order memory order = _buildOrder(priya, _buildBandProgram(FEE_0_30_PCT, target, ""));
        address[] memory tokens = new address[](2);
        tokens[0] = address(mumb);
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_MUMB;
        amounts[1] = SHIPPED_USDC;

        vm.startPrank(priya);
        aqua.ship(ROUTER, abi.encode(order), tokens, amounts);
        hook.registerOrder(key, order);
        vm.stopPrank();
    }

    /// @dev `PoolBase._swap`, but the whole swap runs with at most `gasCap` gas.
    function _swapWithGas(bool zeroForOne, int256 amountSpecified, bytes memory hookData, uint256 gasCap)
        internal
        returns (BalanceDelta delta)
    {
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        delta = swapRouter.swap{gas: gasCap}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
    }

    /// @dev One 1,000 USDC exact-input swap with `hookData` under a transaction gas limit of `limit`; false if it
    /// reverted. Leaves its state changes in place on success.
    function _tryAtLimit(uint256 limit, bytes memory hookData) internal returns (bool ok) {
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: usdcForMumb(),
            amountSpecified: -int256(SWAP_USDC),
            sqrtPriceLimitX96: usdcForMumb() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.prank(trader);
        try swapRouter.swap{gas: limit}(key, params, settings, hookData) returns (BalanceDelta) {
            ok = true;
        } catch {}
    }

    /// @dev The hinted swap at `limit`, run from the current state, which it leaves unchanged: whether it passed,
    /// the `AquaSkipped` reasons, and whether an `AquaFill` happened.
    function _hintedAtLimit(uint256 limit) internal returns (bool ok, bytes[] memory skips, bool filled) {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        ok = _tryAtLimit(limit, _hint(SWAP_USDC));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.revertToState(snap);
        skips = _skips(logs);
        (filled,,) = _findAquaFill(logs);
    }

    /// @dev True if the only skip is `InsufficientGas`.
    function _isGasSkip(bytes[] memory skips) internal pure returns (bool) {
        return skips.length == 1 && bytes4(skips[0]) == ConfluenceHook.InsufficientGas.selector;
    }

    /// @dev The transaction gas limits of the sweep: 285,000 to 500,000 in steps of 5,000, then eight larger ones.
    function _gasLimits() internal pure returns (uint256[] memory limits) {
        uint256 n = (500_000 - 285_000) / 5_000 + 1;
        limits = new uint256[](n + 8);
        for (uint256 i; i < n; i++) {
            limits[i] = 285_000 + i * 5_000;
        }
        uint256[8] memory high =
            [uint256(550_000), 600_000, 700_000, 800_000, 1_000_000, 1_500_000, 2_000_000, 3_000_000];
        for (uint256 i; i < 8; i++) {
            limits[n + i] = high[i];
        }
    }

    /// @dev At every limit where the pool-only swap passes, the hinted swap must pass. Returns at how many limits
    /// the Aqua leg filled.
    function _sweepGasLimits(string memory label) internal returns (uint256 filled) {
        uint256[] memory limits = _gasLimits();
        uint256 checked;
        for (uint256 i; i < limits.length; i++) {
            uint256 snap = vm.snapshotState();
            bool poolOk = _tryAtLimit(limits[i], "");
            vm.revertToState(snap);
            if (!poolOk) continue; // the pool alone cannot do it, so there is nothing for Aqua to preserve
            checked++;

            (bool hintOk,, bool wasFilled) = _hintedAtLimit(limits[i]);
            assertTrue(hintOk, string.concat(label, ": hinted swap reverted at gas limit ", vm.toString(limits[i])));
            if (wasFilled) filled++;
        }
        assertGe(checked, 50, string.concat(label, ": precondition: the pool alone passes at (nearly) every limit"));
    }

    function _absDiff(uint160 x, uint160 y) internal pure returns (uint256) {
        return x > y ? uint256(x - y) : uint256(y - x);
    }
}
