// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

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

    /// @notice Non-vacuity guard (the invariants above would pass with a handler that does nothing): the run must
    /// have produced at least one Aqua fill and at least one band skip.
    function afterInvariant() public {
        emit log_named_uint("F08 hinted trader swaps", handler.hintedSwaps());
        emit log_named_uint("F08 AquaFill", handler.fills());
        emit log_named_uint("F08 skipped: band", handler.bandSkips());
        emit log_named_uint("F08 skipped: other", handler.otherSkips());
        emit log_named_uint("F08 swap calls", handler.swapCalls());
        emit log_named_uint("F08 swap calls with the pool price inside the band", handler.swapCallsInBand());
        assertGt(handler.fills(), 0, "vacuous run: no AquaFill");
        assertGt(handler.bandSkips(), 0, "vacuous run: no band skip");
    }

    // ---------------------------------------------------------------- fuzz

    /// @notice From one state, a split on a grid of hints (10% to 100% of the input) never gives the trader less
    /// than the pool alone, in either direction. Also asserts that some hint on the grid really filled, so the
    /// comparison is not pool-only against pool-only.
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

    /// @notice After many 100% Aqua fills, one arbitrage swap brings the pool price back within the band of
    /// Priya's price, and Aqua fills resume. Written in step 4; red until then.
    function testFuzz_F08_fullAquaFillAnchorRecovers(uint256, bool) public pure {
        revert("F08 step 4: not written yet");
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

    /// @dev The positive output amount of a swap: MUMB when the trader paid USDC, USDC otherwise.
    function _out(BalanceDelta d, bool usdcIn) internal view returns (uint256) {
        return uint256(uint128(usdcIn ? mumbAmount(d) : usdcAmount(d)));
    }
}
