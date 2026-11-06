// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {BPS} from "@1inch/swap-vm/src/instructions/Fee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PoolPriceBandExtruction} from "../../src/PoolPriceBandExtruction.sol";
import {PoolBase} from "./PoolBase.t.sol";
import {StrategyLib} from "./StrategyLib.sol";

/// @notice F05 and later: PoolBase plus Priya's strategy shipped to the canonical router with the band built from
/// the hooked pool's key, and her order registered on the hook.
abstract contract ConfluenceBase is PoolBase, StrategyLib {
    using StateLibrary for IPoolManager;

    uint256 internal constant SHIPPED_MUMB = 100_000e18;
    uint256 internal constant SHIPPED_USDC = 100_000e6;
    uint16 internal constant BAND_BPS = 200;

    /// @dev Local copy of the hook's `AquaFill` event (ARCHITECTURE section 6) so the tests compile before the hook
    /// declares it. Topics and data are identical; stage B swaps this for `ConfluenceHook.AquaFill`.
    event AquaFill(PoolId indexed poolId, address indexed maker, uint256 amountIn, uint256 amountOut);

    error NoPoolSwapEvent();

    IAqua internal aqua = IAqua(AQUA);
    PoolPriceBandExtruction internal band;
    ISwapVM.Order internal priyaOrder;
    bytes32 internal strategyHash;

    /// @dev Everything a F05 test compares before and after a swap.
    struct Snap {
        uint256 traderMumb;
        uint256 traderUsdc;
        uint256 priyaMumb;
        uint256 priyaUsdc;
        uint256 aquaMumb;
        uint256 aquaUsdc;
        uint256 managerMumb;
        uint256 managerUsdc;
        uint128 liquidity;
        uint160 sqrtPriceX96;
    }

    constructor() StrategyLib(AQUA) {}

    function setUp() public virtual override {
        super.setUp();

        band = new PoolPriceBandExtruction();

        vm.startPrank(priya);
        mumb.approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        vm.stopPrank();

        _shipBand();

        vm.prank(priya);
        hook.registerOrder(key, priyaOrder);
    }

    // ---------------------------------------------------------------- strategy

    /// @dev F03's `_shipBand`, with the band built from the hooked pool's key: 0.30% fee, XYC, band step.
    function _shipBand() internal {
        bytes memory args = band.build(manager, key, BAND_BPS);
        priyaOrder = _buildOrder(priya, _buildBandProgram(FEE_0_30_PCT, address(band), args));

        address[] memory tokens = new address[](2);
        tokens[0] = address(mumb);
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_MUMB;
        amounts[1] = SHIPPED_USDC;

        vm.prank(priya);
        strategyHash = aqua.ship(ROUTER, abi.encode(priyaOrder), tokens, amounts);
    }

    function _hint(uint256 amountIn) internal pure returns (bytes memory) {
        return abi.encode(amountIn);
    }

    // ---------------------------------------------------------------- expected amounts

    function _netOfFee(uint256 amountIn) internal pure returns (uint256) {
        return amountIn - Math.ceilDiv(amountIn * FEE_0_30_PCT, BPS);
    }

    function _shippedBalance(address token) internal view returns (uint256) {
        return token == USDC ? SHIPPED_USDC : (token == address(mumb) ? SHIPPED_MUMB : 0);
    }

    /// @dev Fee (rounded up, on input) then XYC (rounded down) on the shipped balances, for a first fill.
    function _expectedAquaOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        uint256 net = _netOfFee(amountIn);
        return (net * _shippedBalance(tokenOut)) / (_shippedBalance(tokenIn) + net);
    }

    // ---------------------------------------------------------------- state and logs

    function _aquaBalance(address token) internal view returns (uint256 balance) {
        (balance,) = aqua.rawBalances(priya, ROUTER, strategyHash, token);
    }

    function _snap() internal view returns (Snap memory s) {
        (s.traderMumb, s.traderUsdc) = balances(trader);
        (s.priyaMumb, s.priyaUsdc) = balances(priya);
        s.aquaMumb = _aquaBalance(address(mumb));
        s.aquaUsdc = _aquaBalance(USDC);
        (s.managerMumb, s.managerUsdc) = balances(address(manager));
        s.liquidity = manager.getLiquidity(poolId);
        (s.sqrtPriceX96,,,) = manager.getSlot0(poolId);
    }

    /// @dev An exact-input swap on the main pool with its logs recorded.
    function _swapWithLogs(bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (int128 mumbDelta, int128 usdcDelta, Vm.Log[] memory logs)
    {
        vm.recordLogs();
        BalanceDelta d = _swapExactIn(trader, zeroForOne, amountIn, hookData);
        logs = vm.getRecordedLogs();
        return (mumbAmount(d), usdcAmount(d), logs);
    }

    /// @dev The hook's `AquaFill`, if the swap emitted one.
    function _findAquaFill(Vm.Log[] memory logs)
        internal
        view
        returns (bool found, uint256 amountIn, uint256 amountOut)
    {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == AquaFill.selector) {
                (amountIn, amountOut) = abi.decode(logs[i].data, (uint256, uint256));
                return (true, amountIn, amountOut);
            }
        }
    }

    /// @dev The pool leg of the swap: the PoolManager's `Swap` event for our pool, split by token. It is the
    /// pool's own delta, before the hook's delta is subtracted from the trader's.
    function _poolLeg(Vm.Log[] memory logs) internal view returns (int128 mumbAmt, int128 usdcAmt) {
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector
                    && logs[i].topics[1] == PoolId.unwrap(poolId)
            ) {
                (int128 a0, int128 a1,,,,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return usdcIsCurrency0 ? (a1, a0) : (a0, a1);
            }
        }
        revert NoPoolSwapEvent();
    }

    /// @dev The direction flag for "pay MUMB, receive USDC".
    function mumbForUsdc() internal view returns (bool zeroForOne) {
        return !usdcIsCurrency0;
    }
}
