// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AttackBase} from "./AttackBase.t.sol";
import {LegStatus} from "../../src/libraries/PlanCheck.sol";

/// @notice V2-10 scenario 8: dust. Swaps of 1 to a few hundred raw units, both directions, repeated, hoping rounding leaks
///         value out of a maker (each fill rounds the fee up and the output down, so rounding favours the maker) or that a
///         dust leg breaks something. Legs under `MIN_LEG_BPS` of the trade are skipped. The maker's value never falls.
contract A08DustTest is AttackBase {
    function test_V210_dustNeverCostsTheMaker() public {
        _oneMakerPool(100_000e18, 100_000e6);
        int256 m0 = _value(makers[0], address(mumb));
        uint256 w0 = mumb.balanceOf(makers[0]);
        uint256 u0 = IERC20D(USDC).balanceOf(makers[0]);
        uint256[6] memory sizes = [uint256(1), 2, 10, 100, 500, 999];
        uint256 filled;
        uint256 minLeg;
        for (uint256 round; round < 5; round++) {
            for (uint256 i; i < sizes.length; i++) {
                for (uint256 d; d < 2; d++) {
                    bool zfo = d == 0;
                    // USDC raw units (1e-6 USDC), or MUMB raw units (1e-18 MUMB: dust of 1 to 999 wei).
                    Run memory r = _run(keyV2, zfo, sizes[i], "");
                    if (r.legs.length > 0) {
                        if (r.legs[0].status == LegStatus.FILLED) filled++;
                        if (r.legs[0].status == LegStatus.SKIP_MIN_LEG) minLeg++;
                    }
                    assertGe(int256(r.got) + 0, 0);
                    _assertClean();
                }
            }
        }
        emit log_named_uint("dust legs filled", filled);
        emit log_named_uint("dust legs skipped as too small", minLeg);
        // The maker's holdings, valued at the anchor price, never fell (the 1e-12 truncation of the valuation is far
        // below one raw USDC; the comparison is on balances too).
        assertGe(_value(makers[0], address(mumb)), m0, "dust cost the maker value");
        assertGe(mumb.balanceOf(makers[0]) / 1e12 + IERC20D(USDC).balanceOf(makers[0]), w0 / 1e12 + u0, "balances fell");
    }
}

interface IERC20D {
    function balanceOf(address) external view returns (uint256);
}
