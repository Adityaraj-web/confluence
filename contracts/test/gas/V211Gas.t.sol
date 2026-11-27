// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {MakerVenue} from "../../src/libraries/MakerVenue.sol";
import {PoolVenue} from "../../src/libraries/PoolVenue.sol";
import {SplitBase} from "../base/SplitBase.t.sol";

/// @notice V2-11 gas measurements, one method for every number (M11). Logs only: the ceilings and the snapshot
///         scenarios are added after the levers are ranked.
/// @dev M11: every measurement starts from one `vm.snapshotState()` of the same fixture, moves to the next block (so
///      the swap is the block's first and runs the anchor update), cools every account the swap touches (the manager,
///      the hook, both splitters, Aqua, the router, USDC and its implementation, MUMB, the guard, all six makers, the
///      trader and the swap router), and takes `gasleft()` around the swap through `PoolSwapTest`. It differs from
///      V2-07's `gasLog` (no revert between rows, no anchor update in later rows), V2-09's and V2-10's tables
///      (V2-10's cools only the splitter of the mode it measures and has no 6-maker row), and none of them cooled the
///      USDC implementation, the trader or the swap router.
contract V211GasTest is SplitBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant USDC_IMPL = 0x43506849D7C04F9138D1A2050bbF3A0c054402dd;
    uint256 internal constant EXACT_IN_USDC = 1_000e6;
    uint256 internal constant EXACT_IN_MUMB = 1_000e18;
    uint256 internal constant EXACT_OUT_MUMB = 990e18;
    uint256 internal constant EXACT_OUT_USDC = 990e6;

    uint256 internal bn0;
    uint256 internal ts0;

    // ------------------------------------------------------------------------------------------ M11

    function _coolAll() internal {
        address[10] memory t = [
            address(manager),
            address(hookV2),
            address(splitter),
            address(splitterOut),
            AQUA,
            ROUTER,
            USDC,
            USDC_IMPL,
            address(mumb),
            _guard()
        ];
        for (uint256 i; i < t.length; i++) {
            vm.cool(t[i]);
        }
        for (uint256 i; i < 6; i++) {
            vm.cool(makers[i]);
        }
        vm.cool(trader);
        vm.cool(address(swapRouter));
    }

    function _nextBlockM11() internal {
        vm.roll(bn0 + 1);
        vm.warp(ts0 + 12);
    }

    /// @dev One M11 swap on `k`; returns the gas and the number of FILLED legs.
    function _m11(PoolKey memory k, bool zfo, bool exactIn, uint256 amount)
        internal
        returns (uint256 used, uint256 filled)
    {
        _nextBlockM11();
        _coolAll();
        vm.recordLogs();
        uint256 g = gasleft();
        _swap(k, trader, zfo, exactIn ? -int256(amount) : int256(amount), "");
        used = g - gasleft();
        (ConfluenceHook.Leg[] memory legs,) = _legsFrom(vm.getRecordedLogs(), address(hookV2));
        filled = _countStatus(legs, 0);
    }

    function _amount(bool zfo, bool exactIn) internal pure returns (uint256) {
        if (exactIn) return zfo ? EXACT_IN_USDC : EXACT_IN_MUMB;
        return zfo ? EXACT_OUT_MUMB : EXACT_OUT_USDC;
    }

    /// @dev Registers `n` makers (0, 1, 3 or 6) on `keyV2` as V2-07's `gasLog` does.
    function _makers(uint256 n) internal {
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

    /// @dev A hookless pool with the same fee, spacing, price and liquidity as `keyV2`: the floor.
    function _plainPool() internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: keyV2.currency0,
            currency1: keyV2.currency1,
            fee: keyV2.fee,
            tickSpacing: keyV2.tickSpacing,
            hooks: IHooks(address(0))
        });
        manager.initialize(k, anchorSqrtPriceX96(true));
        deal(USDC, deployer, IERC20(USDC).balanceOf(deployer) + 1e15);
        vm.startPrank(deployer);
        mumb.mint(deployer, 1e27);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        mumb.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(manager.getLiquidity(idV2))),
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------ the table

    /// @dev Full swaps: the hookless floor, then 0, 1, 3 and 6 makers, exact in and out, both directions.
    function test_V211_gasTable() public {
        _initExact(keyV2);
        bn0 = block.number;
        ts0 = block.timestamp;
        PoolKey memory plain = _plainPool();
        uint256 base = vm.snapshotState();
        uint8[4] memory ns = [0, 1, 3, 6];

        console2.log("M11 full swaps: label | gas | filled legs");
        for (uint256 d; d < 2; d++) {
            bool zfo = d == 0;
            for (uint256 m; m < 2; m++) {
                bool exactIn = m == 0;
                uint256 amt = _amount(zfo, exactIn);
                string memory tag = string.concat(zfo ? "USDC in " : "MUMB in ", exactIn ? "exact-in  " : "exact-out ");
                vm.revertToState(base);
                (uint256 gp,) = _m11(plain, zfo, exactIn, amt);
                console2.log(string.concat(tag, "hookless floor"), gp);
                for (uint256 i; i < ns.length; i++) {
                    vm.revertToState(base);
                    _makers(ns[i]);
                    (uint256 g, uint256 f) = _m11(keyV2, zfo, exactIn, amt);
                    console2.log(string.concat(tag, vm.toString(uint256(ns[i])), " makers"), g, f);
                }
            }
        }
    }

    /// @dev One cold plan call per splitter (the hook's call without the hook), 1, 3 and 6 makers.
    function test_V211_planGas() public {
        _initExact(keyV2);
        bn0 = block.number;
        ts0 = block.timestamp;
        uint256 base = vm.snapshotState();
        uint8[3] memory ns = [1, 3, 6];
        console2.log("M11 plan gas (cold, direct call): label | gas");
        for (uint256 i; i < ns.length; i++) {
            vm.revertToState(base);
            _makers(ns[i]);
            for (uint256 m; m < 2; m++) {
                bool exactIn = m == 0;
                _nextBlockM11();
                (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
                _coolAll();
                uint256 g = gasleft();
                if (exactIn) {
                    splitter.planExactIn(keyV2, true, TickMath.MIN_SQRT_PRICE + 1, EXACT_IN_USDC, snap, emaX);
                } else {
                    splitterOut.planExactOut(keyV2, true, TickMath.MIN_SQRT_PRICE + 1, EXACT_OUT_MUMB, snap, emaX);
                }
                g -= gasleft();
                console2.log(
                    string.concat(exactIn ? "planExactIn  " : "planExactOut ", vm.toString(uint256(ns[i])), " makers"),
                    g
                );
            }
        }
    }

    /// @dev `MakerVenue.read` / `readOut` and `PoolVenue.read`, called inline (internal libraries: no harness).
    function test_V211_readGas() public {
        _initExact(keyV2);
        bn0 = block.number;
        ts0 = block.timestamp;
        uint256 base = vm.snapshotState();
        uint8[3] memory ns = [1, 3, 6];
        console2.log("M11 library reads (cold, inline): label | gas");
        for (uint256 i; i < ns.length; i++) {
            vm.revertToState(base);
            _makers(ns[i]);
            _nextBlockM11();
            (int24 snap, int56 emaX,) = hookV2.anchorOfX(idV2);
            ConfluenceHook.Slot[] memory s = hookV2.strategiesOf(idV2);
            MakerVenue.Entry[] memory e = new MakerVenue.Entry[](s.length);
            for (uint256 j; j < s.length; j++) {
                e[j] = MakerVenue.Entry({maker: s[j].maker, params: s[j].params, strategyHash: s[j].strategyHash});
            }
            _coolAll();
            uint256 g = gasleft();
            MakerVenue.read(manager, keyV2, _guard(), e, true, snap, emaX);
            g -= gasleft();
            console2.log(string.concat("MakerVenue.read    ", vm.toString(uint256(ns[i])), " makers"), g);
            _coolAll();
            g = gasleft();
            MakerVenue.readOut(manager, keyV2, _guard(), e, true, snap, emaX);
            g -= gasleft();
            console2.log(string.concat("MakerVenue.readOut ", vm.toString(uint256(ns[i])), " makers"), g);
        }
        _poolReadGas(keyV2, "PoolVenue.read v1 pool (1 range, end of liquidity)");
        PoolKey memory gap = _gapKey();
        _poolReadGas(gap, "PoolVenue.read 8-segment gapped pool");
    }

    function _poolReadGas(PoolKey memory k, string memory label) internal {
        _coolAll();
        uint256 g = gasleft();
        PoolVenue.Pool memory p = PoolVenue.read(manager, k.toId(), k.tickSpacing, true, TickMath.MIN_SQRT_PRICE + 1);
        g -= gasleft();
        console2.log(label, g, p.segments.length);
    }
}
