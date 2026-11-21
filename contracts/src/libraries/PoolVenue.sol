// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {SplitMath} from "./SplitMath.sol";

/// @title PoolVenue
/// @notice SKELETON (V2-02 red commit): the interface only; every function returns empty or zero.
library PoolVenue {
    uint256 internal constant MAX_TICK_RANGES = SplitMath.MAX_SEGMENTS;
    uint256 internal constant MAX_TICK_STEPS = 16;

    struct Segment {
        uint160 sqrtPriceStartX96;
        uint160 sqrtPriceEndX96;
        uint128 liquidity;
        uint256 x;
        uint256 y;
        uint256 capIn;
        uint256 capOut;
    }

    struct Pool {
        bool zeroForOne;
        uint24 swapFee;
        bool truncated;
        Segment[] segments;
    }

    function read(IPoolManager, PoolId, int24, bool zeroForOne, uint160) internal view returns (Pool memory p) {
        p.zeroForOne = zeroForOne;
    }

    function segment(uint160, uint160, uint128, uint24, bool) internal pure returns (Segment memory s) {}

    function nextInWord(uint256, int24, int24, bool) internal pure returns (int24 next, bool initialized) {}

    function venues(Pool memory, bool) internal pure returns (SplitMath.Venue[] memory v) {}

    function quoteExactIn(Pool memory, uint256)
        internal
        pure
        returns (uint256 amountOut, uint256 amountInUsed, uint256 touched)
    {}

    function quoteExactOut(Pool memory, uint256)
        internal
        pure
        returns (uint256 amountIn, uint256 amountOutGiven, uint256 touched)
    {}
}
