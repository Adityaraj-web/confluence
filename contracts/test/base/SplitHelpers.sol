// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SplitMath} from "../../src/libraries/SplitMath.sol";

/// @notice Pricing and fuzz-generator helpers shared by the SplitMath (V2-01) and PoolVenue (V2-02) tests.
/// @dev Moved verbatim from `V201SplitMath.t.sol` (V2-02, D-30). Test-only.
abstract contract SplitHelpers {
    uint256 internal constant E9 = 1e9;

    /// @dev SwapVM exact in: flat fee rounded up on the input, then XYC rounded down (Fee.sol:89, XYCSwap.sol:22).
    function _cpOutInt(SplitMath.Venue memory v, uint256 a) internal pure returns (uint256) {
        uint256 net = a - Math.ceilDiv(a * v.feeE9, E9);
        return FullMath.mulDiv(net, v.y, v.x + net);
    }

    /// @dev SwapVM exact out: XYC input rounded up, then the fee grossed up, rounded up (XYCSwap.sol:28, Fee.sol:95).
    function _cpInInt(SplitMath.Venue memory v, uint256 b) internal pure returns (uint256) {
        uint256 net = FullMath.mulDivRoundingUp(b, v.x, v.y - b);
        return FullMath.mulDivRoundingUp(net, E9, E9 - v.feeE9);
    }

    /// @dev Exact curve output, one floor: floor(y g a / (x 1e9 + g a)).
    function _outFloor(SplitMath.Venue memory v, uint256 a) internal pure returns (uint256) {
        if (a == 0) return 0;
        uint256 g = E9 - v.feeE9;
        return FullMath.mulDiv(v.y * g, a, v.x * E9 + g * a);
    }

    /// @dev Exact curve input, one ceil: ceil(x 1e9 b / (g (y - b))).
    function _inCeil(SplitMath.Venue memory v, uint256 b) internal pure returns (uint256) {
        if (b == 0) return 0;
        uint256 g = E9 - v.feeE9;
        return FullMath.mulDivRoundingUp(v.x * E9, b, g * (v.y - b));
    }

    /// @dev A value in [lo, hi] whose bit length is uniform over the range's bit lengths.
    function _logUniform(uint256 w, uint256 lo, uint256 hi) internal pure returns (uint256 r) {
        if (hi <= lo) return lo;
        uint256 loBits = Math.log2(lo);
        uint256 hiBits = Math.log2(hi);
        uint256 bits = loBits + w % (hiBits - loBits + 1);
        uint256 mantissa = uint256(keccak256(abi.encode(w)));
        r = bits == 0 ? 1 : (1 << bits) | (mantissa & ((1 << bits) - 1));
        if (r < lo) r = lo;
        if (r > hi) r = hi;
    }

    /// @dev Values biased to the envelope edge: 2^128 +- 2, small, raw, or log-uniform below 2^128.
    function _edgy(uint256 w) internal pure returns (uint256) {
        uint256 k = w % 5;
        if (k == 0) return (1 << 128) - 2 + (w >> 8) % 5;
        if (k == 1) return (w >> 8) % 1000;
        if (k == 2) return w;
        return _logUniform(w >> 8, 1, type(uint128).max);
    }

    function _word(uint256 seed, uint256 i, uint256 tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i, tag)));
    }

    function _sum(uint256[] memory a) internal pure returns (uint256 s) {
        for (uint256 i; i < a.length; i++) {
            s += a[i];
        }
    }
}
