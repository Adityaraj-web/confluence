// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {PoolBase} from "./PoolBase.t.sol";
import {StrategyLib} from "./StrategyLib.sol";

/// @notice V2-05's registry fixture, moved verbatim out of `V205RegistryTest` so V2-06 can reuse it (V2-02's
///         `SplitHelpers` pattern): the v2 hook, its pool, twelve maker addresses, and the helpers that fund, ship
///         and register a T1 strategy.
abstract contract RegistryBase is PoolBase, StrategyLib {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant N_MAKERS = 12;

    ConfluenceHook internal hookV2;
    PoolKey internal keyV2;
    PoolId internal idV2;
    address[N_MAKERS] internal makers;

    constructor() StrategyLib(AQUA) {}

    function setUp() public override {
        super.setUp();
        // The expected-depth helper below puts USDC on the currency0 side (D-28's premise, tested by V200).
        require(usdcIsCurrency0, "premise: USDC is currency0");
        hookV2 = _deployHookV2();
        keyV2 = _createPool(IHooks(address(hookV2)));
        idV2 = keyV2.toId();
        for (uint256 i; i < N_MAKERS; i++) {
            makers[i] = makeAddr(string.concat("maker", vm.toString(i)));
        }
    }

    // ---------------------------------------------------------------- helpers

    function _p() internal pure returns (StrategyTemplate.Params memory) {
        return StrategyTemplate.Params({feeE9: FEE_0_30_PCT, bandBps: 200, driftTicks: 300, exclusive: true, salt: 0});
    }

    function _guard() internal view returns (address) {
        return address(hookV2.bandGuard());
    }

    function _program(StrategyTemplate.Params memory p) internal view returns (bytes memory) {
        return StrategyTemplate.program(p, manager, keyV2, _guard());
    }

    function _hash(address m, StrategyTemplate.Params memory p) internal view returns (bytes32) {
        return StrategyTemplate.strategyHash(StrategyTemplate.order(m, _program(p)));
    }

    /// @dev Gives `m` a wallet of `mumbAmt` and `usdcAmt` (on top of what it has) and approves Aqua for everything.
    function _fund(address m, uint256 mumbAmt, uint256 usdcAmt) internal {
        vm.prank(deployer);
        mumb.mint(m, mumbAmt);
        deal(USDC, m, IERC20(USDC).balanceOf(m) + usdcAmt);
        vm.startPrank(m);
        mumb.approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        vm.stopPrank();
    }

    function _tokens() internal view returns (address[] memory t) {
        t = new address[](2);
        t[0] = USDC; // currency0 (premise)
        t[1] = address(mumb);
    }

    /// @dev Ships `prog` as `m`'s order with the given virtual balances.
    function _shipProgram(address m, bytes memory prog, uint256 mumbVirt, uint256 usdcVirt)
        internal
        returns (bytes32 h)
    {
        uint256[] memory a = new uint256[](2);
        a[0] = usdcVirt;
        a[1] = mumbVirt;
        vm.prank(m);
        h = IAqua(AQUA).ship(ROUTER, abi.encode(StrategyTemplate.order(m, prog)), _tokens(), a);
    }

    function _ship(address m, StrategyTemplate.Params memory p, uint256 mumbVirt, uint256 usdcVirt)
        internal
        returns (bytes32)
    {
        return _shipProgram(m, _program(p), mumbVirt, usdcVirt);
    }

    function _register(address m, StrategyTemplate.Params memory p) internal {
        vm.prank(m);
        hookV2.register(keyV2, p);
    }

    /// @dev Fund, ship and register in one go: wallet = virtual = the given amounts.
    function _join(address m, uint256 mumbAmt, uint256 usdcAmt, StrategyTemplate.Params memory p)
        internal
        returns (bytes32 h)
    {
        _fund(m, mumbAmt, usdcAmt);
        h = _ship(m, p, mumbAmt, usdcAmt);
        _register(m, p);
    }

    /// @dev One tiny swap records the pool's first snapshot (a pool with no swaps has no anchor).
    function _initAnchor() internal {
        _swap(keyV2, trader, usdcForMumb(), -int256(10e6), "");
    }

    function _snap() internal view returns (int24 s) {
        (s,,) = hookV2.anchorOf(idV2);
    }

    /// @dev The spec's depth, written out again here: both sides valued in currency1 (MUMB) at the snapshot, with the
    ///      same two-step rounding as the library. Amounts are the (already minimised) per-token depths.
    function _expected(uint256 mumbDepth, uint256 usdcDepth, int24 snap) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(snap);
        return FullMath.mulDiv(FullMath.mulDiv(usdcDepth, s, 2 ** 96), s, 2 ** 96) + mumbDepth;
    }

    /// @dev Makers 0..n-1 with wallet = virtual = (i+1)*1000 MUMB and (i+1)*1000 USDC.
    function _fill(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _join(makers[i], (i + 1) * 1000e18, (i + 1) * 1000e6, _p());
        }
    }

    function _isRegistered(address m) internal view returns (bool) {
        ConfluenceHook.Slot[] memory s = hookV2.strategiesOf(idV2);
        for (uint256 i; i < s.length; i++) {
            if (s[i].maker == m) return true;
        }
        return false;
    }
}
