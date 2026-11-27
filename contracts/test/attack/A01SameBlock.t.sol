// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {LegStatus} from "../../src/libraries/PlanCheck.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 scenario 1 and the named risk "same-block manipulation": an attacker moves the pool's price inside the
///         block, then a victim (or the attacker) fills a maker's strategy. v1's guard read the pool's spot price, so
///         the manipulation moved the band with it (`v1/A01V1SameBlock` shows that attack paying). v2's guard reads the
///         block's FIRST snapshot, which no later swap in the block can move.
/// @dev Each test pushes the price with a real swap through the hook (the attacker's own swap also fills the maker, up to
///      the band), then runs the victim's swap from the manipulated state. Asserted for every FILLED leg: its price is
///      within the band of the SNAPSHOT price, not of the manipulated spot; and the victim gets at least what a
///      pool-only swap from the same manipulated state gives. PnL lines are printed per case.
contract A01SameBlockTest is AttackBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant BAND_BPS = 200;
    uint32 internal constant FEE_030 = 3_000_000;

    function _setup() internal {
        _attackInit();
        _initExact(keyV2); // the block's first swap: the snapshot is the fair price
        _joinM(keyV2, makers[0], 100_000e18, 100_000e6, _pf(FEE_030));
        deal(USDC, attacker, 1_000_000e6);
        vm.prank(deployer);
        mumb.mint(attacker, 1_000_000e18);
    }

    /// @dev The output a trade of `amtIn` would give at the snapshot price with no fee and no curve: the reference.
    function _fairOut(uint256 amtIn, bool zfo, int24 snap) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(snap);
        return zfo
            ? FullMath.mulDiv(FullMath.mulDiv(amtIn, s, 2 ** 96), s, 2 ** 96)
            : FullMath.mulDiv(FullMath.mulDiv(amtIn, 2 ** 96, s), 2 ** 96, s);
    }

    /// @dev Every FILLED leg's gross price is at least the band's lower edge after the fee: out >= fair * (1 - band) *
    ///      (1 - fee). It is the guard's rule written on gross numbers, with 1e-6 of slack for rounding.
    function _assertLegsInBand(ConfluenceHook.Leg[] memory legs, bool zfo, int24 snap) internal view {
        for (uint256 i; i < legs.length; i++) {
            if (legs[i].status != LegStatus.FILLED) continue;
            uint256 fair = _fairOut(legs[i].amountIn, zfo, snap);
            uint256 floor_ = fair * (10_000 - BAND_BPS) / 10_000 * (1e9 - FEE_030) / 1e9;
            assertGe(legs[i].amountOut + fair / 1e6, floor_, "a filled leg is outside the band of the SNAPSHOT");
        }
    }

    /// @dev USDC raw value of an input amount (USDC in, or MUMB in at 1e12 raw per USDC raw).
    function _usdc(uint256 amtIn, bool zfo) internal pure returns (uint256) {
        return zfo ? amtIn : amtIn / 1e12;
    }

    struct Out {
        int256 attackerPnl;
        int256 makerPnl;
        int256 victimGainVsPoolOnly; // raw output units of the victim's token
        uint256 filledLegs;
        uint8 status0; // the maker's slot status in the victim's swap
        int24 snap;
        int24 spotAfterPush;
    }

    /// @dev One attack: the attacker pushes (`pushZfo`, `pushIn`), the victim swaps (`vZfo`, `vIn`), the attacker
    ///      reverses its position, all in one block.
    function _attack(bool pushZfo, uint256 pushIn, bool vZfo, uint256 vIn) internal returns (Out memory o) {
        int256 a0 = _value(attacker, address(mumb));
        int256 m0 = _value(makers[0], address(mumb));
        o.snap = _snap();

        uint256 aBefore = IERC20(pushZfo ? address(mumb) : USDC).balanceOf(attacker);
        _swap(keyV2, attacker, pushZfo, -int256(pushIn), "");
        uint256 held = IERC20(pushZfo ? address(mumb) : USDC).balanceOf(attacker) - aBefore;
        (, o.spotAfterPush,,) = manager.getSlot0(idV2);

        Run memory po = _poolOnly(keyV2, vZfo, vIn);
        Run memory r = _run(keyV2, vZfo, vIn, "");
        assertEq(_snap(), o.snap, "the snapshot did not move inside the block");
        _assertLegsInBand(r.legs, vZfo, o.snap);
        assertGe(r.got + 1, po.got, "the victim got less than pool-only from the manipulated state");
        o.victimGainVsPoolOnly = int256(r.got) - int256(po.got);
        if (r.legs.length > 0) o.status0 = r.legs[0].status;
        for (uint256 i; i < r.legs.length; i++) {
            if (r.legs[i].status == LegStatus.FILLED) o.filledLegs++;
        }

        // The attacker unwinds what the push gave it.
        if (held > 0) _swap(keyV2, attacker, !pushZfo, -int256(held), "");
        o.attackerPnl = _value(attacker, address(mumb)) - a0;
        o.makerPnl = _value(makers[0], address(mumb)) - m0;
        _assertClean();
    }

    // ---------------------------------------------------------------- the attack, fixed cases

    function test_V210_sameBlockPush() public {
        _setup();
        uint256 anyFilled;
        uint256[3] memory pushes = [uint256(100e6), 500e6, 2_000e6];
        for (uint256 d; d < 2; d++) {
            for (uint256 i; i < 3; i++) {
                uint256 s = vm.snapshotState();
                bool pushZfo = d == 0; // USDC in: MUMB gets dearer; or MUMB in: MUMB gets cheaper
                uint256 pushIn = pushZfo ? pushes[i] : pushes[i] * 1e12;
                // The victim swaps the direction the push made WORSE for it: the pool is the bad venue, the maker the good one.
                bool vZfo = pushZfo;
                uint256 vIn = vZfo ? 1_000e6 : 1_000e18;
                Out memory o = _attack(pushZfo, pushIn, vZfo, vIn);
                // Either the maker filled the victim, or the push (the attacker's own fill) had already used the whole
                // band measured from the SNAPSHOT: the maker's exposure in a block is the band, not more.
                assertTrue(
                    o.filledLegs > 0 || o.status0 == LegStatus.SKIP_BAND, "the maker neither filled nor was band-spent"
                );
                if (o.filledLegs > 0) anyFilled++;
                // The same sequence with the maker gone: an ordinary sandwich of the pool alone.
                vm.revertToState(s); // back to the start of this case (the snapshot is kept)
                _unregisterAll(keyV2);
                Out memory sandwich = _attack(pushZfo, pushIn, vZfo, vIn);
                emit log_named_string(
                    string.concat(
                        "push ", vm.toString(pushes[i] / 1e6), " USDC-equivalent, ", pushZfo ? "USDC in" : "MUMB in"
                    ),
                    string.concat(
                        "attacker PnL ",
                        vm.toString(o.attackerPnl),
                        " (pool-only sandwich ",
                        vm.toString(sandwich.attackerPnl),
                        "), maker PnL ",
                        vm.toString(o.makerPnl)
                    )
                );
                emit log_named_string("  victim vs pool-only (raw out)", vm.toString(o.victimGainVsPoolOnly));
                // A sandwich of the victim's slippage exists on any AMM, with or without a maker (the pool-only column).
                // It is not a maker loss: the maker's PnL below is positive in every case, and the victim is never worse
                // than pool-only (asserted in `_attack`). The two attacker columns are not comparable at the largest push,
                // where the pool alone runs out of liquidity, so no ordering between them is asserted; THREATS.md records
                // the sandwich as a residual risk of every AMM, not of the maker.
                assertGe(o.makerPnl, 0, "the same-block push cost the maker");
                assertGe(
                    o.makerPnl,
                    -int256((_usdc(vIn, vZfo) + 2 * _usdc(pushIn, pushZfo)) * BAND_BPS / 10_000),
                    "the maker lost more than the band bound"
                );
                require(vm.revertToStateAndDelete(s), "revert failed");
            }
        }
        assertGt(anyFilled, 0, "non-vacuous: the maker filled the victim in some case");
    }

    // ---------------------------------------------------------------- the same attack, fuzzed

    /// @dev 1,000 runs: random push direction and size, random victim direction and size. Every FILLED leg inside the
    ///      band of the snapshot, the snapshot unchanged, the victim never worse than pool-only, the books clean.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_V210_sameBlockPush(uint256 pushSeed, bool pushZfo, uint256 vSeed, bool vZfo) public {
        _setup();
        uint256 pushIn = pushZfo ? bound(pushSeed, 1e6, 2_400e6) : bound(pushSeed, 1e18, 2_400e18);
        uint256 vIn = vZfo ? bound(vSeed, 1e6, 3_000e6) : bound(vSeed, 1e18, 3_000e18);
        _attack(pushZfo, pushIn, vZfo, vIn);
    }

    // ---------------------------------------------------------------- the push that moves spot past the band

    /// @dev A maker priced 300 ticks (3%) off the snapshot, outside the band of the snapshot. The attacker pushes spot onto
    ///      the maker's price inside the block (a limited swap), so a band centred on spot would accept the maker. The victim's
    ///      swap must still find the maker `SKIP_BAND` and the maker's wallet and Aqua balances must not move: the hook caps
    ///      each leg by the band of the SNAPSHOT before the router is called. MUT1 (the guard reading spot) survives this test,
    ///      because the hook's cap is the first line; the guard is the line that holds against a DIRECT router fill by a
    ///      non-exclusive strategy's taker, and `V204BandGuardFork.test_V204_sameBlockAttackRefused` is the test that kills MUT1.
    function test_V210_pushOntoAMispricedMakerCannotOpenTheBand() public {
        _attackInit();
        _initExact(keyV2);
        (int24 snap,,) = hookV2.anchorOf(idV2);
        uint256 usdcAmt = 100_000e6;
        M memory m = _joinM(keyV2, makers[0], _mumbAt(usdcAmt, snap + 300), usdcAmt, _pf(FEE_030));
        int256 m0 = _value(makers[0], address(mumb));
        (uint256 w0m, uint256 w0u) = (mumb.balanceOf(makers[0]), IERC20(USDC).balanceOf(makers[0]));
        // MUMB in raises the tick: push spot onto the maker's price.
        _swapLim(keyV2, false, 400_000e18, TickMath.getSqrtPriceAtTick(snap + 300));
        (, int24 spot,,) = manager.getSlot0(idV2);
        assertGe(spot, snap + 295, "the push put spot on the maker's price");
        assertEq(_snap(), snap, "the snapshot did not move");
        Run memory po = _poolOnly(keyV2, true, 1_000e6);
        Run memory r = _run(keyV2, true, 1_000e6, "");
        assertEq(r.legs.length, 1, "the maker is planned");
        assertEq(r.legs[0].status, LegStatus.SKIP_BAND, "outside the band of the SNAPSHOT: refused");
        assertEq(r.got, po.got, "exactly pool-only");
        assertEq(mumb.balanceOf(makers[0]), w0m, "maker wallet MUMB unmoved");
        assertEq(IERC20(USDC).balanceOf(makers[0]), w0u, "maker wallet USDC unmoved");
        assertEq(_value(makers[0], address(mumb)), m0, "maker PnL 0");
        m; // the shipped hash is not needed
        _assertClean();
    }
}
