// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {ConfluenceBase} from "../base/ConfluenceBase.t.sol";

/// @notice F05: the hook fills the hinted part of an exact-input swap from Priya's Aqua strategy inside
/// `beforeSwap`, and the pool curve fills the rest.
contract F05AquaLegTest is ConfluenceBase {
    uint256 internal constant SWAP_USDC = 1_000e6;
    uint256 internal constant SWAP_MUMB = 1_000e18;
    uint256 internal constant HINT_60_PCT_USDC = 600e6;
    uint256 internal constant HINT_60_PCT_MUMB = 600e18;

    /// @dev Priya's fill of 1,000 USDC on 100,000 + 100,000 with a 0.30% fee (F02, D-16).
    uint256 internal constant FULL_FILL_MUMB_OUT = 987_158_034_397_061_298_850;
    /// @dev Pool-only buy of 1,000 USDC on the seed position (F04, D-18).
    uint256 internal constant POOL_ONLY_MUMB_OUT = 984_934_194_542_570_551_127;

    // ---------------------------------------------------------------- acceptance

    /// @dev The hour-8 gate.
    function test_F05_fullAquaFill() public {
        Snap memory b = _snap();

        (int128 mumbDelta, int128 usdcDelta, Vm.Log[] memory logs) =
            _swapWithLogs(usdcForMumb(), SWAP_USDC, _hint(SWAP_USDC));

        Snap memory a = _snap();
        (bool found, uint256 fillIn, uint256 fillOut) = _findAquaFill(logs);
        assertTrue(found, "AquaFill emitted");
        assertEq(fillIn, SWAP_USDC, "AquaFill amountIn");
        assertEq(fillOut, FULL_FILL_MUMB_OUT, "AquaFill amountOut");
        // Trader: pays exactly 1,000 USDC, gets Priya's fill and nothing from the pool.
        assertEq(a.traderUsdc, b.traderUsdc - SWAP_USDC, "trader USDC");
        assertEq(a.traderMumb, b.traderMumb + FULL_FILL_MUMB_OUT, "trader MUMB");
        assertEq(int256(mumbDelta), int256(FULL_FILL_MUMB_OUT), "delta MUMB");
        assertEq(int256(usdcDelta), -int256(SWAP_USDC), "delta USDC");
        // Priya's wallet: MUMB down by the same amount, USDC pushed in.
        assertEq(a.priyaMumb, b.priyaMumb - FULL_FILL_MUMB_OUT, "Priya wallet MUMB");
        assertEq(a.priyaUsdc, b.priyaUsdc + SWAP_USDC, "Priya wallet USDC");
        // Priya's Aqua virtual balances.
        assertEq(a.aquaUsdc, b.aquaUsdc + SWAP_USDC, "Aqua USDC");
        assertEq(a.aquaMumb, b.aquaMumb - FULL_FILL_MUMB_OUT, "Aqua MUMB");
        // The pool curve did not trade: in-range liquidity and price are unchanged.
        assertEq(a.liquidity, b.liquidity, "pool liquidity");
        assertEq(a.sqrtPriceX96, b.sqrtPriceX96, "pool price");
        // The PoolManager's balances are unchanged: the hook took and settled in the same call.
        assertEq(a.managerUsdc, b.managerUsdc, "PoolManager USDC");
        assertEq(a.managerMumb, b.managerMumb, "PoolManager MUMB");
        _assertHookHoldsNothing();
    }

    function test_F05_partialSplit() public {
        Snap memory b = _snap();
        uint256 aquaOut = _expectedAquaOut(USDC, address(mumb), HINT_60_PCT_USDC);

        (int128 mumbDelta, int128 usdcDelta, Vm.Log[] memory logs) =
            _swapWithLogs(usdcForMumb(), SWAP_USDC, _hint(HINT_60_PCT_USDC));

        Snap memory a = _snap();
        (bool found, uint256 fillIn, uint256 fillOut) = _findAquaFill(logs);
        assertTrue(found, "AquaFill emitted");
        assertEq(fillIn, HINT_60_PCT_USDC, "AquaFill amountIn");
        assertEq(fillOut, aquaOut, "AquaFill amountOut");

        // The pool leg took the other 400 USDC.
        (int128 poolMumb, int128 poolUsdc) = _poolLeg(logs);
        assertEq(int256(poolUsdc), -int256(SWAP_USDC - HINT_60_PCT_USDC), "pool leg USDC in");
        assertGt(poolMumb, 0, "pool leg MUMB out");

        // Trader's MUMB = Aqua leg out + pool leg out, and USDC down by exactly the amount in.
        assertEq(a.traderMumb - b.traderMumb, fillOut + uint256(uint128(poolMumb)), "trader MUMB = legs");
        assertEq(int256(mumbDelta), int256(a.traderMumb - b.traderMumb), "delta MUMB");
        assertEq(b.traderUsdc - a.traderUsdc, SWAP_USDC, "trader USDC");
        assertEq(int256(usdcDelta), -int256(SWAP_USDC), "delta USDC");
        // Priya.
        assertEq(a.priyaMumb, b.priyaMumb - fillOut, "Priya wallet MUMB");
        assertEq(a.priyaUsdc, b.priyaUsdc + HINT_60_PCT_USDC, "Priya wallet USDC");
        assertEq(a.aquaUsdc, b.aquaUsdc + HINT_60_PCT_USDC, "Aqua USDC");
        assertEq(a.aquaMumb, b.aquaMumb - fillOut, "Aqua MUMB");
        // PoolManager: it keeps the pool leg's USDC and pays out the pool leg's MUMB, nothing else.
        assertEq(a.managerUsdc, b.managerUsdc + (SWAP_USDC - HINT_60_PCT_USDC), "PoolManager USDC");
        assertEq(a.managerMumb, b.managerMumb - uint256(uint128(poolMumb)), "PoolManager MUMB");
        // The pool leg moved the price but stayed in range.
        assertTrue(a.sqrtPriceX96 != b.sqrtPriceX96, "pool price moved");
        assertEq(a.liquidity, b.liquidity, "pool liquidity");
        _assertHookHoldsNothing();
    }

    function test_F05_splitBeatsPoolOnly() public {
        (uint256 mumbBefore,) = balances(trader);
        uint256 snap = vm.snapshotState();

        _swapExactIn(trader, usdcForMumb(), SWAP_USDC, "");
        uint256 poolOnly = mumb.balanceOf(trader) - mumbBefore;

        vm.revertToState(snap);

        _swapExactIn(trader, usdcForMumb(), SWAP_USDC, _hint(HINT_60_PCT_USDC));
        uint256 split = mumb.balanceOf(trader) - mumbBefore;

        assertEq(poolOnly, POOL_ONLY_MUMB_OUT, "pool-only output");
        assertGt(split, poolOnly, "split beats pool-only");
        _assertHookHoldsNothing();
    }

    function test_F05_reverseDirection() public {
        Snap memory b = _snap();
        uint256 aquaOut = _expectedAquaOut(address(mumb), USDC, HINT_60_PCT_MUMB);

        (int128 mumbDelta, int128 usdcDelta, Vm.Log[] memory logs) =
            _swapWithLogs(mumbForUsdc(), SWAP_MUMB, _hint(HINT_60_PCT_MUMB));

        Snap memory a = _snap();
        (bool found, uint256 fillIn, uint256 fillOut) = _findAquaFill(logs);
        assertTrue(found, "AquaFill emitted");
        assertEq(fillIn, HINT_60_PCT_MUMB, "AquaFill amountIn");
        assertEq(fillOut, aquaOut, "AquaFill amountOut");

        (int128 poolMumb, int128 poolUsdc) = _poolLeg(logs);
        assertEq(int256(poolMumb), -int256(SWAP_MUMB - HINT_60_PCT_MUMB), "pool leg MUMB in");
        assertGt(poolUsdc, 0, "pool leg USDC out");

        // Trader pays 1,000 MUMB and gets Aqua out + pool out in USDC.
        assertEq(b.traderMumb - a.traderMumb, SWAP_MUMB, "trader MUMB");
        assertEq(a.traderUsdc - b.traderUsdc, fillOut + uint256(uint128(poolUsdc)), "trader USDC = legs");
        assertEq(int256(mumbDelta), -int256(SWAP_MUMB), "delta MUMB");
        assertEq(int256(usdcDelta), int256(a.traderUsdc - b.traderUsdc), "delta USDC");
        // Priya received 600 MUMB and paid USDC.
        assertEq(a.priyaMumb, b.priyaMumb + HINT_60_PCT_MUMB, "Priya wallet MUMB");
        assertEq(a.priyaUsdc, b.priyaUsdc - fillOut, "Priya wallet USDC");
        assertEq(a.aquaMumb, b.aquaMumb + HINT_60_PCT_MUMB, "Aqua MUMB");
        assertEq(a.aquaUsdc, b.aquaUsdc - fillOut, "Aqua USDC");
        // PoolManager: it keeps the pool leg's MUMB and pays out the pool leg's USDC.
        assertEq(a.managerMumb, b.managerMumb + (SWAP_MUMB - HINT_60_PCT_MUMB), "PoolManager MUMB");
        assertEq(a.managerUsdc, b.managerUsdc - uint256(uint128(poolUsdc)), "PoolManager USDC");
        _assertHookHoldsNothing();
    }

    function test_F05_zeroHintIsPoolOnly() public {
        Snap memory b = _snap();

        vm.expectCall(ROUTER, abi.encodeWithSelector(ISwapVM.swap.selector), 0);
        BalanceDelta d = _swapExactIn(trader, usdcForMumb(), SWAP_USDC, _hint(0));

        Snap memory a = _snap();
        assertEq(a.traderMumb - b.traderMumb, POOL_ONLY_MUMB_OUT, "same output as F04");
        assertEq(int256(mumbAmount(d)), int256(POOL_ONLY_MUMB_OUT), "delta MUMB");
        assertEq(b.traderUsdc - a.traderUsdc, SWAP_USDC, "trader USDC");
        assertEq(a.priyaMumb, b.priyaMumb, "Priya wallet MUMB untouched");
        assertEq(a.priyaUsdc, b.priyaUsdc, "Priya wallet USDC untouched");
        assertEq(a.aquaMumb, b.aquaMumb, "Aqua MUMB untouched");
        assertEq(a.aquaUsdc, b.aquaUsdc, "Aqua USDC untouched");
        _assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------- skip rules and hygiene

    function test_F05_skipBadHintLength() public {
        vm.expectCall(ROUTER, abi.encodeWithSelector(ISwapVM.swap.selector), 0);
        _assertSkipped("31 bytes", -int256(SWAP_USDC), new bytes(31));
        _assertSkipped("33 bytes", -int256(SWAP_USDC), abi.encodePacked(_hint(SWAP_USDC), hex"00"));
        _assertSkipped("64 bytes", -int256(SWAP_USDC), abi.encode(SWAP_USDC, SWAP_USDC));
    }

    function test_F05_skipHintAboveAmount() public {
        vm.expectCall(ROUTER, abi.encodeWithSelector(ISwapVM.swap.selector), 0);
        _assertSkipped("hint above amount", -int256(SWAP_USDC), _hint(SWAP_USDC + 1));
    }

    function test_F05_skipExactOutput() public {
        vm.expectCall(ROUTER, abi.encodeWithSelector(ISwapVM.swap.selector), 0);
        _assertSkipped("exact output", int256(500e18), _hint(100e6));
    }

    function test_F05_skipNoOrder() public {
        vm.prank(priya);
        hook.unregisterOrder(key);

        vm.expectCall(ROUTER, abi.encodeWithSelector(ISwapVM.swap.selector), 0);
        _assertSkipped("no order", -int256(SWAP_USDC), _hint(SWAP_USDC));
    }

    function test_F05_approvalReset() public {
        _swapExactIn(trader, usdcForMumb(), SWAP_USDC, _hint(HINT_60_PCT_USDC));
        assertEq(IERC20(USDC).allowance(address(hook), ROUTER), 0, "USDC allowance reset");
        assertEq(mumb.allowance(address(hook), ROUTER), 0, "MUMB allowance reset");

        _swapExactIn(trader, mumbForUsdc(), SWAP_MUMB, _hint(HINT_60_PCT_MUMB));
        assertEq(IERC20(USDC).allowance(address(hook), ROUTER), 0, "USDC allowance reset, reverse");
        assertEq(mumb.allowance(address(hook), ROUTER), 0, "MUMB allowance reset, reverse");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev From one state: the swap with empty hookData (pool-only by F04) and the swap with `hookData` give the
    /// same delta, and Priya's wallet and Aqua balances do not move. The caller sets `vm.expectCall(..., 0)` once.
    function _assertSkipped(string memory label, int256 amountSpecified, bytes memory hookData) internal {
        uint256 snap = vm.snapshotState();
        BalanceDelta base = _swap(key, trader, usdcForMumb(), amountSpecified, "");
        vm.revertToState(snap);

        Snap memory b = _snap();
        BalanceDelta d = _swap(key, trader, usdcForMumb(), amountSpecified, hookData);
        Snap memory a = _snap();

        assertEq(BalanceDelta.unwrap(d), BalanceDelta.unwrap(base), label);
        assertEq(a.priyaMumb, b.priyaMumb, label);
        assertEq(a.priyaUsdc, b.priyaUsdc, label);
        assertEq(a.aquaMumb, b.aquaMumb, label);
        assertEq(a.aquaUsdc, b.aquaUsdc, label);
        _assertHookHoldsNothing();
    }
}
