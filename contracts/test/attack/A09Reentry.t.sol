// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {LegStatus} from "../../src/ConfluenceSplitter.sol";
import {AttackBase, HostileToken} from "./AttackBase.t.sol";

/// @notice The attacker's contract inside a hostile token's callback: runs a nested swap on the PoolManager (which is
///         unlocked for the whole `unlock` callback, `PoolManager.sol:103-111`), or forwards a call to any target as
///         itself (so it can be a registered maker calling `unregister`). Records what it saw.
contract Reenterer {
    using SafeERC20 for IERC20;

    uint256 public hookBefore;
    uint256 public hookAfter;
    bool public ran;
    bool public execOk;
    bytes public execRet;

    /// @notice A nested exact-input swap, settled from this contract's own balances. Anyone may call (test only).
    function nested(IPoolManager m, PoolKey calldata k, bool zfo, int256 spec, address hook, address tokenB) external {
        hookBefore = IERC20(tokenB).balanceOf(hook);
        BalanceDelta d = m.swap(
            k,
            IPoolManager.SwapParams({
                zeroForOne: zfo,
                amountSpecified: spec,
                sqrtPriceLimitX96: zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        _settle(m, k.currency0, d.amount0());
        _settle(m, k.currency1, d.amount1());
        hookAfter = IERC20(tokenB).balanceOf(hook);
        ran = true;
    }

    /// @notice Forwards `data` to `t` as this contract and records the result. Anyone may call (test only).
    function exec(address t, bytes calldata data) external {
        (execOk, execRet) = t.call(data);
    }

    function _settle(IPoolManager m, Currency c, int128 amt) private {
        if (amt < 0) {
            m.sync(c);
            // casting to 'uint128' is safe: amt is negative
            // forge-lint: disable-next-line(unsafe-typecast)
            IERC20(Currency.unwrap(c)).safeTransfer(address(m), uint128(-amt));
            m.settle();
        } else if (amt > 0) {
            // casting to 'uint128' is safe: amt is positive
            // forge-lint: disable-next-line(unsafe-typecast)
            m.take(c, address(this), uint128(amt));
        }
    }
}

/// @notice V2-10 scenario 9 and the hostile-token table (plan, checkpoint A). Each test asserts the DESIRED property
///         ("Aqua can never make a v4 swap fail", hook holds nothing, allowances 0, books exact). A test that is red
///         is a finding, reported with its row; no assertion is loosened. Each swap-level test also logs a ROW:
///         outcome, whether pool-only passes, the thief's gain, the hook's balances and the allowances.
contract A09ReentryTest is AttackBase {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant IN_USDC = 1_000e6;
    uint256 internal constant IN_HOST = 1_000e18;
    Reenterer internal re;
    PoolKey internal k;
    ConfluenceHook.Leg[][] internal evs;

    // ------------------------------------------------------------------------------------------ helpers

    function _setup2() internal {
        k = _hostilePool();
        _joinHost(k, makers[0], 100_000e18, 100_000e6, _pf(3_000_000));
        _joinHost(k, makers[1], 100_000e18, 100_000e6, _pf(3_000_000));
    }

    /// @dev External so a revert can be caught; `who` pays.
    function exSwap(PoolKey memory kk, address who, bool zfo, int256 spec) external {
        _hSwap(kk, who, zfo, spec);
    }

    function _try(PoolKey memory kk, bool zfo, int256 spec) internal returns (bool ok) {
        vm.recordLogs();
        (ok,) = address(this).call(abi.encodeCall(this.exSwap, (kk, trader, zfo, spec)));
        _collect(vm.getRecordedLogs());
    }

    function _collect(Vm.Log[] memory logs) internal {
        delete evs;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(hookV2) || logs[i].topics[0] != ConfluenceHook.ConfluenceSwap.selector) {
                continue;
            }
            (,,,,,,,, ConfluenceHook.Leg[] memory legs) = abi.decode(
                logs[i].data, (bool, bool, int256, int24, int24, uint160, uint128, uint24, ConfluenceHook.Leg[])
            );
            evs.push();
            for (uint256 j; j < legs.length; j++) {
                evs[evs.length - 1].push(legs[j]);
            }
        }
    }

    function _poolOnlyPasses(PoolKey memory kk, bool zfo, int256 spec) internal returns (bool ok) {
        uint256 s = vm.snapshotState();
        _unregisterAll(kk);
        (ok,) = address(this).call(abi.encodeCall(this.exSwap, (kk, trader, zfo, spec)));
        require(vm.revertToStateAndDelete(s), "revert failed");
    }

    function _row(string memory label, bool ok, bool poolOk, int256 thief) internal {
        emit log_string(string.concat(
                "ROW ",
                label,
                " | swap=",
                ok ? "ok" : "REVERT",
                " | poolOnly=",
                poolOk ? "ok" : "REVERT",
                " | thiefGain=",
                vm.toString(thief),
                " | hookUSDC=",
                vm.toString(IERC20(USDC).balanceOf(address(hookV2))),
                " hookTok=",
                vm.toString(host.balanceOf(address(hookV2))),
                " | allowance hook->router USDC=",
                vm.toString(IERC20(USDC).allowance(address(hookV2), ROUTER)),
                " tok=",
                vm.toString(host.allowance(address(hookV2), ROUTER))
            ));
    }

    function _thief() internal view returns (int256) {
        return
            _value(address(re), address(host)) + _value(address(host), address(host)) + _value(attacker, address(host));
    }

    function _fundRe(uint256 usdcAmt, uint256 tokAmt) internal {
        deal(USDC, address(re), usdcAmt);
        host.mint(address(re), tokAmt);
        vm.startPrank(address(re));
        IERC20(USDC).approve(AQUA, type(uint256).max);
        host.approve(AQUA, type(uint256).max);
        vm.stopPrank();
    }

    function _armNested(PoolKey memory kk, bool zfo, int256 spec, uint256 at) internal {
        host.arm(
            address(re),
            abi.encodeCall(Reenterer.nested, (manager, kk, zfo, spec, address(hookV2), address(host))),
            2,
            at
        );
    }

    /// @dev Sum of legs' amounts over every recorded event, and over all makers' wallets (host decrease, USDC increase).
    function _sumEvents() internal view returns (uint256 inn, uint256 out) {
        for (uint256 i; i < evs.length; i++) {
            for (uint256 j; j < evs[i].length; j++) {
                inn += evs[i][j].amountIn;
                out += evs[i][j].amountOut;
            }
        }
    }

    function _statusLine(string memory label) internal {
        string memory o = label;
        for (uint256 i; i < evs.length; i++) {
            o = string.concat(o, i == 0 ? " | first event:" : " | next event:");
            for (uint256 j; j < evs[i].length; j++) {
                o = string.concat(o, " ", vm.toString(uint256(evs[i][j].status)));
            }
        }
        emit log_string(o);
    }

    function _nFilled(ConfluenceHook.Leg[] storage legs) internal view returns (uint256 n) {
        for (uint256 i; i < legs.length; i++) {
            if (legs[i].status == LegStatus.FILLED) n++;
        }
    }

    // ------------------------------------------------------------------------------------------ fixture

    function test_V210_hostileFixtureBenign() public {
        _setup2();
        bool zfo = _usdcIn(k);
        bool ok = _try(k, zfo, -int256(IN_USDC));
        assertTrue(ok, "benign hostile-token pool swaps");
        assertEq(evs.length, 1, "one event");
        assertEq(uint256(evs[0][0].status), LegStatus.FILLED, "leg 0 filled");
        assertEq(uint256(evs[0][1].status), LegStatus.FILLED, "leg 1 filled");
        _assertAfterAttack(address(host));
    }

    // ------------------------------------------------------------------------------------------ re-entry

    /// @dev A call-out inside the outer leg's router call (the Aqua pull of the output) gets at most `LEG_GAS_CAP`
    ///      (640,000 gas, `ConfluenceHook.sol:494`): a nested hooked swap there cannot run its plan and legs. It is
    ///      contained by gas: it degrades to pool-only, the outer leg fills, nothing is left over.
    function test_V210_reentryNestedSwapInsideLegIsGasStarved() public {
        _setup2();
        re = new Reenterer();
        _fundRe(50_000e6, 50_000e18);
        bool zfo = _usdcIn(k);
        _armNested(k, zfo, -int256(100e6), 1);
        int256 t0 = _thief();
        bool ok = _try(k, zfo, -int256(IN_USDC));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("nested swap inside the router call (gas-capped)", ok, poolOk, _thief() - t0);
        _statusLine("STATUS");
        assertTrue(ok, "the outer swap passes");
        assertTrue(host.fired() && host.lastOk(), "the nested swap ran inside the outer leg and passed");
        assertEq(evs.length, 2, "nested event, then outer event");
        assertEq(_nFilled(evs[0]), 0, "the nested swap got no legs: gas-starved");
        assertEq(_nFilled(evs[1]), 2, "both outer legs filled");
        assertEq(re.hookBefore(), re.hookAfter(), "hook balance unchanged by the nested swap");
        _assertAfterAttack(address(host));
    }

    /// @dev Nested hooked swap with FULL gas on the SAME pool: the host token calls out from `approve`, which the hook
    ///      runs in its own frame (`ConfluenceHook.sol:491`), right after the outer leg's allowance is set. Host is the
    ///      input token. The nested swap's `forceApprove(ROUTER, x2)` and reset to 0 must not zero or overwrite the outer
    ///      approval: the outer leg must still fill. Books exact, hook balance unchanged by the nested swap.
    function test_V210_reentryNestedSwapSamePoolInputToken() public {
        _setup2();
        re = new Reenterer();
        _fundRe(50_000e6, 50_000e18);
        bool zfo = !_usdcIn(k);
        host.arm(
            address(re),
            abi.encodeCall(Reenterer.nested, (manager, k, zfo, -int256(100e18), address(hookV2), address(host))),
            8,
            1
        );
        int256 t0 = _thief();
        bool ok = _try(k, zfo, -int256(IN_HOST));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("nested swap, same pool, host=input, full gas", ok, poolOk, _thief() - t0);
        _statusLine("STATUS");
        assertTrue(ok, "the outer swap passes");
        assertTrue(host.fired() && host.lastOk(), "the nested swap ran and passed");
        assertEq(evs.length, 2, "nested event, then outer event");
        assertGt(_nFilled(evs[0]), 0, "non-vacuous: the nested swap filled a leg");
        assertEq(re.hookBefore(), re.hookAfter(), "hook token balance unchanged by the nested swap (:465)");
        _assertAfterAttack(address(host));
        (uint256 inn, uint256 out) = _sumEvents();
        uint256 mIn = host.balanceOf(makers[0]) + host.balanceOf(makers[1]) - 200_000e18;
        uint256 mOut = 200_000e6 - IERC20(USDC).balanceOf(makers[0]) - IERC20(USDC).balanceOf(makers[1]);
        assertEq(mIn, inn, "makers received exactly the events' inputs");
        assertEq(mOut, out, "makers gave exactly the events' outputs");
        assertEq(
            uint256(evs[1][0].status), LegStatus.FILLED, "outer approval not zeroed or overwritten by the inner reset"
        );
    }

    /// @dev The same with the nested swap on a second hooked pool (other fee and spacing) that has its own maker on the
    ///      same token: legs on the same token while the outer leg's allowance is live.
    function test_V210_reentryNestedSwapSecondPool() public {
        _setup2();
        PoolKey memory k2 = _hostilePoolOn(3000, 30);
        _joinHost(k2, makers[2], 100_000e18, 100_000e6, _pf(3_000_000));
        re = new Reenterer();
        _fundRe(50_000e6, 50_000e18);
        bool zfo = !_usdcIn(k);
        host.arm(
            address(re),
            abi.encodeCall(Reenterer.nested, (manager, k2, zfo, -int256(100e18), address(hookV2), address(host))),
            8,
            1
        );
        int256 t0 = _thief();
        bool ok = _try(k, zfo, -int256(IN_HOST));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("nested swap, second pool, host=input, full gas", ok, poolOk, _thief() - t0);
        _statusLine("STATUS");
        assertTrue(ok, "the outer swap passes");
        assertTrue(host.fired() && host.lastOk(), "the nested swap on the second pool ran and passed");
        assertEq(evs.length, 2, "nested event, then outer event");
        assertGt(_nFilled(evs[0]), 0, "non-vacuous: the nested swap filled a leg");
        assertEq(re.hookBefore(), re.hookAfter(), "hook token balance unchanged by the nested swap (:465)");
        _assertAfterAttack(address(host));
        assertEq(uint256(evs[1][0].status), LegStatus.FILLED, "outer approval not zeroed by the inner reset");
        assertEq(uint256(evs[1][1].status), LegStatus.FILLED, "outer leg 1 filled");
    }

    /// @dev Host is the output token; inside the Aqua pull the attacker donates host tokens to the hook, so the
    ///      balance difference at `:465` includes them. The hook settles them to the PoolManager and returns them in its
    ///      delta, so the trader receives them: only the donor pays. Value-conserving, no one else loses.
    function test_V210_donationInsideTheWindowOnlyCostsTheDonor() public {
        _setup2();
        re = new Reenterer();
        _fundRe(50_000e6, 50_000e18);
        bool zfo = _usdcIn(k);
        uint256 donation = 7e18;
        host.arm(
            address(re),
            abi.encodeCall(
                Reenterer.exec, (address(host), abi.encodeCall(HostileToken.transfer, (address(hookV2), donation)))
            ),
            2,
            1
        );
        int256 t0 = _thief();
        bool ok = _try(k, zfo, -int256(IN_USDC));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("donation to the hook inside the window", ok, poolOk, _thief() - t0);
        assertTrue(ok, "the swap passes");
        assertTrue(re.execOk(), "the donation was made");
        assertEq(_thief() - t0, -int256(donation / 1e12), "the donor lost exactly the donation (valued in USDC raw)");
        _assertAfterAttack(address(host));
    }

    /// @dev H1: slot 0's maker is a contract; during its own leg it calls `unregister`, which pops a slot, so the
    ///      loop's `slots[1]` is out of bounds.
    function test_V210_reentryUnregisterMidLoop() public {
        k = _hostilePool();
        re = new Reenterer();
        _joinHost(k, address(re), 100_000e18, 100_000e6, _pf(3_000_000));
        _joinHost(k, makers[1], 100_000e18, 100_000e6, _pf(3_000_000));
        bool zfo = _usdcIn(k);
        host.arm(
            address(re),
            abi.encodeCall(Reenterer.exec, (address(hookV2), abi.encodeCall(ConfluenceHook.unregister, (k)))),
            2,
            1
        );
        bool ok = _try(k, zfo, -int256(IN_USDC));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("unregister mid-loop (H1)", ok, poolOk, 0);
        assertTrue(ok, "the outer swap passes");
        _assertAfterAttack(address(host));
    }

    /// @dev The token calls `PoolManager.take` for the PoolManager's USDC: the debt is the caller's, and `unlock`
    ///      reverts `CurrencyNotSettled` (`PoolManager.sol:111`); nothing moves.
    function test_V210_reentryPoolManagerTakeIsUnsettledAndReverts() public {
        _setup2();
        re = new Reenterer();
        bool zfo = _usdcIn(k);
        host.arm(
            address(re),
            abi.encodeCall(
                Reenterer.exec, (address(manager), abi.encodeCall(IPoolManager.take, (k.currency0, address(re), 1e6)))
            ),
            2,
            1
        );
        uint256 usdcPm = IERC20(USDC).balanceOf(address(manager));
        int256 t0 = _thief();
        bool ok = _try(k, zfo, -int256(IN_USDC));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("pm.take by the token's contract", ok, poolOk, _thief() - t0);
        assertFalse(ok, "an unsettled debt reverts the whole swap");
        assertEq(IERC20(USDC).balanceOf(address(manager)), usdcPm, "no funds moved");
        _assertAfterAttack(address(host));
    }

    // ------------------------------------------------------------------------------------------ token behaviours

    function test_V210_feeOnTransferOutput() public {
        _setup2();
        bool zfo = _usdcIn(k);
        host.setFeeBps(100);
        bool ok = _try(k, zfo, -int256(IN_USDC));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("fee-on-transfer, host=output", ok, poolOk, 0);
        assertTrue(ok, "a leg's token fee must not fail the swap");
        _assertAfterAttack(address(host));
    }

    function test_V210_feeOnTransferInput() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setFeeBps(100);
        bool ok = _try(k, zfo, -int256(IN_HOST));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("fee-on-transfer, host=input", ok, poolOk, 0);
        assertTrue(ok, "a leg's token fee must not fail the swap");
        _assertAfterAttack(address(host));
    }

    /// @dev Host is the input token: the approval reset to 0 (`ConfluenceHook.sol:502`) reverts.
    function test_V210_revertsOnApproveZero() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setRevertApproveZero(true);
        bool ok = _try(k, zfo, -int256(IN_HOST));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("approve(0) reverts, host=input (H3)", ok, poolOk, 0);
        assertTrue(ok, "the approval reset must not fail the swap");
        _assertAfterAttack(address(host));
    }

    /// @dev USDT-shaped token returns nothing; the hook settles through `CurrencySettler`'s `IERC20Minimal.transfer`.
    function test_V210_noReturnTokenOutput() public {
        _setup2();
        bool zfo = _usdcIn(k);
        host.setNoReturn(true);
        bool ok = _try(k, zfo, -int256(IN_USDC));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("no-return token, host=output (H4)", ok, poolOk, 0);
        assertTrue(ok, "a no-return token must not fail the swap");
        _assertAfterAttack(address(host));
    }

    function test_V210_noReturnTokenInput() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setNoReturn(true);
        bool ok = _try(k, zfo, -int256(IN_HOST));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("no-return token, host=input (H4)", ok, poolOk, 0);
        assertTrue(ok, "a no-return token must not fail the swap");
        _assertAfterAttack(address(host));
    }

    /// @dev Latent H4 on the input side: a no-return input token only reverts when a leg fails and its input is settled
    ///      back through `CurrencySettler`. A blocklisted maker makes the leg fail.
    function test_V210_noReturnTokenInputFailedLeg() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setNoReturn(true);
        host.setBlocked(makers[0], true);
        bool ok = _try(k, zfo, -int256(IN_HOST));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("no-return token, host=input, one leg fails (H4)", ok, poolOk, 0);
        assertTrue(ok, "a failed leg's settle-back must not fail the swap");
        _assertAfterAttack(address(host));
    }

    /// @dev A maker's wallet is blocklisted: its pull fails inside the router (try/catch); the pool fills the share.
    function test_V210_blocklistedMakerIsContained() public {
        _setup2();
        bool zfo = _usdcIn(k);
        host.setBlocked(makers[0], true);
        bool ok = _try(k, zfo, -int256(IN_USDC));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("blocklisted maker, host=output", ok, poolOk, 0);
        assertTrue(ok, "a blocked maker must not fail the swap");
        assertEq(uint256(evs[0][0].status), LegStatus.SKIP_REVERT, "the blocked maker's leg is skipped");
        _assertAfterAttack(address(host));
    }

    /// @dev The issuer blocklists the hook; host is the input token, so `take` to the hook reverts (H5).
    function test_V210_blocklistedHookInput() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setBlocked(address(hookV2), true);
        bool ok = _try(k, zfo, -int256(IN_HOST));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("hook blocklisted, host=input (H5)", ok, poolOk, 0);
        assertTrue(ok, "a blocklisted hook must not fail the swap");
        _assertAfterAttack(address(host));
    }

    function test_V210_blocklistedHookOutput() public {
        _setup2();
        bool zfo = _usdcIn(k);
        host.setBlocked(address(hookV2), true);
        bool ok = _try(k, zfo, -int256(IN_USDC));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("hook blocklisted, host=output (H5)", ok, poolOk, 0);
        assertTrue(ok, "a blocklisted hook must not fail the swap");
        _assertAfterAttack(address(host));
    }
}
