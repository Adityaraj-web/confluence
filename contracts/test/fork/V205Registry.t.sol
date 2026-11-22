// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {BPS} from "@1inch/swap-vm/src/instructions/Fee.sol";
import {Controls} from "@1inch/swap-vm/src/instructions/Controls.sol";
import {XYCSwap} from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import {Fee} from "@1inch/swap-vm/src/instructions/Fee.sol";
import {Extruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {Program, ProgramBuilder} from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {BandGuardArgs, InvalidBand, InvalidDrift} from "../../src/BandGuardV2.sol";
import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {StrategyTemplate} from "../../src/libraries/StrategyTemplate.sol";
import {MockMUMB} from "../../src/mocks/MockMUMB.sol";
import {PoolBase} from "../base/PoolBase.t.sol";
import {StrategyLib} from "../base/StrategyLib.sol";

/// @dev External wrappers, so `vm.expectRevert` can see the reverts of the library's internal functions.
contract TemplateHarness {
    function program(StrategyTemplate.Params calldata p, IPoolManager pm, PoolKey calldata k, address guard)
        external
        pure
        returns (bytes memory)
    {
        return StrategyTemplate.program(p, pm, k, guard);
    }

    function depthValue(uint256 d0, uint256 d1, int24 snapTick) external pure returns (uint256) {
        return StrategyTemplate.depthValue(d0, d1, snapTick);
    }
}

/// @notice V2-05, no fork: template T1 against the 1inch SDK's bytes (`reference/sdk/gen_t1.ts`), the opcode indices
///         against `AquaOpcodes._opcodes()`, the parameter bounds and the depth maths at the extreme prices.
contract V205TemplateTest is Test, StrategyLib {
    string internal constant FIXTURE = "test/vectors/t1_sdk.json";
    address internal constant AQUA_ADDR = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;

    TemplateHarness internal harness;

    constructor() StrategyLib(AQUA_ADDR) {}

    function setUp() public {
        harness = new TemplateHarness();
    }

    function _key(string memory j, uint256 i) internal pure returns (PoolKey memory k) {
        string memory c = string.concat(".cases[", vm.toString(i), "]");
        k = PoolKey({
            currency0: Currency.wrap(vm.parseJsonAddress(j, ".currency0")),
            currency1: Currency.wrap(vm.parseJsonAddress(j, ".currency1")),
            fee: uint24(vm.parseJsonUint(j, string.concat(c, ".fee"))),
            tickSpacing: int24(int256(vm.parseJsonUint(j, string.concat(c, ".tickSpacing")))),
            hooks: IHooks(vm.parseJsonAddress(j, ".hooks"))
        });
    }

    function _params(string memory j, uint256 i) internal pure returns (StrategyTemplate.Params memory p) {
        string memory c = string.concat(".cases[", vm.toString(i), "]");
        p = StrategyTemplate.Params({
            feeE9: uint32(vm.parseJsonUint(j, string.concat(c, ".feeE9"))),
            bandBps: uint16(vm.parseJsonUint(j, string.concat(c, ".bandBps"))),
            driftTicks: uint16(vm.parseJsonUint(j, string.concat(c, ".driftTicks"))),
            exclusive: vm.parseJsonBool(j, string.concat(c, ".exclusive")),
            salt: uint64(vm.parseJsonUint(j, string.concat(c, ".salt")))
        });
    }

    /// @notice Named risk 1: for fixed parameters the program, the ABI-encoded order and its hash equal what the 1inch
    ///         SDK produced (three parameter sets; the fixture is written outside Solidity by `gen_t1.ts`).
    function test_V205_templateMatchesSdk() public view {
        string memory j = vm.readFile(FIXTURE);
        string[] memory names = abi.decode(vm.parseJson(j, ".cases[*].name"), (string[]));
        assertEq(names.length, 3, "fixture has three parameter sets");

        for (uint256 i; i < 3; i++) {
            string memory c = string.concat(".cases[", vm.toString(i), "]");
            PoolKey memory k = _key(j, i);
            StrategyTemplate.Params memory p = _params(j, i);
            address maker = vm.parseJsonAddress(j, ".maker");

            bytes memory prog = StrategyTemplate.program(
                p,
                IPoolManager(vm.parseJsonAddress(j, ".poolManager")),
                k,
                vm.parseJsonAddress(j, ".guard")
            );
            assertEq(prog, vm.parseJsonBytes(j, string.concat(c, ".program")), string.concat("program ", names[i]));

            ISwapVM.Order memory o = StrategyTemplate.order(maker, prog);
            assertEq(abi.encode(o), vm.parseJsonBytes(j, string.concat(c, ".order")), string.concat("order ", names[i]));
            assertEq(
                StrategyTemplate.strategyHash(o),
                vm.parseJsonBytes32(j, string.concat(c, ".hash")),
                string.concat("hash ", names[i])
            );
        }
    }

    /// @notice The four indices are constants in the library; here they are tied to `AquaOpcodes._opcodes()`.
    function test_V205_opcodesFromAquaOpcodes() public pure {
        Program memory p = ProgramBuilder.init(_opcodes());
        assertEq(ProgramBuilder.findOpcode(p, Controls._salt), StrategyTemplate.OP_SALT, "salt");
        assertEq(ProgramBuilder.findOpcode(p, Fee._flatFeeAmountInXD), StrategyTemplate.OP_FLAT_FEE, "flat fee");
        assertEq(ProgramBuilder.findOpcode(p, XYCSwap._xycSwapXD), StrategyTemplate.OP_XYC_SWAP, "xyc");
        assertEq(ProgramBuilder.findOpcode(p, Extruction._extruction), StrategyTemplate.OP_EXTRUCTION, "extruction");
    }

    /// @notice The template accepts exactly what the guard accepts (`BandGuardV2.sol:49`, `:91`): `driftTicks` 0 and
    ///         10,000 pass, 10,001 reverts; the band bounds are 1 and 10,000. A fee of 100% is refused.
    function test_V205_templateBounds() public view {
        PoolKey memory k;
        k.currency0 = Currency.wrap(address(1));
        k.currency1 = Currency.wrap(address(2));
        k.hooks = IHooks(address(3));
        StrategyTemplate.Params memory p = StrategyTemplate.Params(3_000_000, 200, 0, true, 0);
        IPoolManager pm = IPoolManager(address(4));

        harness.program(p, pm, k, address(5));
        p.driftTicks = 10_000;
        harness.program(p, pm, k, address(5));

        // The reverts need calls the harness can make: `expectRevert` is not a view cheatcode, so use try/catch.
        p.driftTicks = 10_001;
        try harness.program(p, pm, k, address(5)) {
            revert("driftTicks 10,001 accepted");
        } catch (bytes memory r) {
            assertEq(bytes4(r), InvalidDrift.selector, "drift selector");
        }
        p.driftTicks = 300;
        p.bandBps = 0;
        try harness.program(p, pm, k, address(5)) {
            revert("bandBps 0 accepted");
        } catch (bytes memory r) {
            assertEq(bytes4(r), InvalidBand.selector, "band 0 selector");
        }
        p.bandBps = 10_001;
        try harness.program(p, pm, k, address(5)) {
            revert("bandBps 10,001 accepted");
        } catch (bytes memory r) {
            assertEq(bytes4(r), InvalidBand.selector, "band 10,001 selector");
        }
        p.bandBps = 10_000;
        harness.program(p, pm, k, address(5));
        p.bandBps = 1;
        p.feeE9 = 999_999_999;
        harness.program(p, pm, k, address(5));
        p.feeE9 = 1_000_000_000;
        try harness.program(p, pm, k, address(5)) {
            revert("fee 100% accepted");
        } catch (bytes memory r) {
            assertEq(bytes4(r), StrategyTemplate.InvalidMakerFee.selector, "fee selector");
        }
    }

    /// @notice Depth maths at the extreme prices, with amounts near uint128 max: no revert, and the ranking is right
    ///         (a saturated value is the largest, a dust value the smallest). Closes risk 2 (overflow).
    function test_V205_depthValueExtremes() public view {
        uint256 big = type(uint128).max;
        int24[2] memory ticks = [TickMath.MIN_TICK, TickMath.MAX_TICK];

        for (uint256 i; i < 2; i++) {
            int24 t = ticks[i];
            uint256 onlyToken0 = harness.depthValue(big, 0, t);
            uint256 onlyToken1 = harness.depthValue(0, big, t);
            uint256 both = harness.depthValue(big, big, t);
            uint256 dust = harness.depthValue(1, 1, t);
            assertEq(onlyToken1, big, "token1 is valued at par");
            assertGe(both, onlyToken0, "sum never below a part");
            assertGe(both, onlyToken1, "sum never below a part");
            assertGe(both, dust, "dust below a full holding");
        }

        // MIN price: one raw token0 is worth almost nothing, so a token1 holding outranks a token0 holding.
        assertGt(harness.depthValue(0, big, TickMath.MIN_TICK), harness.depthValue(big, 0, TickMath.MIN_TICK), "min");
        // MAX price: one raw token0 is worth about 2^128 raw token1, so the token0 holding outranks token1.
        assertGt(harness.depthValue(big, 0, TickMath.MAX_TICK), harness.depthValue(0, big, TickMath.MAX_TICK), "max");

        // Saturation: a holding past the second multiplication's range returns the maximum, never reverts.
        uint256 huge = type(uint248).max;
        assertEq(harness.depthValue(huge, 0, TickMath.MAX_TICK), type(uint256).max, "saturated");
        assertEq(harness.depthValue(huge, huge, TickMath.MAX_TICK), type(uint256).max, "saturated sum");
        assertEq(harness.depthValue(huge, type(uint256).max, 0), type(uint256).max, "sum saturates");
        // Two saturated values tie: ranking never makes a saturated newcomer win over a saturated slot.
        assertEq(
            harness.depthValue(huge, 1, TickMath.MAX_TICK), harness.depthValue(huge, 2, TickMath.MAX_TICK), "tie"
        );
    }

    /// @notice At tick 0 the price is 1, so depth is the plain sum.
    function test_V205_depthValueAtParity() public view {
        assertEq(harness.depthValue(7, 5, 0), 12);
        assertEq(harness.depthValue(0, 0, 0), 0);
    }
}

/// @notice V2-05 on the mainnet fork: the registry on a real pool, against the real Aqua.
contract V205RegistryTest is PoolBase, StrategyLib {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant N_MAKERS = 12;

    ConfluenceHook internal hookV2;
    PoolKey internal keyV2;
    PoolId internal idV2;
    address[N_MAKERS] internal makers;

    constructor() StrategyLib(AQUA) {}

    function setUp() public override {
        super.setUp();
        // The expected-depth helper below puts USDC on the currency0 side (D-28's premise, tested by V200).
        require(usdcIsCurrency0, "premise: USDC is currency0");
        hookV2 = _deployHookV2();
        keyV2 = _createPool(IHooks(address(hookV2)));
        idV2 = keyV2.toId();
        for (uint256 i; i < N_MAKERS; i++) {
            makers[i] = makeAddr(string.concat("maker", vm.toString(i)));
        }
    }

    // ---------------------------------------------------------------- helpers

    function _p() internal pure returns (StrategyTemplate.Params memory) {
        return StrategyTemplate.Params({feeE9: FEE_0_30_PCT, bandBps: 200, driftTicks: 300, exclusive: true, salt: 0});
    }

    function _guard() internal view returns (address) {
        return address(hookV2.bandGuard());
    }

    function _program(StrategyTemplate.Params memory p) internal view returns (bytes memory) {
        return StrategyTemplate.program(p, manager, keyV2, _guard());
    }

    function _hash(address m, StrategyTemplate.Params memory p) internal view returns (bytes32) {
        return StrategyTemplate.strategyHash(StrategyTemplate.order(m, _program(p)));
    }

    /// @dev Gives `m` a wallet of `mumbAmt` and `usdcAmt` (on top of what it has) and approves Aqua for everything.
    function _fund(address m, uint256 mumbAmt, uint256 usdcAmt) internal {
        vm.prank(deployer);
        mumb.mint(m, mumbAmt);
        deal(USDC, m, IERC20(USDC).balanceOf(m) + usdcAmt);
        vm.startPrank(m);
        mumb.approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        vm.stopPrank();
    }

    function _tokens() internal view returns (address[] memory t) {
        t = new address[](2);
        t[0] = USDC; // currency0 (premise)
        t[1] = address(mumb);
    }

    /// @dev Ships `prog` as `m`'s order with the given virtual balances.
    function _shipProgram(address m, bytes memory prog, uint256 mumbVirt, uint256 usdcVirt)
        internal
        returns (bytes32 h)
    {
        uint256[] memory a = new uint256[](2);
        a[0] = usdcVirt;
        a[1] = mumbVirt;
        vm.prank(m);
        h = IAqua(AQUA).ship(ROUTER, abi.encode(StrategyTemplate.order(m, prog)), _tokens(), a);
    }

    function _ship(address m, StrategyTemplate.Params memory p, uint256 mumbVirt, uint256 usdcVirt)
        internal
        returns (bytes32)
    {
        return _shipProgram(m, _program(p), mumbVirt, usdcVirt);
    }

    function _register(address m, StrategyTemplate.Params memory p) internal {
        vm.prank(m);
        hookV2.register(keyV2, p);
    }

    /// @dev Fund, ship and register in one go: wallet = virtual = the given amounts.
    function _join(address m, uint256 mumbAmt, uint256 usdcAmt, StrategyTemplate.Params memory p)
        internal
        returns (bytes32 h)
    {
        _fund(m, mumbAmt, usdcAmt);
        h = _ship(m, p, mumbAmt, usdcAmt);
        _register(m, p);
    }

    /// @dev One tiny swap records the pool's first snapshot (a pool with no swaps has no anchor).
    function _initAnchor() internal {
        _swap(keyV2, trader, usdcForMumb(), -int256(10e6), "");
    }

    function _snap() internal view returns (int24 s) {
        (s,,) = hookV2.anchorOf(idV2);
    }

    /// @dev The spec's depth, written out again here: both sides valued in currency1 (MUMB) at the snapshot, with the
    ///      same two-step rounding as the library. Amounts are the (already minimised) per-token depths.
    function _expected(uint256 mumbDepth, uint256 usdcDepth, int24 snap) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(snap);
        return FullMath.mulDiv(FullMath.mulDiv(usdcDepth, s, 2 ** 96), s, 2 ** 96) + mumbDepth;
    }

    /// @dev Makers 0..n-1 with wallet = virtual = (i+1)*1000 MUMB and (i+1)*1000 USDC.
    function _fill(uint256 n) internal {
        for (uint256 i; i < n; i++) {
            _join(makers[i], (i + 1) * 1000e18, (i + 1) * 1000e6, _p());
        }
    }

    function _isRegistered(address m) internal view returns (bool) {
        ConfluenceHook.Slot[] memory s = hookV2.strategiesOf(idV2);
        for (uint256 i; i < s.length; i++) {
            if (s[i].maker == m) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------- status checks

    function test_V205_rejectsUnshipped() public {
        _initAnchor();
        address m = makers[0];
        _fund(m, 1000e18, 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.StrategyNotShipped.selector, _hash(m, _p())));
        _register(m, _p());
        assertEq(hookV2.strategiesOf(idV2).length, 0, "nothing stored");
    }

    /// @notice A strategy shipped for another app, another token pair, three tokens, another hook, another taker rule,
    ///         another key field or another maker never matches the program the hook rebuilds.
    function test_V205_rejectsForeignProgram() public {
        _initAnchor();
        address m = makers[0];
        address other = makers[1];
        _fund(m, 100_000e18, 100_000e6);
        _fund(other, 100_000e18, 100_000e6);
        StrategyTemplate.Params memory p = _p();
        bytes memory prog = _program(p);
        bytes32 expected = _hash(m, p);
        bytes memory notShipped = abi.encodeWithSelector(ConfluenceHook.StrategyNotShipped.selector, expected);

        // Cross-check: v1's own builder (fee, XYC, extruction, no salt) gives the template's bytes.
        bytes memory args = _args(keyV2, p);
        assertEq(_buildBandProgram(p.feeE9, _guard(), args), prog, "template == StrategyLib for salt 0");

        uint256[] memory a = new uint256[](2);
        a[0] = 1000e6;
        a[1] = 1000e18;
        bytes memory encoded = abi.encode(StrategyTemplate.order(m, prog));

        // 1. another app
        vm.prank(m);
        IAqua(AQUA).ship(address(0xdead), encoded, _tokens(), a);
        vm.expectRevert(notShipped);
        _register(m, p);

        // 2. another token pair: the second token is not the pool's currency1
        address[] memory pair = _tokens();
        pair[1] = address(new MockMUMB());
        vm.prank(m);
        IAqua(AQUA).ship(ROUTER, encoded, pair, a);
        vm.expectRevert(notShipped);
        _register(m, p);
        (, uint8 count) = IAqua(AQUA).rawBalances(m, ROUTER, expected, address(mumb));
        assertEq(count, 0, "the pool's token1 was never shipped");

        // 3. three tokens (the right pair plus one more): Aqua stores a count of 3, not 2
        address[] memory three = new address[](3);
        uint256[] memory a3 = new uint256[](3);
        (three[0], three[1], three[2]) = (USDC, address(mumb), address(0xbeef));
        (a3[0], a3[1], a3[2]) = (1000e6, 1000e18, 1);
        vm.prank(other);
        IAqua(AQUA).ship(ROUTER, abi.encode(StrategyTemplate.order(other, prog)), three, a3);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.StrategyNotShipped.selector, _hash(other, p)));
        _register(other, p);

        // 4. another hook, 5. another taker rule (exclusive off), 6. each other key field: all different hashes
        PoolKey memory k = keyV2;
        k.hooks = IHooks(address(0xBEEF));
        _shipTampered(m, p, k, 1);
        (k.hooks, k.currency0, k.currency1) = (keyV2.hooks, keyV2.currency1, keyV2.currency0);
        _shipTampered(m, p, k, 2);
        k.currency0 = keyV2.currency0;
        k.currency1 = keyV2.currency1;
        k.fee = 500;
        _shipTampered(m, p, k, 3);
        k.fee = keyV2.fee;
        k.tickSpacing = 10;
        _shipTampered(m, p, k, 4);
        k.tickSpacing = keyV2.tickSpacing;
        StrategyTemplate.Params memory open = _p();
        open.exclusive = false;
        bytes32 hOpen = _shipProgram(m, StrategyTemplate.program(open, manager, k, _guard()), 1000e18, 1000e6);
        assertTrue(hOpen != expected, "different strategy");
        vm.expectRevert(notShipped);
        _register(m, p);

        // 7. shipped by another maker, with this maker named in the order: Aqua keys the shipment by the sender
        bytes memory forged = abi.encode(StrategyTemplate.order(m, StrategyTemplate.program(p, manager, keyV2, _guard())));
        vm.prank(makers[2]);
        IAqua(AQUA).ship(ROUTER, forged, _tokens(), a);
        vm.expectRevert(notShipped);
        _register(m, p);

        assertEq(hookV2.strategiesOf(idV2).length, 0, "nothing registered");
    }

    function _args(PoolKey memory k, StrategyTemplate.Params memory p) internal view returns (bytes memory) {
        return BandGuardArgs.build(manager, k, p.bandBps, p.driftTicks, p.exclusive ? 1 : 0);
    }

    /// @dev Ships a program whose guard args name `k` (another maker-chosen key), then shows registering the true
    ///      parameters still finds nothing shipped.
    function _shipTampered(address m, StrategyTemplate.Params memory p, PoolKey memory k, uint256 n) internal {
        bytes memory prog = _buildBandProgram(p.feeE9, _guard(), _args(k, p));
        assertTrue(keccak256(prog) != keccak256(_program(p)), "tampered program differs");
        _shipProgram(m, prog, 1000e18 + n, 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.StrategyNotShipped.selector, _hash(m, p)));
        _register(m, p);
    }

    function test_V205_rejectsDocked() public {
        _initAnchor();
        address m = makers[0];
        _fund(m, 1000e18, 1000e6);
        bytes32 h = _ship(m, _p(), 1000e18, 1000e6);
        vm.prank(m);
        IAqua(AQUA).dock(ROUTER, h, _tokens());
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.StrategyDocked.selector, h));
        _register(m, _p());
        assertEq(hookV2.strategiesOf(idV2).length, 0, "nothing stored");
    }

    // ---------------------------------------------------------------- slots, eviction, depth

    function test_V205_slotsAndEviction() public {
        _initAnchor();
        int24 snap = _snap();

        // The first registration emits its event with the exact depth.
        StrategyTemplate.Params memory p = _p();
        _fund(makers[0], 1000e18, 1000e6);
        bytes32 h0 = _ship(makers[0], p, 1000e18, 1000e6);
        uint256 d0 = _expected(1000e18, 1000e6, snap);
        vm.expectEmit(true, true, false, true, address(hookV2));
        emit ConfluenceHook.MakerRegistered(idV2, makers[0], h0, p, d0);
        _register(makers[0], p);
        for (uint256 i = 1; i < 6; i++) {
            _join(makers[i], (i + 1) * 1000e18, (i + 1) * 1000e6, p);
        }

        ConfluenceHook.Slot[] memory s = hookV2.strategiesOf(idV2);
        assertEq(s.length, 6, "six slots");
        assertEq(hookV2.MAX_STRATEGIES(), 6);
        for (uint256 i; i < 6; i++) {
            assertEq(s[i].maker, makers[i], "slot order");
            assertEq(s[i].strategyHash, _hash(makers[i], p), "slot hash");
            assertEq(hookV2.depthOf(keyV2, makers[i]), _expected((i + 1) * 1000e18, (i + 1) * 1000e6, snap), "depth");
        }

        // A newcomer with exactly the smallest slot's depth does not displace it; neither does a smaller one.
        _fund(makers[6], 1000e18, 1000e6);
        _ship(makers[6], p, 1000e18, 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.DepthTooLow.selector, d0, d0));
        _register(makers[6], p);

        _fund(makers[7], 999e18, 1000e6);
        _ship(makers[7], p, 999e18, 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.DepthTooLow.selector, d0 - 1e18, d0));
        _register(makers[7], p);
        assertEq(hookV2.strategiesOf(idV2).length, 6, "still six");

        // One more wei of depth and the smallest slot is evicted.
        _fund(makers[8], 1000e18 + 1, 1000e6);
        bytes32 h8 = _ship(makers[8], p, 1000e18 + 1, 1000e6);
        vm.expectEmit(true, true, false, true, address(hookV2));
        emit ConfluenceHook.MakerEvicted(idV2, makers[0], h0, ConfluenceHook.EvictReason.DISPLACED);
        vm.expectEmit(true, true, false, true, address(hookV2));
        emit ConfluenceHook.MakerRegistered(idV2, makers[8], h8, p, d0 + 1);
        _register(makers[8], p);

        s = hookV2.strategiesOf(idV2);
        assertEq(s.length, 6, "still six");
        assertFalse(_isRegistered(makers[0]), "smallest gone");
        assertTrue(_isRegistered(makers[8]), "newcomer in");
        assertEq(s[0].maker, makers[8], "newcomer took the evicted slot");
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.NotRegistered.selector, makers[0]));
        hookV2.depthOf(keyV2, makers[0]);

        // The evicted maker cannot come straight back: its depth is now the smallest.
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.DepthTooLow.selector, d0, d0 + 1));
        _register(makers[0], p);

        // A maker registering again replaces its own slot in place and evicts nobody.
        StrategyTemplate.Params memory p2 = _p();
        p2.salt = 7;
        _ship(makers[3], p2, 4000e18, 4000e6);
        _register(makers[3], p2);
        s = hookV2.strategiesOf(idV2);
        assertEq(s.length, 6, "no growth");
        assertEq(s[3].maker, makers[3]);
        assertEq(s[3].params.salt, 7, "own slot replaced in place");
        assertEq(s[3].strategyHash, _hash(makers[3], p2));
    }

    /// @notice Depth counts what can be filled, as Aqua sees it: min(virtual, wallet, allowance) per token. A newcomer
    ///         with phantom virtual balances cannot evict; a registered maker whose funds go away is evicted first.
    function test_V205_phantomDepthCannotEvict() public {
        _initAnchor();
        int24 snap = _snap();
        _fill(6);
        uint256 smallest = _expected(1000e18, 1000e6, snap);
        StrategyTemplate.Params memory p = _p();
        uint256 phantom = 1_000_000e18;

        // (a) a huge virtual balance, a small wallet
        _fund(makers[6], 100e18, 100e6);
        _ship(makers[6], p, phantom, phantom / 1e12);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.DepthTooLow.selector, _expected(100e18, 100e6, snap), smallest));
        _register(makers[6], p);

        // (b) a huge virtual balance and wallet, a small allowance to Aqua
        _fund(makers[7], phantom, phantom / 1e12);
        vm.startPrank(makers[7]);
        mumb.approve(AQUA, 500e18);
        IERC20(USDC).approve(AQUA, 500e6);
        vm.stopPrank();
        _ship(makers[7], p, phantom, phantom / 1e12);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.DepthTooLow.selector, _expected(500e18, 500e6, snap), smallest));
        _register(makers[7], p);

        // (c) a huge wallet and allowance, a small virtual balance
        _fund(makers[8], phantom, phantom / 1e12);
        _ship(makers[8], p, 300e18, 300e6);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.DepthTooLow.selector, _expected(300e18, 300e6, snap), smallest));
        _register(makers[8], p);
        assertEq(hookV2.strategiesOf(idV2).length, 6, "no phantom got in");

        // Registered maker 3 drops its allowance after registering: its depth is zero now. A newcomer worth far less
        // than the smallest healthy slot (maker 0) takes the dead slot, and maker 0 stays.
        vm.startPrank(makers[3]);
        mumb.approve(AQUA, 0);
        IERC20(USDC).approve(AQUA, 0);
        vm.stopPrank();
        assertEq(hookV2.depthOf(keyV2, makers[3]), 0, "allowance dropped");
        bytes32 h3 = hookV2.strategiesOf(idV2)[3].strategyHash;
        bytes32 h9 = _ship(makers[9], p, 400e18, 400e6);
        _fund(makers[9], 400e18, 400e6);
        vm.expectEmit(true, true, false, true, address(hookV2));
        emit ConfluenceHook.MakerEvicted(idV2, makers[3], h3, ConfluenceHook.EvictReason.NO_DEPTH);
        vm.expectEmit(true, true, false, true, address(hookV2));
        emit ConfluenceHook.MakerRegistered(idV2, makers[9], h9, p, _expected(400e18, 400e6, snap));
        _register(makers[9], p);
        assertFalse(_isRegistered(makers[3]), "dead slot evicted");
        assertTrue(_isRegistered(makers[0]), "healthy smallest stays");

        // Maker 4 moves its wallet away: zero depth again, evicted by the next newcomer, maker 0 still stays.
        vm.startPrank(makers[4]);
        mumb.transfer(makers[10], mumb.balanceOf(makers[4]));
        IERC20(USDC).transfer(makers[10], IERC20(USDC).balanceOf(makers[4]));
        vm.stopPrank();
        assertEq(hookV2.depthOf(keyV2, makers[4]), 0, "wallet emptied");
        _fund(makers[11], 450e18, 450e6);
        _ship(makers[11], p, 450e18, 450e6);
        _register(makers[11], p);
        assertFalse(_isRegistered(makers[4]), "emptied slot evicted");
        assertTrue(_isRegistered(makers[0]), "healthy smallest stays");
        assertEq(hookV2.strategiesOf(idV2).length, 6);
    }

    function test_V205_anyoneEvictsDocked() public {
        _initAnchor();
        _fill(5);
        address stranger = makeAddr("stranger");

        // healthy: not evictable, and an unknown maker is refused
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.NotEvictable.selector, makers[0]));
        hookV2.evict(keyV2, makers[0]);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.NotRegistered.selector, makers[9]));
        hookV2.evict(keyV2, makers[9]);

        // docked
        bytes32 h1 = hookV2.strategiesOf(idV2)[1].strategyHash;
        vm.prank(makers[1]);
        IAqua(AQUA).dock(ROUTER, h1, _tokens());
        vm.expectEmit(true, true, false, true, address(hookV2));
        emit ConfluenceHook.MakerEvicted(idV2, makers[1], h1, ConfluenceHook.EvictReason.DOCKED);
        vm.prank(stranger);
        hookV2.evict(keyV2, makers[1]);
        assertFalse(_isRegistered(makers[1]), "docked slot gone");

        // zero allowance
        bytes32 h2 = hookV2.strategiesOf(idV2)[hookV2.strategiesOf(idV2).length - 1].strategyHash;
        address last = hookV2.strategiesOf(idV2)[hookV2.strategiesOf(idV2).length - 1].maker;
        vm.startPrank(last);
        mumb.approve(AQUA, 0);
        IERC20(USDC).approve(AQUA, 0);
        vm.stopPrank();
        vm.expectEmit(true, true, false, true, address(hookV2));
        emit ConfluenceHook.MakerEvicted(idV2, last, h2, ConfluenceHook.EvictReason.NO_DEPTH);
        vm.prank(stranger);
        hookV2.evict(keyV2, last);

        // the others stay; the registry has room again
        assertEq(hookV2.strategiesOf(idV2).length, 3, "three left");
    }

    /// @notice Closes D-18: only a maker can remove its own slot; a newcomer displaces another only by depth.
    function test_V205_noDisplacement() public {
        _initAnchor();
        int24 snap = _snap();
        _fill(6);
        bytes memory before = abi.encode(hookV2.strategiesOf(idV2));
        address a = makers[0];
        address b = makers[6];
        _fund(b, 500e18, 500e6);

        vm.prank(b);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.NotRegistered.selector, b));
        hookV2.unregister(keyV2);

        vm.prank(b);
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.NotEvictable.selector, a));
        hookV2.evict(keyV2, a);

        // B claiming A's exact parameters is B's own strategy, and B shipped nothing yet.
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.StrategyNotShipped.selector, _hash(b, _p())));
        _register(b, _p());

        // B ships its own, but with less depth than every slot: no way in.
        _ship(b, _p(), 500e18, 500e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConfluenceHook.DepthTooLow.selector, _expected(500e18, 500e6, snap), _expected(1000e18, 1000e6, snap)
            )
        );
        _register(b, _p());

        assertEq(abi.encode(hookV2.strategiesOf(idV2)), before, "no slot changed");

        // A can remove itself, and only then.
        bytes32 hA = hookV2.strategiesOf(idV2)[0].strategyHash;
        vm.expectEmit(true, true, false, true, address(hookV2));
        emit ConfluenceHook.MakerUnregistered(idV2, a, hA);
        vm.prank(a);
        hookV2.unregister(keyV2);
        assertFalse(_isRegistered(a));
        assertEq(hookV2.strategiesOf(idV2).length, 5);
        for (uint256 i = 1; i < 6; i++) {
            assertTrue(_isRegistered(makers[i]), "others untouched");
        }
        // The room freed by A lets B in without evicting anybody.
        _register(b, _p());
        assertEq(hookV2.strategiesOf(idV2).length, 6);
    }

    /// @notice One wallet is counted once: a maker has one slot per pool, so a second strategy from the same wallet
    ///         replaces the first; depth is bounded by the wallet, not by the sum of two virtual balances.
    function test_V205_oneWalletCountsOnce() public {
        _initAnchor();
        int24 snap = _snap();
        address m = makers[0];
        _fund(m, 1500e18, 1500e6);
        StrategyTemplate.Params memory p1 = _p();
        p1.salt = 1;
        StrategyTemplate.Params memory p2 = _p();
        p2.salt = 2;
        _ship(m, p1, 1000e18, 1000e6);
        _ship(m, p2, 1000e18, 1000e6);
        _register(m, p1);
        assertEq(hookV2.depthOf(keyV2, m), _expected(1000e18, 1000e6, snap));
        _register(m, p2);
        assertEq(hookV2.strategiesOf(idV2).length, 1, "one slot per maker");
        assertEq(hookV2.strategiesOf(idV2)[0].strategyHash, _hash(m, p2), "replaced in place");
        // 1,500 of wallet backs 2 x 1,000 of virtual balance, but depth is one strategy's min, not 2,000.
        assertEq(hookV2.depthOf(keyV2, m), _expected(1000e18, 1000e6, snap), "counted once");
    }

    // ---------------------------------------------------------------- key, params, price source

    function test_V205_poolKeyChecks() public {
        address m = makers[0];
        StrategyTemplate.Params memory p = _p();
        PoolKey memory k = keyV2;

        k.hooks = IHooks(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.HooksMismatch.selector, address(0xBEEF)));
        vm.prank(m);
        hookV2.register(k, p);
        k.hooks = IHooks(address(0));
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.HooksMismatch.selector, address(0)));
        vm.prank(m);
        hookV2.register(k, p);
        k.hooks = IHooks(address(hook)); // the v1 hook
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.HooksMismatch.selector, address(hook)));
        vm.prank(m);
        hookV2.register(k, p);
        k.hooks = keyV2.hooks;

        (k.currency0, k.currency1) = (keyV2.currency1, keyV2.currency0);
        vm.expectRevert(ConfluenceHook.CurrenciesOutOfOrder.selector);
        vm.prank(m);
        hookV2.register(k, p);
        k.currency1 = k.currency0;
        vm.expectRevert(ConfluenceHook.CurrenciesOutOfOrder.selector);
        vm.prank(m);
        hookV2.register(k, p);
        k.currency0 = Currency.wrap(address(0));
        k.currency1 = keyV2.currency1;
        vm.expectRevert(ConfluenceHook.NativeCurrencyUnsupported.selector);
        vm.prank(m);
        hookV2.register(k, p);
        k.currency0 = keyV2.currency0;

        k.fee = 1_000_001;
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.InvalidPoolFee.selector, uint24(1_000_001)));
        vm.prank(m);
        hookV2.register(k, p);
        k.fee = 0x800001;
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.InvalidPoolFee.selector, uint24(0x800001)));
        vm.prank(m);
        hookV2.register(k, p);
        k.fee = keyV2.fee;

        int24[3] memory bad = [int24(0), int24(-1), int24(32768)];
        for (uint256 i; i < 3; i++) {
            k.tickSpacing = bad[i];
            vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.InvalidTickSpacing.selector, bad[i]));
            vm.prank(m);
            hookV2.register(k, p);
        }
        k.tickSpacing = keyV2.tickSpacing;

        // A valid fee or spacing that names a pool nobody initialised is only an unknown pool to the hook.
        k.fee = 500;
        vm.expectRevert(ConfluenceHook.PoolNotInitialized.selector);
        vm.prank(m);
        hookV2.register(k, p);
        k.fee = keyV2.fee;
        k.tickSpacing = 10;
        vm.expectRevert(ConfluenceHook.PoolNotInitialized.selector);
        vm.prank(m);
        hookV2.register(k, p);
    }

    /// @notice Carry-over 3: `driftTicks` is bounded by the guard's own 0 to 10,000; both edges register.
    function test_V205_driftTicksEdges() public {
        _initAnchor();
        StrategyTemplate.Params memory p = _p();
        p.driftTicks = 0;
        _join(makers[0], 1000e18, 1000e6, p);
        assertEq(hookV2.strategiesOf(idV2)[0].params.driftTicks, 0);
        p.driftTicks = 10_000;
        _join(makers[1], 1000e18, 1000e6, p);
        assertEq(hookV2.strategiesOf(idV2)[1].params.driftTicks, 10_000);
        p.driftTicks = 10_001;
        vm.expectRevert(InvalidDrift.selector);
        _register(makers[2], p);
    }

    /// @notice Depth is priced with the recorded snapshot, never with spot (D-33). With no anchor there is no price:
    ///         `register` and `depthOf` revert. After the anchor exists, moving `slot0` inside the same block changes
    ///         no depth and lets no newcomer in.
    function test_V205_depthIgnoresSpotAndNeedsAnchor() public {
        StrategyTemplate.Params memory p = _p();
        _fund(makers[0], 1000e18, 1000e6);
        _ship(makers[0], p, 1000e18, 1000e6);

        // Fresh pool: no swap yet, no anchor.
        vm.expectRevert(ConfluenceHook.AnchorNotInitialised.selector);
        _register(makers[0], p);
        vm.expectRevert(ConfluenceHook.AnchorNotInitialised.selector);
        hookV2.depthOf(keyV2, makers[0]);

        // The first swap records the snapshot; six MUMB-only slots of 1,000 .. 6,000 MUMB register in this block.
        _initAnchor();
        int24 snap = _snap();
        for (uint256 i; i < 6; i++) {
            _join(makers[i + 1], (i + 1) * 1000e18, 0, p);
        }
        uint256[6] memory before;
        for (uint256 i; i < 6; i++) {
            before[i] = hookV2.depthOf(keyV2, makers[i + 1]);
            assertEq(before[i], (i + 1) * 1000e18, "MUMB-only depth is par");
        }

        // A newcomer holding only USDC, worth 990 MUMB at the snapshot but more than 1,000 at the pushed spot.
        _fund(makers[7], 0, 990e6);
        _ship(makers[7], p, 0, 990e6);

        (, int24 tickBefore,,) = manager.getSlot0(idV2);
        _swap(keyV2, trader, !usdcForMumb(), -int256(1_500e18), ""); // same block: price of USDC in MUMB goes up
        (, int24 tickAfter,,) = manager.getSlot0(idV2);
        assertGt(tickAfter, tickBefore + 200, "spot moved by more than 200 ticks");
        assertEq(_snap(), snap, "snapshot unmoved");

        uint256 atSnapshot = _expected(0, 990e6, snap);
        uint256 atSpot = _expected(0, 990e6, tickAfter);
        assertLt(atSnapshot, 1000e18, "premise: loses at the snapshot");
        assertGt(atSpot, 1000e18, "premise: would win at spot");

        for (uint256 i; i < 6; i++) {
            assertEq(hookV2.depthOf(keyV2, makers[i + 1]), before[i], "depth unchanged by the push");
        }
        vm.expectRevert(abi.encodeWithSelector(ConfluenceHook.DepthTooLow.selector, atSnapshot, 1000e18));
        _register(makers[7], p);
    }
}

/// @notice V2-05 on Unichain: a strategy built by the template ships through the real Aqua, registers, and fills
///         through the real router with the hook's address as taker (extends gate G0).
/// @dev Covers: template -> real Aqua `ship` -> `register` (status and depth checks) -> `BandGuardV2` reading this
///      hook's own anchor on a real v4 pool -> a fill with `msg.sender == hook` and the hook as taker. Left for V2-07:
///      the hook calling the router itself from `beforeSwap`, `take`/`settle` with the PoolManager, the exact approve
///      and reset, the try/catch fallback and the returned delta. Here the hook's address is pranked and its balances
///      are funded by the test.
contract V205UnichainTest is Test, StrategyLib {
    using PoolIdLibrary for PoolKey;

    address internal constant AQUA_ADDR = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant ROUTER_ADDR = 0x111111338c5091E8440b67B168bAe16a668AC0De;
    /// @dev Uniswap v4 PoolManager on Unichain (not the mainnet address).
    address internal constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    uint256 internal constant SHIPPED = 100_000e18;
    uint256 internal constant SWAP_IN = 1_000e18;

    ConfluenceHook internal hook;
    IPoolManager internal manager;
    MockMUMB internal t0;
    MockMUMB internal t1;
    PoolKey internal key;
    address internal maker;

    constructor() StrategyLib(AQUA_ADDR) {}

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_URL"), vm.envUint("UNICHAIN_FORK_BLOCK"));
        assertEq(block.chainid, 130, "not Unichain");
        manager = IPoolManager(UNICHAIN_POOL_MANAGER);
        assertGt(address(manager).code.length, 0, "no PoolManager");

        (MockMUMB a, MockMUMB b) = (new MockMUMB(), new MockMUMB());
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        maker = makeAddr("maker");

        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, type(ConfluenceHook).creationCode, args);
        hook = new ConfluenceHook{salt: salt}(manager);
        assertEq(address(hook), expected, "hook address");

        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, 2 ** 96);

        // Liquidity around price 1, then a tiny swap: the first swap records the snapshot (tick 0).
        PoolModifyLiquidityTest lr = new PoolModifyLiquidityTest(manager);
        PoolSwapTest sr = new PoolSwapTest(manager);
        t0.mint(address(this), 1_000e18);
        t1.mint(address(this), 1_000e18);
        t0.approve(address(lr), type(uint256).max);
        t1.approve(address(lr), type(uint256).max);
        t0.approve(address(sr), type(uint256).max);
        lr.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e19, salt: bytes32(0)}),
            ""
        );
        sr.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _takerData() internal view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(hook),
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                threshold: abi.encode(uint256(0)),
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }

    function _aqua(bytes32 h, address token) internal view returns (uint256 bal) {
        (bal,) = IAqua(AQUA_ADDR).rawBalances(maker, ROUTER_ADDR, h, token);
    }

    function test_V205_templateFillsOnUnichain() public {
        StrategyTemplate.Params memory p = StrategyTemplate.Params({
            feeE9: FEE_0_30_PCT, bandBps: 200, driftTicks: 300, exclusive: true, salt: 0
        });
        ISwapVM.Order memory order =
            StrategyTemplate.order(maker, StrategyTemplate.program(p, manager, key, address(hook.bandGuard())));

        t0.mint(maker, SHIPPED);
        t1.mint(maker, SHIPPED);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(t0), address(t1));
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (SHIPPED, SHIPPED);
        vm.startPrank(maker);
        t0.approve(AQUA_ADDR, type(uint256).max);
        t1.approve(AQUA_ADDR, type(uint256).max);
        bytes32 h = IAqua(AQUA_ADDR).ship(ROUTER_ADDR, abi.encode(order), tokens, amounts);
        hook.register(key, p);
        vm.stopPrank();

        // Registered, with par pricing: depth is 2 x 100,000 at tick 0.
        assertEq(hook.strategiesOf(key.toId()).length, 1, "registered");
        assertEq(hook.depthOf(key, maker), 2 * SHIPPED, "depth");
        (int24 snapTick,, bool fresh) = hook.anchorOf(key.toId());
        assertEq(snapTick, 0, "snapshot");
        assertTrue(fresh, "anchor stored this block");

        // The hook as taker: fee rounded up, then XYC rounded down.
        uint256 net = SWAP_IN - Math.ceilDiv(SWAP_IN * FEE_0_30_PCT, BPS);
        uint256 expectedOut = (net * SHIPPED) / (SHIPPED + net);
        t0.mint(address(hook), SWAP_IN);
        vm.startPrank(address(hook));
        t0.approve(ROUTER_ADDR, SWAP_IN);
        (uint256 amountIn, uint256 amountOut,) =
            ISwapVM(ROUTER_ADDR).swap(order, address(t0), address(t1), SWAP_IN, _takerData());
        t0.approve(ROUTER_ADDR, 0);
        vm.stopPrank();

        assertEq(amountIn, SWAP_IN, "amountIn");
        assertEq(amountOut, expectedOut, "amountOut");
        assertEq(t1.balanceOf(address(hook)), expectedOut, "the hook holds the output (V2-07 settles it)");
        assertEq(t0.balanceOf(address(hook)), 0, "input fully spent");
        assertEq(t0.balanceOf(maker), SHIPPED + SWAP_IN, "maker wallet in");
        assertEq(t1.balanceOf(maker), SHIPPED - expectedOut, "maker wallet out");
        assertEq(_aqua(h, address(t0)), SHIPPED + SWAP_IN, "virtual in");
        assertEq(_aqua(h, address(t1)), SHIPPED - expectedOut, "virtual out");
        assertEq(t0.balanceOf(ROUTER_ADDR) + t1.balanceOf(ROUTER_ADDR), 0, "router holds nothing");
        assertEq(t0.balanceOf(AQUA_ADDR) + t1.balanceOf(AQUA_ADDR), 0, "aqua holds nothing");
        assertEq(t0.allowance(address(hook), ROUTER_ADDR), 0, "approval reset");

        // Any other taker is refused by the guard's exclusive rule (the strategy is exclusive).
        address stranger = makeAddr("stranger");
        t0.mint(stranger, SWAP_IN);
        vm.startPrank(stranger);
        t0.approve(ROUTER_ADDR, SWAP_IN);
        vm.expectRevert();
        ISwapVM(ROUTER_ADDR).swap(order, address(t0), address(t1), SWAP_IN, _takerDataFor(stranger));
        vm.stopPrank();
    }

    function _takerDataFor(address taker) internal pure returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: taker,
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                threshold: abi.encode(uint256(0)),
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }
}
