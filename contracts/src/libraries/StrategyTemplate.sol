// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "@1inch/swap-vm/src/libs/MakerTraits.sol";

import {BandGuardArgs} from "../BandGuardV2.sol";

/// @title StrategyTemplate
/// @notice Template T1, the only strategy shape the hook prices (ARCHITECTURE-v2 sections 1 and 5): an optional
///         `_salt`, a flat input fee, the XYC curve, then BandGuardV2. No KYC opcode. The hook rebuilds a maker's order
///         with these functions and asks Aqua whether exactly those bytes were shipped (D-33).
/// @dev Pure. The opcode indices are constants, each proved equal to `AquaOpcodes._opcodes()` by
///      `test_V205_opcodesFromAquaOpcodes` and pinned a second time by the SDK fixture (D-33). Encoding of one
///      instruction is `opcode (1) | args length (1) | args` (SwapVM `ProgramBuilder`).
library StrategyTemplate {
    /// @notice A maker's choices. `salt` 0 leaves the `_salt` step out; any other value (up to 2^64 - 1, the SDK's
    ///         width) makes the same parameters ship as a different strategy.
    struct Params {
        uint32 feeE9;
        uint16 bandBps;
        uint16 driftTicks;
        bool exclusive;
        uint64 salt;
    }

    /// @dev Indices in `AquaOpcodes._opcodes()` of `Controls._salt`, `Fee._flatFeeAmountInXD`,
    ///      `XYCSwap._xycSwapXD` and `Extruction._extruction` (SwapVM v1.0.2).
    uint8 internal constant OP_SALT = 20;
    uint8 internal constant OP_FLAT_FEE = 21;
    uint8 internal constant OP_XYC_SWAP = 17;
    uint8 internal constant OP_EXTRUCTION = 32;

    /// @dev SwapVM's fee scale: 1e9 is 100% (`Fee.sol`). A fee of 100% or more can never fill.
    uint32 internal constant FEE_SCALE = 1_000_000_000;

    /// @dev The fee is 100% or more.
    error InvalidMakerFee(uint32 feeE9);

    /// @notice The program of template T1 for `key`, guarded by `guard`. Reverts `InvalidMakerFee` for a fee of 100% or
    ///         more, and with BandGuardV2's own errors for a band, drift or flags it would refuse (so the template
    ///         accepts exactly what the guard accepts).
    /// @dev `pm` goes into the guard's args, which the guard parses and ignores (D-32). `key.hooks` is the hook that
    ///      registers the strategy; the guard trusts it, so the hook must pass its own key.
    function program(Params memory p, IPoolManager pm, PoolKey memory key, address guard)
        internal
        pure
        returns (bytes memory)
    {
        if (p.feeE9 >= FEE_SCALE) revert InvalidMakerFee(p.feeE9);
        bytes memory args = BandGuardArgs.build(
            pm, key, p.bandBps, p.driftTicks, p.exclusive ? BandGuardArgs.FLAG_EXCLUSIVE : uint8(0)
        );
        bytes memory head = p.salt == 0 ? bytes("") : abi.encodePacked(OP_SALT, uint8(8), p.salt);
        return bytes.concat(
            head,
            abi.encodePacked(OP_FLAT_FEE, uint8(4), p.feeE9),
            abi.encodePacked(OP_XYC_SWAP, uint8(0)),
            abi.encodePacked(OP_EXTRUCTION, uint8(20 + BandGuardArgs.ARGS_LENGTH), guard, args)
        );
    }

    /// @notice An Aqua-mode order: no signature, no hooks, and the maker receives its own input.
    function order(address maker, bytes memory prog) internal pure returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
                receiver: address(0),
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: true,
                allowZeroAmountIn: false,
                hasPreTransferInHook: false,
                hasPostTransferInHook: false,
                hasPreTransferOutHook: false,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(0),
                postTransferInData: "",
                preTransferOutTarget: address(0),
                preTransferOutData: "",
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: prog
            })
        );
    }

    /// @notice The strategy hash Aqua uses: `keccak256(abi.encode(order))`, which is the shipped bytes
    ///         (`SwapVM.hash`, `SwapVM.sol:97-100`).
    function strategyHash(ISwapVM.Order memory o) internal pure returns (bytes32) {
        return keccak256(abi.encode(o));
    }

    /// @notice Ranks a strategy: its per-token depths valued in currency1 at the price of `snapTick`,
    ///         `d0 * price + d1`, with `price = (sqrtPrice / 2^96)^2` applied in two steps, each with a 512-bit mulDiv.
    ///         Saturates at `type(uint256).max` instead of reverting, so two saturated values tie and a tie never
    ///         evicts (D-33).
    function depthValue(uint256 d0, uint256 d1, int24 snapTick) internal pure returns (uint256) {
        uint256 s = TickMath.getSqrtPriceAtTick(snapTick);
        uint256 v0 = _mulShift(_mulShift(d0, s), s);
        (bool ok, uint256 sum) = Math.tryAdd(v0, d1);
        return ok ? sum : type(uint256).max;
    }

    /// @dev `x * s / 2^96`, or the maximum when the result would not fit (`x * s >= 2^352`).
    function _mulShift(uint256 x, uint256 s) private pure returns (uint256) {
        (uint256 high,) = Math.mul512(x, s);
        if (high >> 96 != 0) return type(uint256).max;
        return FullMath.mulDiv(x, s, 2 ** 96);
    }
}
