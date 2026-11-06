// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Controls, ControlsArgsBuilder} from "@1inch/swap-vm/src/instructions/Controls.sol";
import {Program, ProgramBuilder} from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {ConfluenceHook} from "../../../src/ConfluenceHook.sol";
import {PoolPriceBandExtruction} from "../../../src/PoolPriceBandExtruction.sol";
import {MockMUMB} from "../../../src/mocks/MockMUMB.sol";
import {StrategyLib} from "../../base/StrategyLib.sol";

/// @notice F08 handler: the actions the invariant run calls, and the ghost state the invariants read.
/// @dev Step 1 skeleton: `shipSalted` and the ghost getters are real; the three fuzzed actions are empty until
/// step 2 and 3, so the non-vacuity guard in `afterInvariant` is red against it.
contract ConfluenceHandler is Test, StrategyLib {
    using ProgramBuilder for Program;

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

    // ------------------------------------------------------------------ actions (empty until steps 2 and 3)

    /// @notice A trader swap: random size, direction and hint. Step 2.
    function traderSwap(uint256 amountSeed, uint256 dirSeed, uint256 hintSeed) external {}

    /// @notice A pool-only swap by the arbitrageur to move the price. Step 2.
    function arbSwap(uint256 amountSeed, uint256 dirSeed) external {}

    /// @notice Priya docks the live strategy and ships a new one at the pool's current price. Step 3.
    function priyaRedock(uint256 sizeSeed, uint256 saltSeed) external {}

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
