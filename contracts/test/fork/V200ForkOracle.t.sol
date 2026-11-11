// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ForkOracle} from "../base/ForkOracle.sol";
import {Vectors} from "../base/Vectors.sol";

/// @notice V2-00: the fork oracle reproduces v1's numbers (D-21) and agrees with the Python model's pool state.
/// @dev Every number is also checked against `test/vectors/v1_demo.json`, which the Python model generated, so the
///      model and the chain cannot drift apart without a red test.
contract V200ForkOracleTest is ForkOracle {
    using StateLibrary for IPoolManager;

    // D-21 (pinned facts, also in the vectors).
    uint256 internal constant POOL_ONLY_WEI = 984934194542570551127;
    uint256 internal constant HINTED_BEST_WEI = 991549823315669231761;
    uint256 internal constant V1_HINT = 550_000_000;
    uint256 internal constant AMOUNT_USDC = 1_000e6;

    function test_V200_forkOracleReproducesV1() public {
        // The model's currency order: USDC is currency0 (reference/gen_vectors.py, V1_USDC_IS_CURRENCY0).
        assertTrue(usdcIsCurrency0, "the model assumes USDC is currency0");

        uint256[] memory hints = new uint256[](2);
        hints[0] = 0;
        hints[1] = V1_HINT;

        uint256[] memory outs = _realiseExactIn(usdcForMumb(), AMOUNT_USDC, hints);

        assertEq(outs.length, 2, "one output per candidate");
        assertEq(outs[0], POOL_ONLY_WEI, "pool-only (hint 0)");
        assertEq(outs[1], HINTED_BEST_WEI, "hint 550000000");

        // Same numbers, from the Python model's vectors.
        Vectors.V1Case memory c = Vectors.v1Case(Vectors.read(Vectors.V1_DEMO), 0);
        assertEq(c.amount, AMOUNT_USDC, "vector amount");
        assertEq(outs[0], c.poolOnlyOut, "pool-only vs vector");
        assertEq(c.hint, V1_HINT, "vector hint");
        assertEq(outs[1], c.hintTotal, "hinted best vs vector");
        assertGt(c.totalInt, outs[1], "the closed form beats v1's hinted best (M3 target)");
    }

    /// @dev The oracle runs each candidate from the same state: calling it again, or in another order, gives the
    ///      same outputs, and the pool is where it started.
    function test_V200_forkOracleLeavesStateUntouched() public {
        (uint160 sqrtBefore, int24 tickBefore,,) = manager.getSlot0(poolId);
        uint128 liqBefore = manager.getLiquidity(poolId);
        (uint256 traderMumb, uint256 traderUsdc) = balances(trader);

        uint256[] memory hints = new uint256[](3);
        hints[0] = V1_HINT;
        hints[1] = 0;
        hints[2] = V1_HINT;
        uint256[] memory outs = _realiseExactIn(usdcForMumb(), AMOUNT_USDC, hints);
        assertEq(outs[0], HINTED_BEST_WEI, "first");
        assertEq(outs[1], POOL_ONLY_WEI, "second");
        assertEq(outs[2], HINTED_BEST_WEI, "third: a swap must not leak into the next candidate");

        (uint160 sqrtAfter, int24 tickAfter,,) = manager.getSlot0(poolId);
        assertEq(sqrtAfter, sqrtBefore, "sqrtPrice");
        assertEq(tickAfter, tickBefore, "tick");
        assertEq(manager.getLiquidity(poolId), liqBefore, "liquidity");
        (uint256 traderMumbAfter, uint256 traderUsdcAfter) = balances(trader);
        assertEq(traderMumbAfter, traderMumb, "trader MUMB");
        assertEq(traderUsdcAfter, traderUsdc, "trader USDC");
    }

    function test_V200_forkOracleRefusesTooManyCandidates() public {
        uint256[] memory hints = new uint256[](MAX_CANDIDATES + 1);
        vm.expectRevert(abi.encodeWithSelector(TooManyCandidates.selector, MAX_CANDIDATES + 1));
        this.externalRealise(usdcForMumb(), AMOUNT_USDC, hints);
    }

    function externalRealise(bool zeroForOne, uint256 amountIn, uint256[] memory hints) external {
        _realiseExactIn(zeroForOne, amountIn, hints);
    }

    /// @dev The fork pool is the pool the Python model builds, field by field.
    function test_V200_forkPoolMatchesModel() public view {
        Vectors.V1Case memory c = Vectors.v1Case(Vectors.read(Vectors.V1_DEMO), 0);

        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(sqrtPriceX96, c.pool.sqrtPriceX96, "sqrtPriceX96");
        assertEq(tick, c.pool.tick, "tick");
        assertEq(lpFee, c.pool.feePips, "lpFee");
        assertEq(key.fee, c.pool.feePips, "key fee");
        assertEq(key.tickSpacing, c.pool.tickSpacing, "tick spacing");
        assertEq(uint256(manager.getLiquidity(poolId)), uint256(c.pool.liquidity), "liquidity");

        assertEq(c.pool.ticks.length, 2, "model ticks");
        assertEq(c.pool.ticks[0], tickLower, "lower tick");
        assertEq(c.pool.ticks[1], tickUpper, "upper tick");
        (, int128 netLower) = manager.getTickLiquidity(poolId, tickLower);
        (, int128 netUpper) = manager.getTickLiquidity(poolId, tickUpper);
        assertEq(netLower, c.pool.liquidityNets[0], "liquidityNet at the lower tick");
        assertEq(netUpper, c.pool.liquidityNets[1], "liquidityNet at the upper tick");

        // Priya's shipped balances are the model's venue.
        assertEq(c.priya.x, SHIPPED_USDC, "Priya x (USDC in)");
        assertEq(c.priya.y, SHIPPED_MUMB, "Priya y (MUMB out)");
        assertEq(uint256(c.priya.feeE9), FEE_0_30_PCT, "Priya fee");
    }

    /// @dev The other vector cases: 2,000 USDC (D-23's 1946.313880914421030318 pool-only) and MUMB to USDC.
    function test_V200_forkOracleMatchesOtherVectorCases() public {
        string memory json = Vectors.read(Vectors.V1_DEMO);
        uint256[] memory zero = new uint256[](1);

        Vectors.V1Case memory c2 = Vectors.v1Case(json, 1);
        assertEq(c2.amount, 2_000e6, "case 1 amount");
        assertEq(_realiseExactIn(usdcForMumb(), c2.amount, zero)[0], c2.poolOnlyOut, "2,000 USDC pool-only");
        assertEq(c2.poolOnlyOut, 1946313880914421030318, "D-23 2,000 USDC pool-only");

        Vectors.V1Case memory c3 = Vectors.v1Case(json, 2);
        assertEq(c3.amount, 1_000e18, "case 2 amount");
        assertEq(_realiseExactIn(mumbForUsdc(), c3.amount, zero)[0], c3.poolOnlyOut, "1,000 MUMB pool-only");
    }

    /// @dev 777 MUMB to USDC moves the price across the tick bitmap's word edge at tick 276420, so v4 takes two
    ///      swap steps and rounds twice. A model that jumped straight to the next initialised tick is 1 wei off
    ///      (reference/test_reference.py shows the two walks differ); the chain decides which is right.
    function test_V200_forkOracleMatchesAcrossAWordEdge() public {
        Vectors.V1Case memory c = Vectors.v1Case(Vectors.read(Vectors.V1_DEMO), 3);
        assertEq(c.amount, 777e18, "case 3 amount");
        uint256[] memory zero = new uint256[](1);
        assertEq(_realiseExactIn(mumbForUsdc(), c.amount, zero)[0], c.poolOnlyOut, "777 MUMB pool-only");
    }
}
