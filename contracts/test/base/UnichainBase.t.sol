// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {ConfluenceHook} from "../../src/ConfluenceHook.sol";
import {ConfluenceSplitter} from "../../src/ConfluenceSplitter.sol";
import {ConfluenceSplitterOut} from "../../src/ConfluenceSplitterOut.sol";
import {MockMUMB} from "../../src/mocks/MockMUMB.sol";
import {StrategyLib} from "./StrategyLib.sol";

/// @notice V2-05's Unichain fixture, moved verbatim out of `V205UnichainTest` so V2-07 can reuse it: a fork of Unichain
///         (130), the v2 hook (with its splitter, V2-07) on the real v4 PoolManager, a pool of two mock tokens at
///         price 1 with liquidity over ticks -600..600, and a first swap that records the snapshot (tick 0).
abstract contract UnichainBase is Test, StrategyLib {
    address internal constant AQUA_ADDR = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant ROUTER_ADDR = 0x111111338c5091E8440b67B168bAe16a668AC0De;
    /// @dev Uniswap v4 PoolManager on Unichain (not the mainnet address).
    address internal constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    ConfluenceHook internal hook;
    IPoolManager internal manager;
    MockMUMB internal t0;
    MockMUMB internal t1;
    PoolKey internal key;
    address internal maker;

    constructor() StrategyLib(AQUA_ADDR) {}

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_URL"), vm.envUint("UNICHAIN_FORK_BLOCK"));
        assertEq(block.chainid, 130, "not Unichain");
        manager = IPoolManager(UNICHAIN_POOL_MANAGER);
        assertGt(address(manager).code.length, 0, "no PoolManager");

        (MockMUMB a, MockMUMB b) = (new MockMUMB(), new MockMUMB());
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        maker = makeAddr("maker");

        ConfluenceSplitter splitter = new ConfluenceSplitter();
        ConfluenceSplitterOut splitterOut = new ConfluenceSplitterOut();
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        bytes memory args = abi.encode(manager, splitter, splitterOut);
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, type(ConfluenceHook).creationCode, args);
        hook = new ConfluenceHook{salt: salt}(manager, splitter, splitterOut);
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
            IPoolManager.ModifyLiquidityParams({
                tickLower: -600, tickUpper: 600, liquidityDelta: 1e19, salt: bytes32(0)
            }),
            ""
        );
        sr.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
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
