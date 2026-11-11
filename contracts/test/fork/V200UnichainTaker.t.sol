// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {SwapVM} from "@1inch/swap-vm/src/SwapVM.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {BPS} from "@1inch/swap-vm/src/instructions/Fee.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

import {MockMUMB} from "../../src/mocks/MockMUMB.sol";
import {StrategyLib} from "../base/StrategyLib.sol";
import {TakerHelper} from "../base/TakerHelper.sol";

/// @notice Extruction target that returns the registers unchanged. It stands in for BandGuardV2 in gate G0: it
///         proves a program that ends in an Extruction step fills through the router, without testing any guard.
contract PassThroughExtruction {
    function extruction(bool, uint256 nextPC, SwapQuery calldata, SwapRegisters calldata swap, bytes calldata, bytes calldata)
        external
        pure
        returns (uint256, uint256, SwapRegisters memory)
    {
        return (nextPC, 0, swap);
    }
}

/// @notice V2-00 gate G0. On a Unichain fork, a program shaped like template T1 (flat fee, XYC, Extruction; no KYC
///         opcode) fills through the canonical router with a contract as taker and an empty-handed EOA as tx.origin.
/// @dev Extends `Test`, not `ForkBase`: ForkBase forks Ethereum mainnet and funds mainnet USDC. The pair here is two
///      `MockMUMB` tokens, so no Unichain token address is typed by hand.
contract V200UnichainTakerTest is Test, StrategyLib {
    address internal constant AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    address internal constant ROUTER = 0x111111338c5091E8440b67B168bAe16a668AC0De;
    address internal constant MAINNET_WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    /// @dev OP Stack predeploy, the same address on every OP Stack chain.
    address internal constant UNICHAIN_WETH = 0x4200000000000000000000000000000000000006;

    uint256 internal constant SHIPPED_IN = 100_000e18;
    uint256 internal constant SHIPPED_OUT = 100_000e18;
    uint256 internal constant SWAP_IN = 1_000e18;

    IAqua internal aqua = IAqua(AQUA);
    ISwapVM internal router = ISwapVM(ROUTER);

    MockMUMB internal tokenIn;
    MockMUMB internal tokenOut;
    address internal maker;
    address internal recipient;
    TakerHelper internal helper;
    ISwapVM.Order internal order;
    bytes32 internal strategyHash;
    uint256 internal unichainFork;

    constructor() StrategyLib(AQUA) {}

    function setUp() public {
        unichainFork = vm.createSelectFork(vm.envString("UNICHAIN_RPC_URL"), vm.envUint("UNICHAIN_FORK_BLOCK"));
        assertEq(block.chainid, 130, "not Unichain");

        maker = makeAddr("maker");
        recipient = makeAddr("recipient");

        tokenIn = new MockMUMB();
        tokenOut = new MockMUMB();
        tokenOut.mint(maker, SHIPPED_OUT);

        PassThroughExtruction stub = new PassThroughExtruction();
        order = _buildOrder(maker, _buildBandProgram(FEE_0_30_PCT, address(stub), ""));

        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenIn);
        tokens[1] = address(tokenOut);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SHIPPED_IN;
        amounts[1] = SHIPPED_OUT;

        vm.startPrank(maker);
        tokenIn.approve(AQUA, type(uint256).max);
        tokenOut.approve(AQUA, type(uint256).max);
        strategyHash = aqua.ship(ROUTER, abi.encode(order), tokens, amounts);
        vm.stopPrank();

        helper = new TakerHelper(router);
    }

    /// @dev Fee (rounded up, on input) then XYC (rounded down) on the shipped balances.
    function _expectedOut(uint256 amountIn) internal pure returns (uint256) {
        uint256 net = amountIn - Math.ceilDiv(amountIn * FEE_0_30_PCT, BPS);
        return (net * SHIPPED_OUT) / (SHIPPED_IN + net);
    }

    function _aquaBalance(address token) internal view returns (uint256 balance) {
        (balance,) = aqua.rawBalances(maker, ROUTER, strategyHash, token);
    }

    /// @notice Gate G0. If this fails, stop all V2 work and record the failure in DECISIONS.
    function test_V200_ungatedTakerOnUnichain() public {
        assertGt(ROUTER.code.length, 0, "no router at the pinned address on Unichain");
        assertGt(AQUA.code.length, 0, "no Aqua at the pinned address on Unichain");
        assertEq(address(SwapVM(payable(ROUTER)).AQUA()), AQUA, "router points at a different Aqua");

        tokenIn.mint(address(helper), SWAP_IN);
        uint256 expectedOut = _expectedOut(SWAP_IN);

        // An outside EOA with no tokens starts the transaction. The helper contract is the taker.
        address stranger = makeAddr("stranger");
        assertEq(tokenIn.balanceOf(stranger) + tokenOut.balanceOf(stranger), 0, "stranger holds tokens");

        vm.expectEmit(true, true, true, true, ROUTER);
        emit SwapVM.Swapped(
            strategyHash, maker, address(helper), address(tokenIn), address(tokenOut), SWAP_IN, expectedOut
        );
        vm.prank(stranger, stranger);
        (uint256 amountIn, uint256 amountOut,) =
            helper.swapExactIn(order, address(tokenIn), address(tokenOut), SWAP_IN, expectedOut, recipient);

        assertEq(amountIn, SWAP_IN, "amountIn");
        assertEq(amountOut, expectedOut, "amountOut");
        assertGt(amountOut, 0, "amountOut is zero");

        // Maker wallet: output out, input in. Aqua virtual balances move the same way.
        assertEq(tokenOut.balanceOf(maker), SHIPPED_OUT - amountOut, "maker wallet out-token");
        assertEq(tokenIn.balanceOf(maker), SWAP_IN, "maker wallet in-token");
        assertEq(_aquaBalance(address(tokenOut)), SHIPPED_OUT - amountOut, "virtual out-token");
        assertEq(_aquaBalance(address(tokenIn)), SHIPPED_IN + SWAP_IN, "virtual in-token");

        // The recipient got exactly the output. Nothing is left with the taker, the router or Aqua.
        assertEq(tokenOut.balanceOf(recipient), amountOut, "recipient out-token");
        assertEq(tokenIn.balanceOf(recipient), 0, "recipient in-token");
        assertEq(tokenIn.balanceOf(address(helper)) + tokenOut.balanceOf(address(helper)), 0, "helper holds tokens");
        assertEq(tokenIn.balanceOf(ROUTER) + tokenOut.balanceOf(ROUTER), 0, "router holds tokens");
        assertEq(tokenIn.balanceOf(AQUA) + tokenOut.balanceOf(AQUA), 0, "aqua holds tokens");
        assertEq(tokenIn.allowance(address(helper), ROUTER), 0, "helper allowance to router");

        _assertSameRouterModuloImmutables();
    }

    /// @dev [VERIFY] the router on Unichain is mainnet's router v1.0.2. The two codehashes differ only in three
    ///      32-byte immutables: WETH, the EIP-712 chain id and the EIP-712 domain separator. Swap those in mainnet's
    ///      code for Unichain's values; every other byte must already match, or the hashes differ and this fails.
    function _assertSameRouterModuloImmutables() internal {
        (bytes memory code, bytes memory aquaCode) = _mainnetCode();

        // Aqua has no chain-specific immutables: its code must be byte-identical.
        assertEq(keccak256(AQUA.code), keccak256(aquaCode), "Unichain Aqua code != mainnet Aqua code");

        (, string memory name, string memory version, uint256 chainId, address verifying,,) =
            SwapVM(payable(ROUTER)).eip712Domain();
        assertEq(name, "1inch SwapVM v1.0", "EIP-712 name");
        assertEq(version, "1.0.2", "router version");
        assertEq(chainId, 130, "EIP-712 chain id");
        assertEq(verifying, ROUTER, "EIP-712 verifying contract");

        _swapWord(code, bytes32(uint256(uint160(MAINNET_WETH))), bytes32(uint256(uint160(UNICHAIN_WETH))));
        _swapWord(code, bytes32(uint256(1)), bytes32(uint256(130)));
        _swapWord(code, _domainSeparator(name, version, 1), _domainSeparator(name, version, 130));

        assertEq(keccak256(ROUTER.code), keccak256(code), "Unichain router code != mainnet code modulo immutables");
    }

    function _domainSeparator(string memory name, string memory version, uint256 chainId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                ROUTER
            )
        );
    }

    /// @dev Replaces the one 32-byte word equal to `from` with `to`, in place. Fails unless there is exactly one.
    function _swapWord(bytes memory code, bytes32 from, bytes32 to) internal pure {
        uint256 hits;
        for (uint256 i; i + 32 <= code.length; i++) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(code, 32), i))
            }
            if (word == from) {
                assembly ("memory-safe") {
                    mstore(add(add(code, 32), i), to)
                }
                hits++;
                i += 31;
            }
        }
        require(hits == 1, "immutable word not found exactly once in mainnet router code");
    }

    function _mainnetCode() internal returns (bytes memory routerCode, bytes memory aquaCode) {
        uint256 back = vm.activeFork();
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        assertEq(block.chainid, 1, "not mainnet");
        routerCode = ROUTER.code;
        aquaCode = AQUA.code;
        vm.selectFork(back);
    }
}
