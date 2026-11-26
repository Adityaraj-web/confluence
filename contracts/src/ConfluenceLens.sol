// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ConfluenceLens (V2-09 STUB: the real ABI, zero results; red tests run against this)
contract ConfluenceLens {
    /// @notice One registry slot's part in a quoted swap.
    struct LegQuote {
        address maker;
        bytes32 strategyHash;
        uint256 amountIn;
        uint256 amountOut;
        uint8 status;
    }

    /// @notice A quote with its reasons.
    struct Breakdown {
        bool exactIn;
        uint256 totalIn;
        uint256 totalOut;
        uint256 poolIn;
        uint256 poolOut;
        uint256 poolOnlyIn;
        uint256 poolOnlyOut;
        bool poolExact;
        bool poolOnlyExact;
        int256 gainBps;
        int24 snapTick;
        int56 emaTickX;
        bool anchorFresh;
        uint8 planCode;
        uint256 minHookGas;
        LegQuote[] legs;
    }

    /// @notice One direction of a maker's limits, in input units (exact input) and output units (exact output).
    struct Side {
        uint8 statusIn;
        uint256 minIn;
        uint256 maxIn;
        uint8 statusOut;
        uint256 minOut;
        uint256 maxOut;
    }

    /// @notice A registered maker's limits in both directions.
    struct MakerLimit {
        address maker;
        bytes32 strategyHash;
        Side zeroForOne;
        Side oneForZero;
    }

    /// @notice The quote of a swap on `key`. Stub: returns zeros.
    function quote(PoolKey calldata, bool, int256) external view returns (Breakdown memory b) {
        return b;
    }

    /// @notice The registered makers' limits on `key`. Stub: returns nothing.
    function makerLimits(PoolKey calldata) external view returns (MakerLimit[] memory m) {
        return m;
    }
}
