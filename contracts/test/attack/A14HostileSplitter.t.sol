// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ConfluenceLens} from "../../src/ConfluenceLens.sol";
import {ConfluenceSplitter, LegStatus, Plan} from "../../src/ConfluenceSplitter.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 (carry-over from V2-07 to V2-09): a hostile splitter. The splitter is immutable and bound in the hook's
///         constructor (D-35), so a hostile one means a mis-deployed hook; the hook still checks every plan it gets.
///         V2-08 and V2-09 already refuse (hook and Lens alike) wrong sums, caps, status codes, empty slots, int128
///         overflow, a truncated walk, "not better" and exact output's tail. This file adds what they did not:
///         (1) more than `MAX_LEGS` legs, and the PoolManager total in exact INPUT, each refused by hook and Lens alike;
///         (2) what no check can see: a plan whose `poolOnlyOut` is understated passes `PlanCheck`, and the swap is then
///         WORSE than pool-only. The quote fields are claims the hook cannot recompute, so "never worse than the pool
///         alone" holds for the splitter the hook was built with, not for any address. Pinned here, recorded in THREATS.md
///         as the splitter trust assumption (verify the splitter's bytecode when verifying the hook).
contract A14HostileSplitterTest is AttackBase {
    ConfluenceLens internal lens;

    function _lens() internal returns (ConfluenceLens) {
        if (address(lens).code.length == 0) lens = new ConfluenceLens();
        return lens;
    }

    function _mock(Plan memory q) internal {
        vm.mockCall(address(splitter), abi.encodeWithSelector(ConfluenceSplitter.planExactIn.selector), abi.encode(q));
    }

    /// @dev Hook and Lens refuse the same plan: pool-only output, `SKIP_PLAN`.
    function _refusedByBoth(Plan memory q, Run memory po, string memory ctx) internal {
        uint256 s = vm.snapshotState();
        _mock(q);
        ConfluenceLens.Breakdown memory b = _lens().quote(keyV2, true, -int256(1_000e6));
        Run memory r = _run(keyV2, true, 1_000e6, "");
        assertEq(b.planCode, LegStatus.SKIP_PLAN, string.concat(ctx, ": the Lens refused it"));
        _expectAllStatus(r.legs, LegStatus.SKIP_PLAN, ctx);
        assertEq(r.got, po.got, string.concat(ctx, ": pool-only output"));
        assertEq(b.totalOut, r.got, string.concat(ctx, ": the Lens totals equal the swap"));
        _assertClean();
        vm.clearMockedCalls();
        vm.revertToState(s);
    }

    function test_V210_moreThanMaxLegsIsRefused() public {
        _attackInit();
        _initExact(keyV2);
        M[] memory ms = _fourMakers();
        Run memory po = _poolOnly(keyV2, true, 1_000e6);
        Plan memory p = _plan(keyV2, true, 1_000e6);
        // Four legs, each exactly priced and inside its caps and above the minimum: only the count is wrong.
        Plan memory q = _copy(p);
        uint256 total;
        for (uint256 j; j < 4; j++) {
            uint256 a = 20e6; // 2% of the trade: above MIN_LEG_BPS
            if (a > q.capIn[j]) a = q.capIn[j];
            require(a * 10_000 >= 1_000e6 * hookV2.MIN_LEG_BPS() && a >= q.capMin[j], "premise: a valid leg size");
            (uint256 x, uint256 y) = _virt(ms[j], true);
            (q.amountIn[j], q.amountOut[j], q.status[j]) = (a, _cpOut(x, y, ms[j].p.feeE9, a), LegStatus.FILLED);
            total += a;
        }
        q.poolIn = 1_000e6 - total;
        q.poolOut = type(uint64).max; // generous claims: only the leg count is wrong
        q.poolOnlyOut = 0;
        q.truncated = 0;
        assertEq(hookV2.MAX_LEGS(), 3, "premise: three legs at most");
        _refusedByBoth(q, po, "four legs");
    }

    function test_V210_poolManagerTotalInExactInputIsRefused() public {
        _attackInit();
        _initExact(keyV2);
        M[] memory ms = _threeMakers();
        Run memory po = _poolOnly(keyV2, true, 1_000e6);
        Plan memory p = _plan(keyV2, true, 1_000e6);
        Plan memory q = _copy(p);
        uint256 pmBal = IERC20(USDC).balanceOf(address(manager));
        // One leg asks for more input than the PoolManager holds (the plan's other fields stay consistent).
        q.amountIn[0] = pmBal + 1;
        q.capIn[0] = pmBal + 1;
        q.poolIn = 0;
        (uint256 x, uint256 y) = _virt(ms[0], true);
        q.amountOut[0] = _cpOut(x, y, ms[0].p.feeE9, pmBal + 1);
        _refusedByBoth(q, po, "PoolManager total, exact input");
    }

    /// @dev PINNED trust assumption. A leg to a worse-priced maker (maker 3 charges 1%), sized at its cap and priced
    ///      exactly, with `poolOnlyOut` claimed as 0: every check passes (the strict threshold matches the router's real
    ///      output), the leg fills, and the trader gets LESS than from the pool alone. The hook cannot recompute
    ///      `poolOnlyOut`; it trusts the splitter it was built with.
    function test_V210_pinned_understatedPoolOnlyPassesTheChecks() public {
        _attackInit();
        _initExact(keyV2);
        M[] memory ms = _fourMakers();
        Run memory po = _poolOnly(keyV2, true, 1_000e6);
        Plan memory p = _plan(keyV2, true, 1_000e6);
        Plan memory q = _copy(p);
        for (uint256 j; j < 6; j++) {
            (q.amountIn[j], q.amountOut[j]) = (0, 0);
        }
        uint256 a = q.capIn[3]; // maker 3: 1% fee, 1,000/1,000 depth
        require(a * 10_000 >= 1_000e6 * hookV2.MIN_LEG_BPS() && a >= q.capMin[3], "premise: a valid leg");
        (uint256 x, uint256 y) = _virt(ms[3], true);
        (q.amountIn[3], q.amountOut[3], q.status[3]) = (a, _cpOut(x, y, ms[3].p.feeE9, a), LegStatus.FILLED);
        q.poolIn = 1_000e6 - a;
        q.poolOut = type(uint64).max;
        q.poolOnlyOut = 0; // the lie
        q.tail = 0;
        q.truncated = 0;
        _mock(q);
        Run memory r = _run(keyV2, true, 1_000e6, "");
        emit log_named_uint("trader output with the forged plan", r.got);
        emit log_named_uint("trader output pool-only", po.got);
        assertEq(r.legs[3].status, LegStatus.FILLED, "the forged leg filled: PlanCheck cannot see the lie");
        assertLt(r.got, po.got, "worse than pool-only: the guarantee rests on the splitter the hook was built with");
        _assertClean();
        vm.clearMockedCalls();
    }
}
