// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {ConfluenceHook} from "../src/ConfluenceHook.sol";
import {PoolPriceBandExtruction} from "../src/PoolPriceBandExtruction.sol";
import {MockMUMB} from "../src/mocks/MockMUMB.sol";
import {StrategyLib} from "../test/base/StrategyLib.sol";

/// @notice Pulled forward from F09 (D-21): ARCHITECTURE section 2, steps 2 to 7, on a running anvil fork.
/// Writes `deployments/local.json`. Run from `contracts/`:
///   forge script script/Setup.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
/// Keys are anvil's public test keys from `.env` (DEPLOYER, PRIYA, TRADER).
/// The trader and Priya are funded and approved for real, so the quoter's `eth_call` needs no state override.
/// The step 8 snapshot belongs to F09's `make setup`; this script does not take it.
contract Setup is Script, StrategyLib {
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Same amounts as ForkBase / PoolBase / ConfluenceBase, so tests and the demo agree.
    uint256 internal constant PRIYA_MUMB = 1_000_000e18;
    uint256 internal constant TRADER_MUMB = 10_000e18;
    uint256 internal constant PRIYA_USDC = 1_000_000e6;
    uint256 internal constant TRADER_USDC = 100_000e6;
    uint256 internal constant SEED_USDC = 2_500e6;
    uint256 internal constant SEED_MUMB = 2_500e18;
    uint256 internal constant SHIPPED_MUMB = 100_000e18;
    uint256 internal constant SHIPPED_USDC = 100_000e6;
    uint16 internal constant BAND_BPS = 200;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant HALF_RANGE = 600;

    /// @dev Circle's FiatTokenV2_2 keeps `balanceAndBlacklistStates` (address => uint256) at storage slot 9.
    uint256 internal constant USDC_BALANCE_SLOT = 9;

    error UsdcFundingFailed(address who, uint256 want, uint256 got);

    struct Actors {
        address deployer;
        address priya;
        address trader;
    }

    struct Deployed {
        MockMUMB mumb;
        PoolPriceBandExtruction band;
        ConfluenceHook hook;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTest liquidityRouter;
        PoolKey key;
    }

    constructor() StrategyLib(AQUA) {}

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 priyaPk = vm.envUint("PRIYA_PRIVATE_KEY");
        uint256 traderPk = vm.envUint("TRADER_PRIVATE_KEY");
        Actors memory a = Actors(vm.addr(deployerPk), vm.addr(priyaPk), vm.addr(traderPk));
        Deployed memory d;

        // Step 2: USDC is real mainnet USDC, so it is funded by writing the node's storage.
        // Done before any broadcast: it changes the node at once, as `deal` does in a test.
        _fundUsdc(a.priya, PRIYA_USDC);
        _fundUsdc(a.trader, TRADER_USDC);
        _fundUsdc(a.deployer, SEED_USDC);

        // Steps 2 to 5 as the deployer.
        vm.startBroadcast(deployerPk);
        d.mumb = new MockMUMB();
        d.mumb.mint(a.priya, PRIYA_MUMB);
        d.mumb.mint(a.trader, TRADER_MUMB);
        d.mumb.mint(a.deployer, SEED_MUMB);
        d.band = new PoolPriceBandExtruction();
        d.swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        d.liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(POOL_MANAGER));
        d.hook = _deployHook();
        d.key = _createPool(d);
        vm.stopBroadcast();

        // Step 6 and 7 as Priya.
        ISwapVM.Order memory order = _buildOrder(
            a.priya,
            _buildBandProgram(FEE_0_30_PCT, address(d.band), d.band.build(IPoolManager(POOL_MANAGER), d.key, BAND_BPS))
        );
        vm.startBroadcast(priyaPk);
        d.mumb.approve(AQUA, type(uint256).max);
        IERC20(USDC).approve(AQUA, type(uint256).max);
        address[] memory tokens = new address[](2);
        tokens[0] = address(d.mumb);
        tokens[1] = USDC;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_MUMB;
        amounts[1] = SHIPPED_USDC;
        bytes32 strategyHash = IAqua(AQUA).ship(ROUTER, abi.encode(order), tokens, amounts);
        d.hook.registerOrder(d.key, order);
        vm.stopBroadcast();

        // The trader approves the swap router once, so simulations need no override.
        vm.startBroadcast(traderPk);
        IERC20(USDC).approve(address(d.swapRouter), type(uint256).max);
        d.mumb.approve(address(d.swapRouter), type(uint256).max);
        vm.stopBroadcast();

        _writeDeployment(a, d, strategyHash);
    }

    // ---------------------------------------------------------------- steps

    function _fundUsdc(address who, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(who, USDC_BALANCE_SLOT));
        vm.rpc(
            "anvil_setStorageAt",
            string.concat('["', vm.toString(USDC), '","', vm.toString(slot), '","', vm.toString(bytes32(amount)), '"]')
        );
        uint256 got = IERC20(USDC).balanceOf(who);
        if (got != amount) revert UsdcFundingFailed(who, amount, got);
    }

    /// @dev Mines a salt for exactly beforeSwap + beforeSwapReturnDelta. Broadcast CREATE2 goes through the
    /// deterministic factory, so that is the deployer for the address maths.
    function _deployHook() internal returns (ConfluenceHook hook) {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(IPoolManager(POOL_MANAGER), ROUTER);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(ConfluenceHook).creationCode, args);
        hook = new ConfluenceHook{salt: salt}(IPoolManager(POOL_MANAGER), ROUTER);
        require(address(hook) == expected, "Setup: hook address mismatch");
    }

    /// @dev Same pool as PoolBase._createPool: fee 3000, spacing 60, anchor 1 MUMB = 1 USDC, ~6% range seed.
    function _createPool(Deployed memory d) internal returns (PoolKey memory k) {
        bool usdcIsCurrency0 = USDC < address(d.mumb);
        (address c0, address c1) = usdcIsCurrency0 ? (USDC, address(d.mumb)) : (address(d.mumb), USDC);
        k = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(d.hook))
        });

        uint160 sqrtPriceX96 =
            usdcIsCurrency0 ? uint160(FixedPoint96.Q96 * 1e6) : uint160(FixedPoint96.Q96 / 1e6);
        int24 tick = IPoolManager(POOL_MANAGER).initialize(k, sqrtPriceX96);
        int24 centre = (tick / TICK_SPACING) * TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) centre -= TICK_SPACING;
        int24 tickLower = centre - HALF_RANGE;
        int24 tickUpper = centre + HALF_RANGE;

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            usdcIsCurrency0 ? SEED_USDC : SEED_MUMB,
            usdcIsCurrency0 ? SEED_MUMB : SEED_USDC
        );

        // The deployer is the broadcaster here, so it pays the seed.
        IERC20(USDC).approve(address(d.liquidityRouter), type(uint256).max);
        d.mumb.approve(address(d.liquidityRouter), type(uint256).max);
        d.liquidityRouter.modifyLiquidity(
            k,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    // ---------------------------------------------------------------- output

    function _writeDeployment(Actors memory a, Deployed memory d, bytes32 strategyHash) internal {
        string memory poolKeyJson = string.concat(
            '{"currency0":"',
            vm.toString(Currency.unwrap(d.key.currency0)),
            '","currency1":"',
            vm.toString(Currency.unwrap(d.key.currency1)),
            '","fee":',
            vm.toString(uint256(d.key.fee)),
            ',"tickSpacing":',
            vm.toString(uint256(uint24(d.key.tickSpacing))),
            ',"hooks":"',
            vm.toString(address(d.key.hooks)),
            '"}'
        );
        string memory json = string.concat(
            '{"usdc":"',
            vm.toString(USDC),
            '","mumb":"',
            vm.toString(address(d.mumb)),
            '","hook":"',
            vm.toString(address(d.hook)),
            '","swapRouter":"',
            vm.toString(address(d.swapRouter)),
            '","band":"',
            vm.toString(address(d.band)),
            '","maker":"',
            vm.toString(a.priya),
            '","trader":"',
            vm.toString(a.trader),
            '","strategyHash":"',
            vm.toString(strategyHash),
            '","poolKey":',
            poolKeyJson,
            "}"
        );
        vm.writeFile("../deployments/local.json", json);
        console.log("wrote ../deployments/local.json");
        console.log("hook", address(d.hook));
        console.log("swapRouter", address(d.swapRouter));
    }
}
