// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IExtruction, IStaticExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

/// @dev The args are not exactly 91 bytes.
error InvalidArgsLength(uint256 length);
/// @dev `bandBps` is 0 or above 10,000.
error InvalidBand();
/// @dev `driftTicks` is above `MAX_DRIFT_TICKS`.
error InvalidDrift();
/// @dev A flag bit other than bit 0 is set.
error InvalidFlags(uint8 flags);
/// @dev The swap's tokens are not the pool's two currencies.
error PoolTokenMismatch();
/// @dev The strategy is exclusive and the taker is not the pool's hook.
error TakerNotHook(address taker);
/// @dev The snapshot and the EMA are more than `driftTicks` apart. `emaTickX` is the EMA times 2^16.
error AnchorDrift(int24 snapTick, int56 emaTickX, uint16 driftTicks);
/// @dev A register is still zero: the step runs before the curve.
error BandNotComputed();
/// @dev The execution price is outside the band around the snapshot price. Both prices are currency1 per currency0
///      in one scale: X192 (price times 2^192) when the snapshot's sqrt price is below 2^127, else X96.
error BandExceeded(uint256 execX, uint256 refX, uint16 bandBps);

/// @notice The part of `ConfluenceHook` the guard reads: the anchor, unrounded.
interface IConfluenceAnchor {
    /// @notice The pool's block-start snapshot tick and its EMA times 2^16. Reverts for a pool with no price.
    function anchorOfX(PoolId poolId) external view returns (int24 snapTick, int56 emaTickX, bool fresh);
}

/// @title BandGuardArgs
/// @notice Encoding of BandGuardV2's 91-byte args, for the guard and for the strategy template (V2-05).
/// @dev Layout, packed: poolManager (20) | currency0 (20) | currency1 (20) | fee (3) | tickSpacing (3) | hooks (20) |
///      bandBps (2) | driftTicks (2) | flags (1). v1's 88 bytes plus `driftTicks` and `flags`. The guard does not read
///      `poolManager`; it reads the anchor from `hooks` (D-32).
library BandGuardArgs {
    uint256 internal constant ARGS_LENGTH = 91;
    uint16 internal constant MAX_BAND_BPS = 10_000;
    /// @dev One unit is one tick (a price factor of 1.0001), not a basis point (D-32).
    uint16 internal constant MAX_DRIFT_TICKS = 10_000;
    uint8 internal constant FLAG_EXCLUSIVE = 1;

    struct Args {
        IPoolManager poolManager;
        PoolKey key;
        uint16 bandBps;
        uint16 driftTicks;
        uint8 flags;
    }

    /// @dev Reverts on a band, drift or flags that could never be valid.
    function build(IPoolManager poolManager, PoolKey memory key, uint16 bandBps, uint16 driftTicks, uint8 flags)
        internal
        pure
        returns (bytes memory)
    {
        _validate(bandBps, driftTicks, flags);
        return abi.encodePacked(
            poolManager, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks, bandBps, driftTicks, flags
        );
    }

    /// @dev Reverts on the wrong length, or an invalid band, drift or flags.
    function parse(bytes calldata args) internal pure returns (Args memory a) {
        if (args.length != ARGS_LENGTH) revert InvalidArgsLength(args.length);
        a.bandBps = uint16(bytes2(args[86:88]));
        a.driftTicks = uint16(bytes2(args[88:90]));
        a.flags = uint8(args[90]);
        _validate(a.bandBps, a.driftTicks, a.flags);
        a.poolManager = IPoolManager(address(bytes20(args[0:20])));
        a.key = PoolKey({
            currency0: Currency.wrap(address(bytes20(args[20:40]))),
            currency1: Currency.wrap(address(bytes20(args[40:60]))),
            fee: uint24(bytes3(args[60:63])),
            tickSpacing: int24(uint24(bytes3(args[63:66]))),
            hooks: IHooks(address(bytes20(args[66:86])))
        });
    }

    function _validate(uint16 bandBps, uint16 driftTicks, uint8 flags) private pure {
        if (bandBps == 0 || bandBps > MAX_BAND_BPS) revert InvalidBand();
        if (driftTicks > MAX_DRIFT_TICKS) revert InvalidDrift();
        if (flags & ~FLAG_EXCLUSIVE != 0) revert InvalidFlags(flags);
    }
}

/// @title BandGuardV2
/// @notice The maker's own guard, an Extruction target that runs inside the maker's SwapVM program. It checks a fill
///         against the hook's anchor instead of spot: the execution price must be within `bandBps` of the block-start
///         snapshot price, and the snapshot must be within `driftTicks` of the EMA. Optionally only the pool's hook may
///         take. Stateless and non-upgradeable: no storage, no owner; one `view` function serves quote and swap, and it
///         reverts or returns the registers unchanged.
/// @dev Check order: args, tokens match the key, exclusive taker, anchor read from `key.hooks` (never spot, never a
///      bare pool id), drift, registers computed, band. A revert of the anchor read (`PoolNotInitialized`, no code at
///      `hooks`) propagates, so the fill fails and the hook's pool fills that share.
contract BandGuardV2 is IExtruction, IStaticExtruction {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant Q96 = 2 ** 96;
    /// @dev The EMA's fixed point: ticks times 2^16 (AnchorLib).
    int256 private constant TICK_SCALE = 2 ** 16;
    /// @dev Below this sqrt price the reference is `s * s` exactly (X192, under 2^254); at or above it, X96.
    uint256 private constant X192_SQRT_LIMIT = 2 ** 127;

    /// @notice Check a fill. Called by a SwapVM router running a maker's program; anyone may call.
    /// @dev Inside a flat fee, `swap.amountIn` is net of the fee, so this checks the maker's curve price (D-15).
    ///      Writes no amounts, consumes no taker data and never jumps.
    function extruction(
        bool, /* isStaticContext */
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata /* takerData */
    ) external view override(IExtruction, IStaticExtruction) returns (uint256, uint256, SwapRegisters memory) {
        BandGuardArgs.Args memory a = BandGuardArgs.parse(args);

        address currency0 = Currency.unwrap(a.key.currency0);
        address currency1 = Currency.unwrap(a.key.currency1);
        bool isToken0In = query.tokenIn == currency0 && query.tokenOut == currency1;
        if (!isToken0In && !(query.tokenIn == currency1 && query.tokenOut == currency0)) revert PoolTokenMismatch();

        address hooks = address(a.key.hooks);
        if (a.flags & BandGuardArgs.FLAG_EXCLUSIVE != 0 && query.taker != hooks) revert TakerNotHook(query.taker);

        (int24 snapTick, int56 emaTickX,) = IConfluenceAnchor(hooks).anchorOfX(a.key.toId());
        _checkDrift(snapTick, emaTickX, a.driftTicks);

        // Before the price maths, which divides by one of these.
        if (swap.amountIn == 0 || swap.amountOut == 0) revert BandNotComputed();
        _checkBand(snapTick, isToken0In, swap.amountIn, swap.amountOut, a.bandBps);

        return (nextPC, 0, swap);
    }

    /// @notice Encode the 91-byte args for a strategy. Reverts on a band, drift or flags that could never be valid.
    ///         Anyone may call.
    function build(IPoolManager poolManager, PoolKey calldata key, uint16 bandBps, uint16 driftTicks, uint8 flags)
        external
        pure
        returns (bytes memory)
    {
        return BandGuardArgs.build(poolManager, key, bandBps, driftTicks, flags);
    }

    /// @notice Decode the 91-byte args. Reverts on the wrong length or an invalid field. Anyone may call.
    function parse(bytes calldata args)
        external
        pure
        returns (IPoolManager poolManager, PoolKey memory key, uint16 bandBps, uint16 driftTicks, uint8 flags)
    {
        BandGuardArgs.Args memory a = BandGuardArgs.parse(args);
        return (a.poolManager, a.key, a.bandBps, a.driftTicks, a.flags);
    }

    /// @dev `|snap * 2^16 - emaTickX| <= driftTicks * 2^16`, in fixed point: the rounded EMA tick never decides.
    function _checkDrift(int24 snapTick, int56 emaTickX, uint16 driftTicks) private pure {
        int256 gap = int256(snapTick) * TICK_SCALE - int256(emaTickX);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 distance = uint256(gap < 0 ? -gap : gap);
        if (distance > uint256(driftTicks) * uint256(TICK_SCALE)) revert AnchorDrift(snapTick, emaTickX, driftTicks);
    }

    /// @dev Both prices are currency1 per currency0 in one scale (see `BandExceeded`): at least 64 bits of precision at
    ///      every tick. The comparison is `diff > ref * bandBps / 10_000`, as v1 (D-16), which cannot overflow.
    function _checkBand(int24 snapTick, bool isToken0In, uint256 amountIn, uint256 amountOut, uint16 bandBps)
        private
        pure
    {
        uint256 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(snapTick);
        uint256 shift;
        uint256 refX;
        if (sqrtPriceX96 < X192_SQRT_LIMIT) {
            shift = 192;
            refX = sqrtPriceX96 * sqrtPriceX96;
        } else {
            shift = 96;
            refX = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        }

        (uint256 num, uint256 den) = isToken0In ? (amountOut, amountIn) : (amountIn, amountOut);
        uint256 execX;
        // `num * 2^shift / den >= 2^256` iff `num >> (256 - shift) >= den`. Such a price is above twice the
        // reference (which is below 2^255), so it is outside any band: saturate instead of overflowing.
        if ((num >> (256 - shift)) >= den) execX = type(uint256).max;
        else execX = FullMath.mulDiv(num, 1 << shift, den);

        uint256 diff = execX > refX ? execX - refX : refX - execX;
        if (diff > FullMath.mulDiv(refX, bandBps, BPS_DENOMINATOR)) revert BandExceeded(execX, refX, bandBps);
    }
}
