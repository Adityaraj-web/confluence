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

    /// @dev The output token amount the trader received in the last swap attempt of `_try`'s kind, from balances.
    function _tryGot(PoolKey memory kk, bool zfo, int256 spec, address tokOut) internal returns (bool ok, uint256 got) {
        uint256 b = IERC20(tokOut).balanceOf(trader);
        ok = _try(kk, zfo, spec);
        got = IERC20(tokOut).balanceOf(trader) - b;
    }

    function _poolOnlyGot(PoolKey memory kk, bool zfo, int256 spec, address tokOut) internal returns (uint256 got) {
        uint256 s0 = vm.snapshotState();
        _unregisterAll(kk);
        uint256 b = IERC20(tokOut).balanceOf(trader);
        (bool ok,) = address(this).call(abi.encodeCall(this.exSwap, (kk, trader, zfo, spec)));
        require(ok, "pool-only swap failed");
        got = IERC20(tokOut).balanceOf(trader) - b;
        require(vm.revertToStateAndDelete(s0), "revert failed");
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

    /// @dev True when `ret` (the PoolManager's wrapped hook error, `HookCallFailed`/`WrappedError`) carries `sel`.
    function _wraps(bytes memory ret, bytes4 sel) internal pure returns (bool) {
        if (ret.length < 36) return false;
        for (uint256 i; i + 4 <= ret.length; i++) {
            bytes4 w;
            assembly {
                w := mload(add(add(ret, 0x20), i))
            }
            if (w == sel) return true;
        }
        return false;
    }

    function _countSkipRevert() internal view returns (uint256 n) {
        for (uint256 i; i < evs[0].length; i++) {
            if (evs[0][i].status == LegStatus.SKIP_REVERT) n++;
        }
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

    /// @dev A call-out inside the outer leg's router call (the Aqua pull of the output) is also rejected by the lock
    ///      (D-38); before the lock it was only contained by `LEG_GAS_CAP` (a nested swap there got no legs). The
    ///      nested `beforeSwap` reverts `Reentered`, the outer swap is unaffected.
    function test_V210_reentryNestedSwapInsideLegIsRejected() public {
        _setup2();
        re = new Reenterer();
        _fundRe(50_000e6, 50_000e18);
        bool zfo = _usdcIn(k);
        _armNested(k, zfo, -int256(100e6), 1);
        int256 t0 = _thief();
        bool ok = _try(k, zfo, -int256(IN_USDC));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("nested swap inside the router call (lock)", ok, poolOk, _thief() - t0);
        assertTrue(ok, "the outer swap passes");
        assertTrue(host.fired() && !host.lastOk(), "the nested swap was attempted and rejected");
        assertTrue(_wraps(host.lastRet(), ConfluenceHook.Reentered.selector), "rejected by the lock");
        assertEq(evs.length, 1, "only the outer event");
        assertEq(_nFilled(evs[0]), 2, "both outer legs filled");
        _assertAfterAttack(address(host));
    }

    /// @dev Full-gas call-out from `approve` (`ConfluenceHook.sol:491`, host = input token) right after the outer
    ///      allowance is set: the nested swap is rejected by the lock, so it cannot zero or overwrite the outer approval.
    ///      The outer swap is correct: both legs filled, books exact, hook empty, allowances 0.
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
        uint256 usdc0 = IERC20(USDC).balanceOf(makers[0]) + IERC20(USDC).balanceOf(makers[1]);
        (bool ok, uint256 got) = _tryGot(k, zfo, -int256(IN_HOST), USDC);
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("nested swap, same pool, host=input, full gas (lock)", ok, poolOk, _thief() - t0);
        assertTrue(ok, "the outer swap passes");
        assertTrue(host.fired() && !host.lastOk(), "the nested swap was attempted and rejected");
        assertTrue(_wraps(host.lastRet(), ConfluenceHook.Reentered.selector), "rejected by the lock");
        assertEq(_thief() - t0, 0, "the attacker gained and lost nothing");
        assertEq(evs.length, 1, "only the outer event");
        assertEq(_nFilled(evs[0]), 2, "outer approval intact: both legs filled");
        (, uint256 out) = _sumEvents();
        assertGe(got, out, "trader got at least the legs' output");
        assertEq(
            usdc0 - IERC20(USDC).balanceOf(makers[0]) - IERC20(USDC).balanceOf(makers[1]),
            out,
            "makers gave the legs' output"
        );
        _assertAfterAttack(address(host));
    }

    /// @dev The same with the nested swap aimed at a second hooked pool on the same token: the lock is global to the
    ///      hook, so it is rejected too.
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
        _row("nested swap, second pool, host=input, full gas (lock)", ok, poolOk, _thief() - t0);
        assertTrue(ok, "the outer swap passes");
        assertTrue(host.fired() && !host.lastOk(), "the nested swap was attempted and rejected");
        assertTrue(_wraps(host.lastRet(), ConfluenceHook.Reentered.selector), "rejected by the lock");
        assertEq(evs.length, 1, "only the outer event");
        assertEq(_nFilled(evs[0]), 2, "both outer legs filled");
        _assertAfterAttack(address(host));
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

    /// @dev H1: slot 0's maker is a contract; during its own leg it calls `unregister`, `register` and `evict` (three
    ///      swaps from one snapshot). The lock rejects each, the slots are untouched, both legs fill.
    function test_V210_reentryRegistryCallsRejectedDuringLegs() public {
        k = _hostilePool();
        re = new Reenterer();
        _joinHost(k, address(re), 100_000e18, 100_000e6, _pf(3_000_000));
        _joinHost(k, makers[1], 100_000e18, 100_000e6, _pf(3_000_000));
        bool zfo = _usdcIn(k);
        bytes[3] memory calls = [
            abi.encodeCall(ConfluenceHook.unregister, (k)),
            abi.encodeCall(ConfluenceHook.register, (k, _pf(3_000_000))),
            abi.encodeCall(ConfluenceHook.evict, (k, makers[1]))
        ];
        for (uint256 i; i < 3; i++) {
            uint256 s0 = vm.snapshotState();
            host.arm(address(re), abi.encodeCall(Reenterer.exec, (address(hookV2), calls[i])), 2, 1);
            bool ok = _try(k, zfo, -int256(IN_USDC));
            assertTrue(ok, "the outer swap passes");
            assertTrue(host.fired(), "the call-out ran");
            assertFalse(re.execOk(), "the registry call was rejected");
            assertEq(bytes4(re.execRet()), ConfluenceHook.Reentered.selector, "by the lock");
            assertEq(hookV2.strategiesOf(k.toId()).length, 2, "slots untouched");
            assertEq(_nFilled(evs[0]), 2, "both legs filled");
            _assertAfterAttack(address(host));
            require(vm.revertToStateAndDelete(s0), "revert failed");
        }
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

    /// @dev PINNED residual risk (THREATS.md): a fee-on-transfer output token. The hook settles the balance it
    ///      measured, the PoolManager receives less, `unlock` reverts `CurrencyNotSettled` after the hook has returned
    ///      (outside any hook try/catch). Pool-only passes. Reverts only for the pool of that token; no funds move.
    function test_V210_pinned_feeOnTransferOutputReverts() public {
        _setup2();
        bool zfo = _usdcIn(k);
        host.setFeeBps(100);
        bool ok = _try(k, zfo, -int256(IN_USDC));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("fee-on-transfer, host=output (pinned)", ok, poolOk, 0);
        assertFalse(ok, "pinned: reverts");
        assertTrue(poolOk, "pool-only passes: the legs cause it");
        _assertAfterAttack(address(host));
    }

    /// @dev PINNED: fee-on-transfer input. v4 itself reverts (the trader's settle is short), so pool-only fails too.
    function test_V210_pinned_feeOnTransferInputReverts() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setFeeBps(100);
        bool ok = _try(k, zfo, -int256(IN_HOST));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("fee-on-transfer, host=input (pinned)", ok, poolOk, 0);
        assertFalse(ok, "pinned: reverts");
        assertFalse(poolOk, "v4 itself reverts: not the hook");
        _assertAfterAttack(address(host));
    }

    /// @dev PINNED residual risk: a token that reverts on `approve(0)` (host = input). The approval reset at
    ///      `ConfluenceHook.sol:502` is outside the try/catch. Not a standard token; reverts only that pool's legged swaps.
    function test_V210_pinned_approveZeroRevertReverts() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setRevertApproveZero(true);
        bool ok = _try(k, zfo, -int256(IN_HOST));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("approve(0) reverts, host=input (pinned)", ok, poolOk, 0);
        assertFalse(ok, "pinned: reverts");
        assertTrue(poolOk, "pool-only passes: the legs cause it");
        _assertAfterAttack(address(host));
    }

    /// @dev H4 with real USDT behaviour (no return value on transfer, transferFrom and approve; approve reverts
    ///      non-zero to non-zero), host = output token: the swap passes and fills its legs.
    function test_V210_usdtTokenOutput() public {
        _setup2();
        bool zfo = _usdcIn(k);
        host.setUsdt(true);
        (bool ok, uint256 got) = _tryGot(k, zfo, -int256(IN_USDC), zfo == _usdcIn(k) ? address(host) : USDC);
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_USDC));
        _row("USDT-shaped token, host=output (H4)", ok, poolOk, 0);
        assertTrue(ok, "a USDT-shaped token must not fail the swap");
        assertGt(got, 0, "the trader received the output");
        assertEq(_nFilled(evs[0]), 2, "both legs filled");
        _assertAfterAttack(address(host));
    }

    /// @dev H4 with real USDT behaviour (no return value on transfer, transferFrom and approve; approve reverts
    ///      non-zero to non-zero), host = input token: the swap passes and fills its legs.
    function test_V210_usdtTokenInput() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setUsdt(true);
        (bool ok, uint256 got) = _tryGot(k, zfo, -int256(IN_HOST), zfo == _usdcIn(k) ? address(host) : USDC);
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("USDT-shaped token, host=input (H4)", ok, poolOk, 0);
        assertTrue(ok, "a USDT-shaped token must not fail the swap");
        assertGt(got, 0, "the trader received the output");
        assertEq(_nFilled(evs[0]), 2, "both legs filled");
        _assertAfterAttack(address(host));
    }

    /// @dev H4's latent path with USDT behaviour on the input side: a leg fails (a blocklisted maker), its input is
    ///      settled back through the no-return token.
    function test_V210_usdtTokenInputFailedLeg() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setUsdt(true);
        host.setBlocked(makers[0], true);
        bool ok = _try(k, zfo, -int256(IN_HOST));
        bool poolOk = _poolOnlyPasses(k, zfo, -int256(IN_HOST));
        _row("USDT-shaped token, host=input, one leg fails (H4)", ok, poolOk, 0);
        assertTrue(ok, "a failed leg's settle-back must not fail the swap");
        assertEq(uint256(evs[0][0].status), LegStatus.SKIP_REVERT, "the blocked maker's leg is skipped");
        assertEq(uint256(evs[0][1].status), LegStatus.FILLED, "the other leg fills");
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

    /// @dev H5, exact input: the issuer blocklists the hook and host is the input token, so `take` to the hook fails.
    ///      The legs are `SKIP_REVERT`, nothing is taken, the pool fills the swap exactly as pool-only does.
    function test_V210_blocklistedHookInput() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setBlocked(address(hookV2), true);
        uint256 po = _poolOnlyGot(k, zfo, -int256(IN_HOST), USDC);
        (bool ok, uint256 got) = _tryGot(k, zfo, -int256(IN_HOST), USDC);
        _row("hook blocklisted, host=input, exact in (H5)", ok, true, 0);
        assertTrue(ok, "a blocklisted hook must not fail the swap");
        assertEq(got, po, "the pool fills the whole swap: exactly pool-only");
        assertEq(_nFilled(evs[0]), 0, "no leg filled");
        assertEq(uint256(evs[0][0].status), LegStatus.SKIP_REVERT, "leg 0 SKIP_REVERT");
        assertEq(uint256(evs[0][1].status), LegStatus.SKIP_REVERT, "leg 1 SKIP_REVERT");
        _assertAfterAttack(address(host));
    }

    /// @dev H5, exact output (the trader asks for 990 USDC, paying host).
    function test_V210_blocklistedHookInputExactOut() public {
        _setup2();
        bool zfo = !_usdcIn(k);
        host.setBlocked(address(hookV2), true);
        uint256 po = _poolOnlyGot(k, zfo, int256(990e6), USDC);
        (bool ok, uint256 got) = _tryGot(k, zfo, int256(990e6), USDC);
        _row("hook blocklisted, host=input, exact out (H5)", ok, true, 0);
        assertTrue(ok, "a blocklisted hook must not fail the swap");
        assertEq(got, po, "exactly pool-only");
        assertEq(got, 990e6, "the exact output");
        assertEq(_nFilled(evs[0]), 0, "no leg filled");
        assertGt(_countSkipRevert(), 0, "non-vacuous: legs were planned and refused");
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
