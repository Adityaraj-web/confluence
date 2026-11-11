// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IExtruction, IStaticExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

/// @title PoolPriceBandExtruction
/// @notice Stateless Extruction target: refuses an Aqua fill priced more than `bandBps` away from a v4 pool's live
///         price. One `view` function serves both `quote()` (STATICCALL) and `swap()` (CALL).
/// @dev Args layout, packed, 88 bytes:
///      poolManager (20) | currency0 (20) | currency1 (20) | fee (3) | tickSpacing (3) | hooks (20) | bandBps (2)
contract PoolPriceBandExtruction is IExtruction, IStaticExtruction {
    using StateLibrary for IPoolManager;

    /// @dev The swap's tokens are not the pool's two currencies.
    error PoolTokenMismatch();
    /// @dev The named pool's `sqrtPriceX96` is zero.
    error PoolNotInitialized();
    /// @dev A register is still zero: the step runs before the curve.
    error PoolPriceBandNotComputed();
    /// @dev The execution price is outside the band around the pool price.
    error PoolPriceBandExceeded(uint256 execX96, uint256 poolX96, uint16 bandBps);
    /// @dev `bandBps` is 0 or above 10,000.
    error InvalidBand();
    /// @dev The args are not exactly 88 bytes.
    error InvalidArgsLength(uint256 length);

    uint256 private constant ARGS_LENGTH = 88;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant Q96 = 2 ** 96;

    /// @notice Check a fill against the band. Called by a SwapVM router running a maker's program; anyone may call.
    /// @dev Inside a flat fee, `swap.amountIn` is net of the fee, so this checks the maker's curve price (D-15).
    ///      Reverts or returns the registers unchanged: it writes no amounts, consumes no taker data and never jumps.
    function extruction(
        bool, /* isStaticContext */
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata /* takerData */
    ) external view override(IExtruction, IStaticExtruction) returns (uint256, uint256, SwapRegisters memory) {
        (IPoolManager poolManager, PoolKey memory key, uint16 bandBps) = parse(args);

        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        bool isToken0In = query.tokenIn == currency0 && query.tokenOut == currency1;
        bool isToken1In = query.tokenIn == currency1 && query.tokenOut == currency0;
        if (!isToken0In && !isToken1In) revert PoolTokenMismatch();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Before the price maths, which divides by one of these.
        if (swap.amountIn == 0 || swap.amountOut == 0) revert PoolPriceBandNotComputed();

        // Both prices are currency1 per currency0.
        uint256 poolX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        uint256 execX96 = isToken0In
            ? FullMath.mulDiv(swap.amountOut, Q96, swap.amountIn)
            : FullMath.mulDiv(swap.amountIn, Q96, swap.amountOut);

        // Same result for integers as `diff * 10_000 > bandBps * poolX96`, but `diff` may be near 2^256.
        uint256 diff = execX96 > poolX96 ? execX96 - poolX96 : poolX96 - execX96;
        if (diff > FullMath.mulDiv(poolX96, bandBps, BPS_DENOMINATOR)) {
            revert PoolPriceBandExceeded(execX96, poolX96, bandBps);
        }

        return (nextPC, 0, swap);
    }

    /// @notice Encode the 88-byte args for a strategy. Reverts on a band that could never be valid. Anyone may call.
    function build(IPoolManager poolManager, PoolKey calldata key, uint16 bandBps)
        external
        pure
        returns (bytes memory)
    {
        _requireValidBand(bandBps);
        return abi.encodePacked(poolManager, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks, bandBps);
    }

    /// @notice Decode the 88-byte args. Reverts on the wrong length or an invalid band. Anyone may call.
    function parse(bytes calldata args)
        public
        pure
        returns (IPoolManager poolManager, PoolKey memory key, uint16 bandBps)
    {
        if (args.length != ARGS_LENGTH) revert InvalidArgsLength(args.length);

        bandBps = uint16(bytes2(args[86:88]));
        _requireValidBand(bandBps);

        poolManager = IPoolManager(address(bytes20(args[0:20])));
        key = PoolKey({
            currency0: Currency.wrap(address(bytes20(args[20:40]))),
            currency1: Currency.wrap(address(bytes20(args[40:60]))),
            fee: uint24(bytes3(args[60:63])),
            tickSpacing: int24(uint24(bytes3(args[63:66]))),
            hooks: IHooks(address(bytes20(args[66:86])))
        });
    }

    function _requireValidBand(uint16 bandBps) private pure {
        if (bandBps == 0 || bandBps > BPS_DENOMINATOR) revert InvalidBand();
    }
}
