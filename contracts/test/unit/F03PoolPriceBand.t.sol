// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

import {PoolPriceBandExtruction} from "../../src/v1/PoolPriceBandExtruction.sol";

/// @notice Answers `extsload` with a price for one pool's storage slot and zero for any other, like an uninitialised
///         pool on the real PoolManager. A band that derives the wrong pool id therefore reads zero.
contract StubPoolManager {
    bytes32 internal poolSlot;
    bytes32 internal slot0;

    function setPoolSlot(bytes32 slot) external {
        poolSlot = slot;
    }

    function setSqrtPrice(uint160 sqrtPriceX96) external {
        slot0 = bytes32(uint256(sqrtPriceX96));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slot == poolSlot ? slot0 : bytes32(0);
    }
}

/// @notice F03: the band's args and price maths, with no fork and no router.
contract F03PoolPriceBandTest is Test {
    uint256 internal constant Q96 = 2 ** 96;
    uint16 internal constant BAND_BPS = 200;
    uint256 internal constant NEXT_PC = 123;

    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    address internal constant OTHER_TOKEN = address(0x3000);

    /// @dev Every key field differs from the fork tests' pools and from a zero value, so none can be assumed.
    uint24 internal constant LP_FEE = 500;
    int24 internal constant TICK_SPACING = 10;
    address internal constant HOOKS = address(0x4000);

    PoolPriceBandExtruction internal band;
    StubPoolManager internal stub;
    PoolKey internal key;
    bytes internal validArgs;

    function setUp() public {
        band = new PoolPriceBandExtruction();
        stub = new StubPoolManager();
        key = PoolKey(Currency.wrap(TOKEN0), Currency.wrap(TOKEN1), LP_FEE, TICK_SPACING, IHooks(HOOKS));
        // Hand-packed, so a broken `build` cannot hide behind these fixtures.
        validArgs = _packArgs(BAND_BPS);
        stub.setPoolSlot(_poolSlot(key));
        stub.setSqrtPrice(uint160(Q96));
    }

    function _packArgs(uint16 bandBps) internal view returns (bytes memory) {
        return abi.encodePacked(address(stub), TOKEN0, TOKEN1, LP_FEE, TICK_SPACING, HOOKS, bandBps);
    }

    /// @dev Where the real PoolManager keeps this pool's `slot0` (StateLibrary `_getPoolStateSlot`).
    function _poolSlot(PoolKey memory k) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(PoolId.unwrap(k.toId()), StateLibrary.POOLS_SLOT));
    }

    /// @dev Runs the check with `tokenIn` as the input and the given registers.
    function _extruction(address tokenIn, uint256 amountIn, uint256 amountOut, bytes memory args, bool isStatic)
        internal
        view
        returns (uint256, uint256, SwapRegisters memory)
    {
        address tokenOut = tokenIn == TOKEN0 ? TOKEN1 : TOKEN0;
        SwapQuery memory query = SwapQuery(bytes32(uint256(1)), address(1), address(2), tokenIn, tokenOut, true);
        SwapRegisters memory regs = SwapRegisters(11, 22, amountIn, amountOut, 33);
        return band.extruction(isStatic, NEXT_PC, query, regs, args, hex"abcd");
    }

    function _assertPasses(address tokenIn, uint256 amountIn, uint256 amountOut, bytes memory args) internal view {
        bool[2] memory contexts = [false, true];
        for (uint256 i = 0; i < contexts.length; i++) {
            (uint256 nextPC, uint256 chopped, SwapRegisters memory r) =
                _extruction(tokenIn, amountIn, amountOut, args, contexts[i]);
            assertEq(nextPC, NEXT_PC, "nextPC changed");
            assertEq(chopped, 0, "taker data consumed");
            assertEq(r.balanceIn, 11, "balanceIn changed");
            assertEq(r.balanceOut, 22, "balanceOut changed");
            assertEq(r.amountIn, amountIn, "amountIn changed");
            assertEq(r.amountOut, amountOut, "amountOut changed");
            assertEq(r.amountNetPulled, 33, "amountNetPulled changed");
        }
    }

    function _expectExceeded(uint256 execX96, uint256 poolX96, uint16 bandBps) internal {
        vm.expectRevert(
            abi.encodeWithSelector(PoolPriceBandExtruction.PoolPriceBandExceeded.selector, execX96, poolX96, bandBps)
        );
    }

    function _expectTokenMismatch(address tokenIn, address tokenOut) internal {
        vm.expectRevert(PoolPriceBandExtruction.PoolTokenMismatch.selector);
        band.extruction(
            false,
            NEXT_PC,
            SwapQuery(bytes32(0), address(1), address(2), tokenIn, tokenOut, true),
            SwapRegisters(0, 0, Q96, Q96, 0),
            validArgs,
            ""
        );
    }

    function test_F03_buildParseRoundTripFuzz(
        address manager,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint16 bandBps
    ) public view {
        bandBps = uint16(bound(bandBps, 1, 10_000));
        PoolKey memory fuzzKey =
            PoolKey(Currency.wrap(currency0), Currency.wrap(currency1), fee, tickSpacing, IHooks(hooks));
        _assertRoundTrip(manager, fuzzKey, bandBps);
    }

    function test_F03_buildParseRoundTrip() public view {
        _assertRoundTrip(address(stub), key, BAND_BPS);
    }

    function _assertRoundTrip(address manager, PoolKey memory k, uint16 bandBps) internal view {
        bytes memory args = band.build(IPoolManager(manager), k, bandBps);
        assertEq(args.length, 88, "args length");
        assertEq(
            args,
            abi.encodePacked(manager, k.currency0, k.currency1, k.fee, k.tickSpacing, k.hooks, bandBps),
            "args layout"
        );

        (IPoolManager parsedManager, PoolKey memory parsed, uint16 parsedBand) = band.parse(args);
        assertEq(address(parsedManager), manager, "manager");
        assertEq(Currency.unwrap(parsed.currency0), Currency.unwrap(k.currency0), "currency0");
        assertEq(Currency.unwrap(parsed.currency1), Currency.unwrap(k.currency1), "currency1");
        assertEq(parsed.fee, k.fee, "fee");
        assertEq(parsed.tickSpacing, k.tickSpacing, "tickSpacing");
        assertEq(address(parsed.hooks), address(k.hooks), "hooks");
        assertEq(parsedBand, bandBps, "bandBps");
    }

    function test_F03_invalidBandReverts() public {
        uint16[2] memory invalid = [0, 10_001];
        for (uint256 i = 0; i < invalid.length; i++) {
            vm.expectRevert(PoolPriceBandExtruction.InvalidBand.selector);
            band.build(IPoolManager(address(stub)), key, invalid[i]);

            bytes memory args = _packArgs(invalid[i]);

            vm.expectRevert(PoolPriceBandExtruction.InvalidBand.selector);
            band.parse(args);

            // The strategy bytes can be hand-built, so the check itself must also refuse them.
            vm.expectRevert(PoolPriceBandExtruction.InvalidBand.selector);
            _extruction(TOKEN0, Q96, Q96, args, false);
        }

        // 1 and 10,000 are the ends of the valid range, for every entry point.
        uint16[2] memory valid = [1, 10_000];
        for (uint256 i = 0; i < valid.length; i++) {
            assertEq(band.build(IPoolManager(address(stub)), key, valid[i]).length, 88, "build at range end");

            bytes memory args = _packArgs(valid[i]);
            (,, uint16 parsedBand) = band.parse(args);
            assertEq(parsedBand, valid[i], "parse at range end");
            _assertPasses(TOKEN0, Q96, Q96, args);
        }
    }

    function test_F03_invalidArgsLengthReverts() public {
        bytes[3] memory malformed = [bytes(""), _slice(validArgs, 87), bytes.concat(validArgs, hex"00")];
        for (uint256 i = 0; i < malformed.length; i++) {
            bytes memory expected =
                abi.encodeWithSelector(PoolPriceBandExtruction.InvalidArgsLength.selector, malformed[i].length);

            vm.expectRevert(expected);
            band.parse(malformed[i]);

            vm.expectRevert(expected);
            _extruction(TOKEN0, Q96, Q96, malformed[i], false);
        }
    }

    function _slice(bytes memory data, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = data[i];
        }
    }

    function test_F03_tokenMismatchUnit() public {
        // A valid currency0 on one side.
        _expectTokenMismatch(OTHER_TOKEN, TOKEN1);
        _expectTokenMismatch(TOKEN0, OTHER_TOKEN);
        // A valid currency1 on one side.
        _expectTokenMismatch(OTHER_TOKEN, TOKEN0);
        _expectTokenMismatch(TOKEN1, OTHER_TOKEN);
        // One pool token named twice is not a swap between the pool's two currencies.
        _expectTokenMismatch(TOKEN0, TOKEN0);
        _expectTokenMismatch(TOKEN1, TOKEN1);
    }

    function test_F03_poolNotInitializedReverts() public {
        stub.setSqrtPrice(0);
        vm.expectRevert(PoolPriceBandExtruction.PoolNotInitialized.selector);
        _extruction(TOKEN0, Q96, Q96, validArgs, false);
    }

    /// @dev Only the exact key's slot holds a price, so ignoring any one field reads an uninitialised pool.
    function test_F03_poolIdUsesEveryKeyField() public {
        _assertPasses(TOKEN0, Q96, Q96, validArgs);

        bytes memory otherFee = abi.encodePacked(address(stub), TOKEN0, TOKEN1, LP_FEE + 1, TICK_SPACING, HOOKS, BAND_BPS);
        bytes memory otherSpacing =
            abi.encodePacked(address(stub), TOKEN0, TOKEN1, LP_FEE, TICK_SPACING + 1, HOOKS, BAND_BPS);
        bytes memory otherHooks =
            abi.encodePacked(address(stub), TOKEN0, TOKEN1, LP_FEE, TICK_SPACING, address(0), BAND_BPS);

        bytes[3] memory others = [otherFee, otherSpacing, otherHooks];
        for (uint256 i = 0; i < others.length; i++) {
            vm.expectRevert(PoolPriceBandExtruction.PoolNotInitialized.selector);
            _extruction(TOKEN0, Q96, Q96, others[i], false);
        }
    }

    /// @dev Zero registers revert by name in both orientations, so neither one reaches a division by zero.
    function test_F03_zeroAmountsNotComputed() public {
        address[2] memory inputs = [TOKEN0, TOKEN1];
        for (uint256 i = 0; i < inputs.length; i++) {
            vm.expectRevert(PoolPriceBandExtruction.PoolPriceBandNotComputed.selector);
            _extruction(inputs[i], Q96, 0, validArgs, false);

            vm.expectRevert(PoolPriceBandExtruction.PoolPriceBandNotComputed.selector);
            _extruction(inputs[i], 0, Q96, validArgs, false);
        }
    }

    function test_F03_bandBoundary() public {
        _assertBoundary(BAND_BPS);
        // The width comes from the strategy bytes, not from a default.
        _assertBoundary(50);
    }

    /// @dev With the other register at Q96, the exec price equals the register under test, so it hits the edge exactly.
    function _assertBoundary(uint16 bandBps) internal {
        bytes memory args = _packArgs(bandBps);
        uint256 limit = FullMath.mulDiv(Q96, bandBps, 10_000);
        uint256 upper = Q96 + limit;
        uint256 lower = Q96 - limit;

        // tokenIn == currency0: exec = amountOut / amountIn.
        _assertPasses(TOKEN0, Q96, Q96, args);
        _assertPasses(TOKEN0, Q96, upper, args);
        _assertPasses(TOKEN0, Q96, lower, args);
        _expectExceeded(upper + 1, Q96, bandBps);
        _extruction(TOKEN0, Q96, upper + 1, args, false);
        _expectExceeded(lower - 1, Q96, bandBps);
        _extruction(TOKEN0, Q96, lower - 1, args, false);

        // tokenIn == currency1: exec = amountIn / amountOut.
        _assertPasses(TOKEN1, upper, Q96, args);
        _assertPasses(TOKEN1, lower, Q96, args);
        _expectExceeded(upper + 1, Q96, bandBps);
        _extruction(TOKEN1, upper + 1, Q96, args, false);
        _expectExceeded(lower - 1, Q96, bandBps);
        _extruction(TOKEN1, lower - 1, Q96, args, false);
    }

    function test_F03_priceMathAtSqrtBounds() public {
        // Top of the price range: the pool price is close to 2^224.
        uint160 maxSqrt = TickMath.MAX_SQRT_PRICE - 1;
        uint256 poolAtMax = FullMath.mulDiv(maxSqrt, maxSqrt, Q96);
        stub.setSqrtPrice(maxSqrt);
        _assertPasses(TOKEN0, Q96, poolAtMax, validArgs);

        // An exec price near 2^256 still reverts by name; it must not overflow into a panic.
        _expectExceeded(type(uint256).max, poolAtMax, BAND_BPS);
        _extruction(TOKEN0, Q96, type(uint256).max, validArgs, false);

        // Bottom of the range: the pool price rounds down to zero, and any non-zero exec price is refused.
        stub.setSqrtPrice(TickMath.MIN_SQRT_PRICE);
        assertEq(FullMath.mulDiv(TickMath.MIN_SQRT_PRICE, TickMath.MIN_SQRT_PRICE, Q96), 0, "pool price rounds to 0");
        _expectExceeded(1, 0, BAND_BPS);
        _extruction(TOKEN0, Q96, 1, validArgs, false);
    }
}
