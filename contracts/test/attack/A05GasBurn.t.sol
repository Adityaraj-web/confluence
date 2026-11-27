// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {LegStatus} from "../../src/libraries/PlanCheck.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {AttackBase} from "./AttackBase.t.sol";

/// @notice V2-10 scenario 5: a gas-burning strategy. Two ways a maker could try to burn the swap's gas:
///         (a) ship a program whose guard burns gas and register it: refused, because `register` rebuilds the order from
///         the template with the hook's own guard and asks Aqua whether exactly those bytes are shipped (D-33), so a
///         foreign program is not registrable (the spec's "evictable" is replaced by "not registrable", D-38);
///         (b) a REGISTERED maker whose guard burns (simulated by etching burner code at the guard address, the V207 way):
///         each leg is cut at `LEG_GAS_CAP`, fails inside the try/catch, and the pool fills the share.
contract A05GasBurnTest is AttackBase {
    function test_V210_foreignBurnerProgramCannotRegister() public {
        _attackInit();
        _initExact(keyV2);
        StrategyTemplate.Params memory p = _pf(3_000_000);
        address burner = makeAddr("burnerGuard");
        vm.etch(burner, _burnerCode());
        _fund(makers[0], 10_000e18, 10_000e6);
        // The program ends with the burner instead of BandGuardV2: a different order, a different hash.
        bytes memory prog = StrategyTemplate.program(p, manager, keyV2, burner);
        uint256[] memory a = new uint256[](2);
        (a[0], a[1]) = (10_000e6, 10_000e18);
        vm.prank(makers[0]);
        IAqua(AQUA).ship(ROUTER, abi.encode(StrategyTemplate.order(makers[0], prog)), _tokens(), a);
        vm.prank(makers[0]);
        vm.expectPartialRevert(ConfluenceHook.StrategyNotShipped.selector);
        hookV2.register(keyV2, p);
        assertEq(hookV2.strategiesOf(idV2).length, 0, "nothing registered");
    }

    function test_V210_burningGuardIsCutAtTheLegGasCap() public {
        _attackInit();
        _initExact(keyV2);
        _threeMakers();
        Run memory po = _poolOnly(keyV2, true, 1_000e6);
        vm.etch(_guard(), _burnerCode());
        Run memory r = _run(keyV2, true, 1_000e6, "");
        uint256 burned;
        for (uint256 i; i < r.legs.length; i++) {
            if (r.legs[i].status == LegStatus.SKIP_REVERT) burned++;
        }
        emit log_named_uint("legs cut at the cap", burned);
        emit log_named_uint("gas, pool-only", po.gasUsed);
        emit log_named_uint("gas, three burning legs", r.gasUsed);
        assertGt(burned, 0, "non-vacuous: the burner was reached");
        assertEq(r.got, po.got, "the pool filled everything: exactly pool-only");
        // Each burning leg costs the cap plus the hook's own work around the call (take, approve, set-up, settle-back,
        // reset): measured about 156,000 here; 160,000 per leg is the bound (v1's single-leg figure was 150,000).
        uint256 perLegOverhead = (r.gasUsed - po.gasUsed) / 3 - hookV2.LEG_GAS_CAP();
        emit log_named_uint("hook overhead per burning leg", perLegOverhead);
        assertLe(perLegOverhead, 160_000, "a burning leg cost more than the cap plus the hook's overhead");
        _assertClean();
    }
}
