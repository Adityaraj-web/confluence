// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {AquaOpcodes} from "@1inch/swap-vm/src/opcodes/AquaOpcodes.sol";
import {XYCSwap} from "@1inch/swap-vm/src/instructions/XYCSwap.sol";
import {Fee, FeeArgsBuilder} from "@1inch/swap-vm/src/instructions/Fee.sol";
import {Extruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {MakerTraitsLib} from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import {Program, ProgramBuilder} from "@1inch/swap-vm/test/utils/ProgramBuilder.sol";

/// @notice Builds Priya's program and order for the canonical router's opcode set.
/// @dev A contract, not a library: `_opcodes()` and the instruction pointers are internal to AquaOpcodes, so
///      only a derived contract can reach them (D-15). Opcode indices are looked up, never hard-coded.
abstract contract StrategyLib is AquaOpcodes {
    using ProgramBuilder for Program;

    /// @dev SwapVM's fee scale is 1e9 = 100% (`BPS` in Fee.sol), so this is 0.30%, not 3,000,000 basis points.
    uint32 internal constant FEE_0_30_PCT = 3_000_000;

    constructor(address aqua) AquaOpcodes(aqua) {}

    /// @notice Flat input fee, then the XYC curve. The fee runs the rest of the program inside itself.
    function _buildProgram(uint32 feeE9) internal pure returns (bytes memory) {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeE9)),
            p.build(XYCSwap._xycSwapXD)
        );
    }

    /// @notice Flat input fee, the XYC curve, then the band check. The check runs inside the fee, so on exact input
    ///         it sees the net-of-fee `amountIn` and the final `amountOut` (D-15).
    /// @param target The deployed Extruction target.
    /// @param bandArgs The target's args, from `PoolPriceBandExtruction.build`.
    function _buildBandProgram(uint32 feeE9, address target, bytes memory bandArgs)
        internal
        pure
        returns (bytes memory)
    {
        Program memory p = ProgramBuilder.init(_opcodes());
        return bytes.concat(
            p.build(Fee._flatFeeAmountInXD, FeeArgsBuilder.buildFlatFee(feeE9)),
            p.build(XYCSwap._xycSwapXD),
            p.build(Extruction._extruction, abi.encodePacked(target, bandArgs))
        );
    }

    /// @notice An Aqua-mode order: no signature, no hooks, and the maker receives her own input.
    function _buildOrder(address maker, bytes memory program) internal pure returns (ISwapVM.Order memory) {
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
                program: program
            })
        );
    }
}
