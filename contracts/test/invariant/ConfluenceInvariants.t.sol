// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {PoolPriceBandExtruction} from "../../src/PoolPriceBandExtruction.sol";
import {ConfluenceBase} from "../base/ConfluenceBase.t.sol";
import {ConfluenceHandler} from "./handlers/ConfluenceHandler.sol";

/// @notice F08: invariants and fuzz tests over the hooked pool and Priya's strategy.
/// @dev Run counts are set here, inline, so a plain `forge test` uses them. Start small, scale up if the file
/// stays fast (PROGRESS records the final numbers). `fail-on-revert` makes any reverting handler call a failure:
/// Aqua must never make a v4 swap fail (CLAUDE.md hard rule).
///
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 25
/// forge-config: default.invariant.fail-on-revert = true
contract ConfluenceInvariantsTest is ConfluenceBase {
    ConfluenceHandler internal handler;
    address internal arb;

    function setUp() public override {
        super.setUp();

        arb = makeAddr("arb");

        ConfluenceHandler.Env memory e;
        e.hook = hook;
        e.manager = manager;
        e.swapRouter = swapRouter;
        e.band = band;
        e.mumb = mumb;
        e.key = key;
        e.aqua = AQUA;
        e.usdc = USDC;
        e.router = ROUTER;
        e.priya = priya;
        e.trader = trader;
        e.arb = arb;
        e.deployer = deployer;
        e.bandBps = BAND_BPS;
        e.tickLower = tickLower;
        e.tickUpper = tickUpper;
        e.usdcIsCurrency0 = usdcIsCurrency0;
        e.order = priyaOrder;
        e.hash = strategyHash;
        e.shippedMumb = SHIPPED_MUMB;
        e.shippedUsdc = SHIPPED_USDC;
        handler = new ConfluenceHandler(e);

        // The handler pranks the actors itself, so it is the only fuzz target.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ConfluenceHandler.traderSwap.selector;
        selectors[1] = ConfluenceHandler.arbSwap.selector;
        selectors[2] = ConfluenceHandler.priyaRedock.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ---------------------------------------------------------------- invariants

    /// @notice The hook holds no token and no ETH after any sequence of swaps (ARCHITECTURE section 4).
    function invariant_F08_hookHoldsNothing() public view {
        _assertHookHoldsNothing();
    }

    /// @notice For each token, Priya's wallet change equals her Aqua virtual balance change, summed over every
    /// strategy she shipped (a dock zeroes the virtual balance without moving tokens, so the handler keeps the
    /// balance at dock time; D-22).
    function invariant_F08_makerValueConserved() public view {
        (int256 walletMumb, int256 virtualMumb, int256 walletUsdc, int256 virtualUsdc) = handler.makerValue();
        assertEq(walletMumb, virtualMumb, "MUMB: Priya's wallet change != virtual balance change");
        assertEq(walletUsdc, virtualUsdc, "USDC: Priya's wallet change != virtual balance change");
    }

    /// @notice Every `AquaFill` the handler saw was priced within the band of the pool price at that moment, with
    /// the extruction's own maths (net-of-fee amount, `mulDiv` floor, same Q96 orientation).
    function invariant_F08_noAquaFillOutsideBand() public view {
        assertEq(handler.bandViolations(), 0, "an AquaFill executed outside the band");
    }

    /// @notice Logging only. Foundry resets state between runs, so these counters are per run and cannot carry a
    /// pass/fail guard (it would fail by chance); non-vacuity is `test_F08_handlerReachesFillAndSkip`.
    function afterInvariant() public {
        emit log_named_uint("F08 hinted trader swaps", handler.hintedSwaps());
        emit log_named_uint("F08 AquaFill", handler.fills());
        emit log_named_uint("F08 skipped: band", handler.bandSkips());
        emit log_named_uint("F08 skipped: other", handler.otherSkips());
        emit log_named_uint("F08 swap calls", handler.swapCalls());
        emit log_named_uint("F08 swap calls with the pool price inside the band", handler.swapCallsInBand());
        if (handler.otherSkips() > 0) emit log_named_bytes("F08 latest other skip reason", handler.lastOtherReason());

        // TEST-ONLY totals over all runs of this process (see `_addToTotal`): the EVM state resets between runs but
        // the process env does not, so the last run's log carries the totals.
        _addToTotal("F08_TOTAL_RUNS", 1);
        _addToTotal("F08_TOTAL_SWAP_CALLS", handler.swapCalls());
        _addToTotal("F08_TOTAL_IN_BAND", handler.swapCallsInBand());
        _addToTotal("F08_TOTAL_FILLS", handler.fills());
        _addToTotal("F08_TOTAL_BAND_SKIPS", handler.bandSkips());
        _addToTotal("F08_TOTAL_OTHER_SKIPS", handler.otherSkips());
        _addToTotal("F08_TOTAL_REDOCKS", handler.redocks());
        _tallyOtherSkips();
        emit log_named_uint("F08 TOTAL redocks", vm.envOr("F08_TOTAL_REDOCKS", uint256(0)));
        emit log_named_uint("F08 TOTAL runs", vm.envOr("F08_TOTAL_RUNS", uint256(0)));
        emit log_named_uint("F08 TOTAL swap calls", vm.envOr("F08_TOTAL_SWAP_CALLS", uint256(0)));
        emit log_named_uint("F08 TOTAL swap calls inside the band", vm.envOr("F08_TOTAL_IN_BAND", uint256(0)));
        emit log_named_uint("F08 TOTAL AquaFill", vm.envOr("F08_TOTAL_FILLS", uint256(0)));
        emit log_named_uint("F08 TOTAL band skips", vm.envOr("F08_TOTAL_BAND_SKIPS", uint256(0)));
        emit log_named_uint("F08 TOTAL other skips", vm.envOr("F08_TOTAL_OTHER_SKIPS", uint256(0)));
    }

    /// @dev Count non-band skips by selector across runs, in process env: key `F08_OTHER_<selector>`, keys listed in
    /// `F08_OTHER_KEYS`. Logging only.
    function _tallyOtherSkips() internal {
        bytes[] memory reasons = handler.otherReasonList();
        for (uint256 i; i < reasons.length; i++) {
            bytes4 sel = reasons[i].length >= 4 ? bytes4(reasons[i]) : bytes4(0);
            string memory k = string.concat("F08_OTHER_", vm.toString(bytes32(sel)));
            if (vm.envOr(k, uint256(0)) == 0) {
                vm.setEnv("F08_OTHER_KEYS", string.concat(vm.envOr("F08_OTHER_KEYS", string("")), k, ";"));
                vm.setEnv(string.concat(k, "_SAMPLE"), vm.toString(reasons[i]));
            }
            _addToTotal(k, 1);
        }
        string[] memory keys = vm.split(vm.envOr("F08_OTHER_KEYS", string("")), ";");
        for (uint256 i; i < keys.length; i++) {
            if (bytes(keys[i]).length == 0) continue;
            emit log_named_uint(string.concat("F08 TOTAL other skip ", keys[i]), vm.envOr(keys[i], uint256(0)));
            emit log_named_string("   first sample", vm.envOr(string.concat(keys[i], "_SAMPLE"), string("")));
        }
    }

    /// @dev TEST-ONLY. Add `n` to a process-level counter through `vm.setEnv`. This relies on the process environment
    /// surviving the state reset between invariant runs, which is how forge behaves today but is not a guarantee, so
    /// the totals are for the log (and the PROGRESS entry) and nothing asserts on them.
    function _addToTotal(string memory name, uint256 n) internal {
        vm.setEnv(name, vm.toString(vm.envOr(name, uint256(0)) + n));
    }

    /// @notice Non-vacuity, deterministic: the handler's own swap path produces a real `AquaFill` and, on the
    /// repeat, a `PoolPriceBandExceeded` skip, and the ghost band check calls the fill inside the band. So the
    /// invariants above are reading real fills and skips, not an idle handler.
    function test_F08_handlerReachesFillAndSkip() public {
        uint256 amountIn = 1_500e6;
        handler.doTraderSwap(true, amountIn, amountIn);
        assertEq(handler.fills(), 1, "first 100% hint: no AquaFill");
        assertEq(handler.bandSkips(), 0, "first fill was band-skipped");

        // Same size, same direction, pool unchanged (the hint was 100%): Priya's curve has moved away from it.
        handler.doTraderSwap(true, amountIn, amountIn);
        assertEq(handler.fills(), 1, "the repeat filled");
        assertEq(handler.bandSkips(), 1, "the repeat was not skipped for PoolPriceBandExceeded");
        assertEq(handler.otherSkips(), 0, "a skip for another reason");
        assertEq(handler.bandViolations(), 0, "a fill outside the band");
        assertEq(handler.hintedSwaps(), 2);
        assertEq(handler.swapCalls(), 2);
        _assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------- fuzz

    /// @notice From one state, a split on a grid of hints (10% to 100% of the input) never gives the trader less
    /// than the pool alone, in either direction. Also asserts that some hint on the grid really filled, so the
    /// comparison is not pool-only against pool-only.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_F08_splitNeverWorseThanPoolOnly(uint256 amountSeed, bool usdcIn) public {
        bool zeroForOne = usdcIn ? usdcForMumb() : mumbForUsdc();
        uint256 unit = usdcIn ? 1e6 : 1e18;
        uint256 amountIn = bound(amountSeed, 10 * unit, 2_000 * unit);

        uint256 snap = vm.snapshotState();
        uint256 poolOnly = _out(_swapExactIn(trader, zeroForOne, amountIn, ""), usdcIn);
        vm.revertToState(snap);

        bool anyFill;
        for (uint256 k = 1; k <= 10; k++) {
            uint256 hint = (amountIn * k) / 10;
            snap = vm.snapshotState();
            (int128 mumbDelta, int128 usdcDelta, Vm.Log[] memory logs) =
                _swapWithLogs(zeroForOne, amountIn, _hint(hint));
            uint256 split = uint256(uint128(usdcIn ? mumbDelta : usdcDelta));
            (bool filled,,) = _findAquaFill(logs);
            anyFill = anyFill || filled;

            assertGe(split, poolOnly, "split gave the trader less than pool-only");
            _assertHookHoldsNothing();
            vm.revertToState(snap);
        }
        assertTrue(anyFill, "no hint on the grid produced an AquaFill");
    }

    /// @notice After 100% Aqua fills of one size, the band refuses the next one (Priya's curve has moved away from
    /// the pool, which a 100% hint leaves untouched). One pool-only arbitrage swap, with the price limit at Priya's
    /// marginal price (the ratio of her virtual balances), brings the pool price back within the band of hers, and
    /// the same 100% fill goes through again.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_F08_fullAquaFillAnchorRecovers(uint256 sizeSeed, bool usdcIn) public {
        bool zeroForOne = usdcIn ? usdcForMumb() : mumbForUsdc();
        uint256 unit = usdcIn ? 1e6 : 1e18;
        uint256 size = bound(sizeSeed, 300 * unit, 1_000 * unit);
        uint160 startPrice = _snap().sqrtPriceX96;

        // Fill 100% from Aqua until the band refuses. A fill of up to about 2,000 units passes the band the first
        // time (ARCHITECTURE section 5), so at least one fill happens.
        uint256 fills;
        bool refused;
        for (uint256 i; i < 40 && !refused; i++) {
            // The refused swap is a probe: the hook falls back to the pool, which fills it all and moves the price,
            // so it is reverted and the pool stays where the Aqua fills left it.
            uint256 snap = vm.snapshotState();
            (,, Vm.Log[] memory logs) = _swapWithLogs(zeroForOne, size, _hint(size));
            (bool filled,,) = _findAquaFill(logs);
            if (filled) {
                fills++;
            } else {
                assertTrue(_bandSkipped(logs), "the fill was skipped, but not for PoolPriceBandExceeded");
                vm.revertToState(snap);
                refused = true;
            }
        }
        assertTrue(refused, "the band never refused a fill");
        assertGe(fills, 1, "no fill before the band refused");
        assertEq(_snap().sqrtPriceX96, startPrice, "a 100% hint moved the pool price");
        _assertHookHoldsNothing();

        // Priya's marginal price. The pool can still be inside the band of it while a fill of this size is refused:
        // the band judges the fill's own price, her marginal price plus that fill's slippage.
        (uint160 target, bool poolInBand) = _priyaPrice();

        // One arbitrage swap, pool-only, down or up to her price (always a real move: after a fill hers has moved).
        assertTrue(target != startPrice, "Priya's price did not move");
        bool arbZeroForOne = target < startPrice;
        address tokenIn = Currency.unwrap(arbZeroForOne ? key.currency0 : key.currency1);
        // `uint256(...)`: an untyped `cond ? 1e6 : 1e18` is a uint64, and 500 * 1e18 overflows it.
        // Far more than the move needs (about 700 units for 1% of price on this seed): the price limit stops the swap
        // at her price and the rest of the input stays with the arbitrageur.
        uint256 arbIn = 5_000 * (tokenIn == USDC ? uint256(1e6) : uint256(1e18));
        _fundArb(tokenIn, arbIn);
        vm.startPrank(arb);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: arbZeroForOne,
                amountSpecified: -int256(arbIn),
                sqrtPriceLimitX96: target
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        (, poolInBand) = _priyaPrice();
        assertTrue(poolInBand, "one arbitrage swap did not bring the pool back within the band of Priya's price");

        // Aqua fills resume: the fill the band refused a moment ago now goes through.
        (,, Vm.Log[] memory resumed) = _swapWithLogs(zeroForOne, size, _hint(size));
        (bool filledAgain,,) = _findAquaFill(resumed);
        assertTrue(
            filledAgain, string.concat("Aqua did not resume after the pool came back; skip reason ", vm.toString(_skipReason(resumed)))
        );
        _assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------- checks on the test machinery

    /// @notice `Controls._salt` changes the strategy hash and nothing about the fill: the same 1,000 USDC swap
    /// with a 100% hint gives the same amounts before and after Priya docks and re-ships a salted copy. The
    /// handler's re-ship relies on this (`ship` refuses a hash it has seen).
    function test_F08_saltChangesHashNotOutput() public {
        uint256 amountIn = 1_000e6;
        uint256 snap = vm.snapshotState();
        (int128 mumb0, int128 usdc0, Vm.Log[] memory logs0) = _swapWithLogs(usdcForMumb(), amountIn, _hint(amountIn));
        (bool filled0, uint256 aquaIn0, uint256 aquaOut0) = _findAquaFill(logs0);
        assertTrue(filled0, "unsalted: no AquaFill");
        vm.revertToState(snap);

        handler.shipSalted(1, SHIPPED_MUMB, SHIPPED_USDC);
        assertTrue(handler.currentHash() != strategyHash, "salt did not change the strategy hash");

        (int128 mumb1, int128 usdc1, Vm.Log[] memory logs1) = _swapWithLogs(usdcForMumb(), amountIn, _hint(amountIn));
        (bool filled1, uint256 aquaIn1, uint256 aquaOut1) = _findAquaFill(logs1);
        assertTrue(filled1, "salted: no AquaFill");

        assertEq(aquaIn1, aquaIn0, "salt changed the Aqua leg's input");
        assertEq(aquaOut1, aquaOut0, "salt changed the Aqua leg's output");
        assertEq(mumb1, mumb0, "salt changed the trader's MUMB");
        assertEq(usdc1, usdc0, "salt changed the trader's USDC");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Priya's marginal price as a pool `sqrtPriceX96`, and whether the pool's price is within the band of it.
    /// Her price is the ratio of her virtual balances, currency1 per currency0: `sqrt(v1 * 2^192 / v0)`.
    function _priyaPrice() internal view returns (uint160 sqrtPriya, bool poolInBand) {
        uint256 vMumb = _aquaBalance(address(mumb));
        uint256 vUsdc = _aquaBalance(USDC);
        (uint256 v0, uint256 v1) = usdcIsCurrency0 ? (vUsdc, vMumb) : (vMumb, vUsdc);
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriya = uint160(Math.sqrt(FullMath.mulDiv(v1, uint256(1) << 192, v0)));

        uint256 poolX96 = FullMath.mulDiv(_snap().sqrtPriceX96, _snap().sqrtPriceX96, FixedPoint96.Q96);
        uint256 priyaX96 = FullMath.mulDiv(v1, FixedPoint96.Q96, v0);
        uint256 diff = priyaX96 > poolX96 ? priyaX96 - poolX96 : poolX96 - priyaX96;
        poolInBand = diff <= FullMath.mulDiv(poolX96, BAND_BPS, 10_000);
    }

    /// @dev The `reason` of the swap's `AquaSkipped`, empty if it had none.
    function _skipReason(Vm.Log[] memory logs) internal view returns (bytes memory reason) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == ConfluenceHook.AquaSkipped.selector) {
                return abi.decode(logs[i].data, (bytes));
            }
        }
    }

    /// @dev Whether the swap's `AquaSkipped` carries `PoolPriceBandExceeded`.
    function _bandSkipped(Vm.Log[] memory logs) internal view returns (bool) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == ConfluenceHook.AquaSkipped.selector) {
                bytes memory reason = abi.decode(logs[i].data, (bytes));
                return reason.length >= 4 && bytes4(reason) == PoolPriceBandExtruction.PoolPriceBandExceeded.selector;
            }
        }
        return false;
    }

    /// @dev Give the arbitrageur `amount` of `token`: MUMB is minted by the deployer, USDC set with `deal`.
    function _fundArb(address token, uint256 amount) internal {
        if (token == address(mumb)) {
            vm.prank(deployer);
            mumb.mint(arb, amount);
        } else {
            deal(token, arb, amount);
        }
    }

    /// @dev The positive output amount of a swap: MUMB when the trader paid USDC, USDC otherwise.
    function _out(BalanceDelta d, bool usdcIn) internal view returns (uint256) {
        return uint256(uint128(usdcIn ? mumbAmount(d) : usdcAmount(d)));
    }
}
