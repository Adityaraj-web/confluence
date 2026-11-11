// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title SplitMath
/// @notice Best split of one trade across up to `MAX_VENUES` constant-product venues (ARCHITECTURE-v2 section 3),
///         exact input and exact output, with a cap per venue. Pure: no storage, no external calls.
/// @dev Overflow envelope: every reserve (`x`, `y`) and the amount are below 2^128. Outside it, or with more than
///      `MAX_VENUES` venues, the result is pool-only: index 0 gets the whole amount, every maker zero. Never reverts.
///      Rounding: maker amounts (index >= 1) are floored; index 0, by convention the pool, takes the remainder, so the
///      parts sum exactly to the amount.
library SplitMath {
    /// @notice A constant-product venue: reserves `x` (input token) and `y` (output token), a flat fee on the input
    ///         (`feeE9`, 1e9 = 100%, SwapVM's scale) and a cap. `cap` is in input units for exact input and in output
    ///         units for exact output; `type(uint256).max` means none.
    struct Venue {
        uint256 x;
        uint256 y;
        uint32 feeE9;
        uint256 cap;
    }

    /// @notice Most venues one solve takes (V2-01). Bounds every loop in this library.
    uint256 internal constant MAX_VENUES = 8;

    /// @notice Fee scale: 1e9 = 100% (SwapVM `BPS`).
    uint256 internal constant FEE_SCALE = 1e9;

    /// @notice Largest reserve or amount inside the overflow envelope (2^128 - 1).
    uint256 internal constant MAX_AMOUNT = type(uint128).max;

    /// @notice Best split of `amountIn` input. `a[i]` is the input venue `i` takes; the parts sum to `amountIn`.
    function solveExactIn(Venue[] memory v, uint256 amountIn) internal pure returns (uint256[] memory a) {
        amountIn;
        a = new uint256[](v.length);
    }

    /// @notice Cheapest split for `amountOut` output. `b[i]` is the output venue `i` gives; the parts sum to `amountOut`.
    function solveExactOut(Venue[] memory v, uint256 amountOut) internal pure returns (uint256[] memory b) {
        amountOut;
        b = new uint256[](v.length);
    }

    /// @notice floor(sqrt(floor(a * b / d))) for a 512-bit product. Exposed for the floor-property test.
    function sqrtMulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 z) {
        a;
        b;
        d;
        z = 0;
    }
}
