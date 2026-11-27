// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

import {ConfluenceBase} from "../../base/ConfluenceBase.t.sol";

/// @notice V2-10 scenario 1 on v1 (`ConfluenceHookV1` and `PoolPriceBandExtruction`, frozen in `src/v1/`): the attack
///         SUCCEEDS. v1's band reads the pool's SPOT price, so an attacker who moves spot inside the block moves the band
///         with it. Priya's curve is a little stale (0.95 USDC per MUMB, 5% under fair); spot is 1.0, so the band (2%) refuses
///         it. The attacker sells 1,500 MUMB into the pool (spot falls about 3.4%), after which her curve is inside the
///         band; the attacker's hinted swap fills it, and the attacker buys back the MUMB it sold. Attacker PnL is positive
///         and Priya's is negative. The v2 counterparts are `A01SameBlock` (snapshot unmoved, legs inside its band) and
///         `V204BandGuardFork.test_V204_sameBlockAttackRefused` (the same fill reverts `BandExceeded`).
contract A01V1SameBlockTest is ConfluenceBase {
    uint256 internal constant STALE_USDC = 95_000e6;
    uint256 internal constant PUSH_MUMB = 1_500e18;
    uint256 internal constant FILL_USDC = 1_000e6;

    function _value(address who) internal view returns (int256) {
        return int256(IERC20(USDC).balanceOf(who)) + int256(mumb.balanceOf(who) / 1e12); // MUMB at the block-start 1 USDC
    }

    function test_V210_v1SameBlockPushPaysTheAttacker() public {
        // Priya replaces her fair strategy by a stale one (0.95).
        address[] memory tokens = new address[](2);
        tokens[0] = address(mumb);
        tokens[1] = USDC;
        vm.prank(priya);
        aqua.dock(ROUTER, strategyHash, tokens);
        // One more unit of fee than the fair strategy: a strategy's hash is its program, and a hash can be shipped once.
        bytes memory args = band.build(manager, key, BAND_BPS);
        ISwapVM.Order memory stale = _buildOrder(priya, _buildBandProgram(FEE_0_30_PCT + 1, address(band), args));
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (SHIPPED_MUMB, STALE_USDC);
        vm.prank(priya);
        aqua.ship(ROUTER, abi.encode(stale), tokens, amounts);
        vm.prank(priya);
        hook.registerOrder(key, stale);

        vm.prank(deployer);
        mumb.mint(trader, 10_000e18);
        deal(USDC, trader, 100_000e6);
        int256 a0 = _value(trader);
        int256 p0 = _value(priya);

        // Block's first swap is the push itself: v1 has no snapshot to defend.
        _swap(key, trader, !usdcForMumb(), -int256(PUSH_MUMB), ""); // sell 1,500 MUMB: spot falls
        _swap(key, trader, usdcForMumb(), -int256(FILL_USDC), _hint(FILL_USDC)); // the hinted fill from Priya's stale curve
        _swap(key, trader, usdcForMumb(), int256(PUSH_MUMB), ""); // buy back exactly the MUMB it sold

        int256 attacker = _value(trader) - a0;
        int256 priyaPnl = _value(priya) - p0;
        emit log_named_int("v1 attacker PnL (raw USDC)", attacker);
        emit log_named_int("v1 maker (Priya) PnL (raw USDC, MUMB at 1 USDC)", priyaPnl);
        assertGt(attacker, 0, "v1: the same-block push pays the attacker");
        assertLt(priyaPnl, 0, "v1: and costs Priya: the band followed the manipulated spot");
        _assertHookHoldsNothing();
    }
}
