// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Controls, ControlsArgsBuilder} from "@1inch/swap-vm/src/instructions/Controls.sol";
import {Program, ProgramBuilder} from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BPS} from "@1inch/swap-vm/src/instructions/Fee.sol";

import {ConfluenceHook} from "../../../src/ConfluenceHook.sol";
import {PoolPriceBandExtruction} from "../../../src/PoolPriceBandExtruction.sol";
import {MockMUMB} from "../../../src/mocks/MockMUMB.sol";
import {StrategyLib} from "../../base/StrategyLib.sol";

/// @notice F08 handler: the actions the invariant run calls, and the ghost state the invariants read.
/// @dev Every swap uses an explicit price limit at the seed range's bounds, so the pool price never leaves the
/// range, no swap reverts with `PriceLimitAlreadyExceeded` (a swap whose limit is already passed is not made), and
/// Aqua is not skipped for good at an extreme price. A swap that hits the limit fills partly, which v4 allows.
contract ConfluenceHandler is Test, StrategyLib {
    using ProgramBuilder for Program;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q96 = FixedPoint96.Q96;
    uint256 internal constant BAND_DENOMINATOR = 10_000;

    /// @dev Everything the handler needs from the test's setUp, in one struct to keep the constructor's stack small.
    struct Env {
        ConfluenceHook hook;
        IPoolManager manager;
        PoolSwapTest swapRouter;
        PoolPriceBandExtruction band;
        MockMUMB mumb;
        PoolKey key;
        address aqua;
        address usdc;
        address router;
        address priya;
        address trader;
        address arb;
        address deployer;
        uint16 bandBps;
        int24 tickLower;
        int24 tickUpper;
        bool usdcIsCurrency0;
        ISwapVM.Order order;
        bytes32 hash;
        uint256 shippedMumb;
        uint256 shippedUsdc;
    }

    /// @dev One strategy Priya shipped. `mumbAtDock` / `usdcAtDock` are her virtual balances just before the dock,
    /// kept because a docked strategy reads as (0, 0xff) in Aqua.
    struct Strategy {
        bytes32 hash;
        uint256 mumbShipped;
        uint256 usdcShipped;
        bool docked;
        uint256 mumbAtDock;
        uint256 usdcAtDock;
    }

    IAqua internal immutable _aqua;
    ConfluenceHook public hook;
    IPoolManager public manager;
    PoolSwapTest public swapRouter;
    PoolPriceBandExtruction public band;
    MockMUMB public mumb;
    PoolKey internal _key;
    address public usdc;
    address public router;
    address public priya;
    address public trader;
    address public arb;
    address public deployer;
    uint16 public bandBps;
    int24 public tickLower;
    int24 public tickUpper;
    bool public usdcIsCurrency0;

    Strategy[] internal _strategies;
    ISwapVM.Order internal _currentOrder;
    uint256 public priyaMumbStart;
    uint256 public priyaUsdcStart;

    // ---- ghosts the invariants and `afterInvariant` read ----
    /// @notice Trader swaps with a non-zero hint.
    uint256 public hintedSwaps;
    /// @notice Trader swaps that emitted `AquaFill`.
    uint256 public fills;
    /// @notice Trader swaps whose Aqua leg was skipped with `PoolPriceBandExceeded`.
    uint256 public bandSkips;
    /// @notice Trader swaps whose Aqua leg was skipped for any other reason.
    uint256 public otherSkips;
    /// @notice `AquaFill` events whose execution price was outside the band of the pool price (must stay 0).
    uint256 public bandViolations;
    /// @notice Trader and arbitrageur swaps made, and how many started with the pool price inside the band of
    /// Priya's price (the share the PROGRESS entry reports).
    uint256 public swapCalls;
    uint256 public swapCallsInBand;
    /// @notice The revert data of the latest skip that was not a band skip, for the run's log.
    bytes public lastOtherReason;
    /// @notice The revert data of every non-band skip, in order, for the run's log.
    bytes[] internal _otherReasons;

    /// @notice All non-band skip reasons of this run.
    function otherReasonList() external view returns (bytes[] memory) {
        return _otherReasons;
    }

    constructor(Env memory e) StrategyLib(e.aqua) {
        _aqua = IAqua(e.aqua);
        hook = e.hook;
        manager = e.manager;
        swapRouter = e.swapRouter;
        band = e.band;
        mumb = e.mumb;
        _key = e.key;
        usdc = e.usdc;
        router = e.router;
        priya = e.priya;
        trader = e.trader;
        arb = e.arb;
        deployer = e.deployer;
        bandBps = e.bandBps;
        tickLower = e.tickLower;
        tickUpper = e.tickUpper;
        usdcIsCurrency0 = e.usdcIsCurrency0;

        _currentOrder = e.order;
        _strategies.push(
            Strategy({
                hash: e.hash,
                mumbShipped: e.shippedMumb,
                usdcShipped: e.shippedUsdc,
                docked: false,
                mumbAtDock: 0,
                usdcAtDock: 0
            })
        );
        // `ship` moves no tokens, so Priya's wallet at construction is the baseline for the value invariant.
        priyaMumbStart = e.mumb.balanceOf(e.priya);
        priyaUsdcStart = IERC20(e.usdc).balanceOf(e.priya);
    }

    // ------------------------------------------------------------------ actions

    /// @notice A trader swap: 200 to 2,000 units, either direction, and a hint that is zero (an eighth of the
    /// time), 1% to 100% of the input in 1% steps (three eighths), or all of it (the other half).
    function traderSwap(uint256 amountSeed, uint256 dirSeed, uint256 hintSeed) external {
        bool usdcIn = dirSeed % 2 == 0;
        uint256 unit = usdcIn ? 1e6 : 1e18;
        uint256 amountIn = bound(amountSeed, 200 * unit, 2_000 * unit);
        uint256 mode = hintSeed % 8;
        // A part of the input on a 1% grid, not a raw random number: the fuzzer favours tiny values, and a dust hint
        // gives the router a zero output, which it refuses (a correct skip, but it would crowd out real fills).
        uint256 hint = mode == 0 ? 0 : (mode <= 3 ? (amountIn * (1 + (hintSeed / 8) % 100)) / 100 : amountIn);
        doTraderSwap(usdcIn, amountIn, hint);
    }

    /// @notice A pool-only swap by the arbitrageur, 1 to 500 units, to move the price.
    function arbSwap(uint256 amountSeed, uint256 dirSeed) external {
        bool usdcIn = dirSeed % 2 == 0;
        uint256 unit = usdcIn ? 1e6 : 1e18;
        uint256 amountIn = bound(amountSeed, unit, 500 * unit);
        bool zeroForOne = usdcIn == usdcIsCurrency0;

        (uint160 s0,,,) = manager.getSlot0(_key.toId());
        bool inBand = _poolInBandOfPriya(s0);
        (bool made,) = _swap(arb, zeroForOne, amountIn, "");
        if (!made) return;
        swapCalls++;
        if (inBand) swapCallsInBand++;
    }

    /// @notice Priya docks the live strategy and ships a new one at the pool's current price. Step 3.
    function priyaRedock(uint256 sizeSeed, uint256 modeSeed) external {}

    /// @notice One trader swap with explicit inputs: `hint` of 0 is pool-only, otherwise the Aqua amount in
    /// `hookData`. The fuzzed `traderSwap` maps its seeds to this; the deterministic reachability test calls it
    /// directly. Updates the ghosts, including the band check on every `AquaFill`.
    function doTraderSwap(bool usdcIn, uint256 amountIn, uint256 hint) public {
        bool zeroForOne = usdcIn == usdcIsCurrency0;
        (uint160 s0,,,) = manager.getSlot0(_key.toId());
        bool inBand = _poolInBandOfPriya(s0);

        (bool made, Vm.Log[] memory logs) = _swap(trader, zeroForOne, amountIn, hint == 0 ? bytes("") : abi.encode(hint));
        if (!made) return;

        swapCalls++;
        if (inBand) swapCallsInBand++;
        if (hint > 0) hintedSwaps++;
        _scan(logs, zeroForOne, s0);
    }

    // ------------------------------------------------------------------ strategy shipping

    /// @notice Dock Priya's live strategy, ship a salted copy of the band program with the given virtual
    /// balances, and register it on the hook. A strategy hash is `keccak256` of the order, and `ship` refuses a
    /// hash it has seen, so re-shipping needs different bytes: `Controls._salt` is a no-op opcode in the canonical
    /// set, so a salt changes the hash and nothing else (checked by `test_F08_saltChangesHashNotOutput`).
    function shipSalted(uint64 salt, uint256 mumbAmount, uint256 usdcAmount) public {
        Strategy storage live = _strategies[_strategies.length - 1];
        address[] memory tokens = _tokens();

        live.mumbAtDock = _virtual(live.hash, address(mumb));
        live.usdcAtDock = _virtual(live.hash, usdc);
        live.docked = true;
        vm.prank(priya);
        _aqua.dock(router, live.hash, tokens);

        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory program = bytes.concat(
            p.build(Controls._salt, ControlsArgsBuilder.buildSalt(salt)),
            _buildBandProgram(FEE_0_30_PCT, address(band), band.build(manager, _key, bandBps))
        );
        ISwapVM.Order memory order = _buildOrder(priya, program);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = mumbAmount;
        amounts[1] = usdcAmount;
        vm.startPrank(priya);
        bytes32 hash = _aqua.ship(router, abi.encode(order), tokens, amounts);
        hook.registerOrder(_key, order);
        vm.stopPrank();

        _currentOrder = order;
        _strategies.push(
            Strategy({
                hash: hash,
                mumbShipped: mumbAmount,
                usdcShipped: usdcAmount,
                docked: false,
                mumbAtDock: 0,
                usdcAtDock: 0
            })
        );
    }

    // ------------------------------------------------------------------ views for the invariants

    /// @notice The hash of Priya's live strategy.
    function currentHash() external view returns (bytes32) {
        return _strategies[_strategies.length - 1].hash;
    }

    /// @notice How many strategies Priya has shipped, the first included.
    function strategyCount() external view returns (uint256) {
        return _strategies.length;
    }

    /// @notice Priya's wallet change since construction and her virtual-balance change over every strategy she
    /// shipped, per token. `ship` and `dock` move no tokens, so the two must be equal (D-22).
    function makerValue() external view returns (int256 walletMumb, int256 virtualMumb, int256 walletUsdc, int256 virtualUsdc) {
        walletMumb = int256(mumb.balanceOf(priya)) - int256(priyaMumbStart);
        walletUsdc = int256(IERC20(usdc).balanceOf(priya)) - int256(priyaUsdcStart);
        for (uint256 i; i < _strategies.length; i++) {
            Strategy storage s = _strategies[i];
            uint256 m = s.docked ? s.mumbAtDock : _virtual(s.hash, address(mumb));
            uint256 u = s.docked ? s.usdcAtDock : _virtual(s.hash, usdc);
            virtualMumb += int256(m) - int256(s.mumbShipped);
            virtualUsdc += int256(u) - int256(s.usdcShipped);
        }
    }

    // ------------------------------------------------------------------ internals

    /// @dev An exact-input swap by `who` with the price limit at the seed range's bound in the swap's direction.
    /// Returns `made = false`, and does nothing, when the pool price is already at or past that limit.
    function _swap(address who, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (bool made, Vm.Log[] memory logs)
    {
        (uint160 s0,,,) = manager.getSlot0(_key.toId());
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? tickLower : tickUpper);
        if (zeroForOne ? limit >= s0 : limit <= s0) return (false, logs);

        _fund(who, Currency.unwrap(zeroForOne ? _key.currency0 : _key.currency1), amountIn);

        vm.recordLogs();
        vm.startPrank(who);
        IERC20(usdc).approve(address(swapRouter), type(uint256).max);
        mumb.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            _key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
        return (true, vm.getRecordedLogs());
    }

    /// @dev Top `who` up to `amount` of `token` if short. MUMB is minted by the deployer; USDC is set with `deal`.
    function _fund(address who, address token, uint256 amount) internal {
        if (IERC20(token).balanceOf(who) >= amount) return;
        if (token == address(mumb)) {
            vm.prank(deployer);
            mumb.mint(who, amount);
        } else {
            deal(token, who, amount);
        }
    }

    /// @dev Read the hook's events of one swap into the ghosts. `s0` is the pool price before the swap, which is
    /// also the price the band reads: the pool curve only runs after `beforeSwap` returns (ARCHITECTURE section 3).
    function _scan(Vm.Log[] memory logs, bool zeroForOne, uint160 s0) internal {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == ConfluenceHook.AquaFill.selector) {
                (uint256 a, uint256 b) = abi.decode(logs[i].data, (uint256, uint256));
                fills++;
                if (!_fillWithinBand(a, b, zeroForOne, s0)) bandViolations++;
            } else if (topic == ConfluenceHook.AquaSkipped.selector) {
                bytes memory reason = abi.decode(logs[i].data, (bytes));
                if (reason.length >= 4 && bytes4(reason) == PoolPriceBandExtruction.PoolPriceBandExceeded.selector) {
                    bandSkips++;
                } else {
                    otherSkips++;
                    lastOtherReason = reason;
                    _otherReasons.push(reason);
                }
            }
        }
    }

    /// @dev The band test of `PoolPriceBandExtruction.extruction`, computed here independently and with the same
    /// rounding: the input is the amount net of the 0.30% fee (rounded up on the fee, as `Fee.sol` does), both
    /// prices are currency1 per currency0 in Q96 with `mulDiv` rounding down, and the fill is inside the band when
    /// `|exec - pool| <= mulDiv(pool, bandBps, 10_000)`.
    function _fillWithinBand(uint256 a, uint256 b, bool zeroForOne, uint160 s0) internal view returns (bool) {
        uint256 net = a - Math.ceilDiv(a * FEE_0_30_PCT, BPS);
        uint256 poolX96 = FullMath.mulDiv(s0, s0, Q96);
        uint256 execX96 = zeroForOne ? FullMath.mulDiv(b, Q96, net) : FullMath.mulDiv(net, Q96, b);
        uint256 diff = execX96 > poolX96 ? execX96 - poolX96 : poolX96 - execX96;
        return diff <= FullMath.mulDiv(poolX96, bandBps, BAND_DENOMINATOR);
    }

    /// @dev Whether the pool price `s0` is within the band of Priya's live strategy's marginal price, taken as the
    /// ratio of her virtual balances (the fee is ignored). A statistic for PROGRESS only: it decides nothing.
    function _poolInBandOfPriya(uint160 s0) internal view returns (bool) {
        bytes32 hash = _strategies[_strategies.length - 1].hash;
        uint256 vMumb = _virtual(hash, address(mumb));
        uint256 vUsdc = _virtual(hash, usdc);
        (uint256 v0, uint256 v1) = usdcIsCurrency0 ? (vUsdc, vMumb) : (vMumb, vUsdc);
        if (v0 == 0 || v1 == 0) return false;
        uint256 poolX96 = FullMath.mulDiv(s0, s0, Q96);
        uint256 priyaX96 = FullMath.mulDiv(v1, Q96, v0);
        uint256 diff = priyaX96 > poolX96 ? priyaX96 - poolX96 : poolX96 - priyaX96;
        return diff <= FullMath.mulDiv(poolX96, bandBps, BAND_DENOMINATOR);
    }

    function _virtual(bytes32 hash, address token) internal view returns (uint256 balance) {
        (balance,) = _aqua.rawBalances(priya, router, hash, token);
    }

    /// @dev The strategy's token list, in the order `ConfluenceBase._shipBand` uses: MUMB, then USDC.
    function _tokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = address(mumb);
        tokens[1] = usdc;
    }
}
