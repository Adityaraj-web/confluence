// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ConfluenceBase} from "./ConfluenceBase.t.sol";

/// @notice Realised outputs of candidate splits on the fork, each run from the same starting state (V2-00).
/// @dev Runs the v1 deployment that `ConfluenceBase` builds (the hook at `src/v1/`, Priya's strategy registered).
///      Each candidate is a v1 hint: the USDC (or MUMB) amount sent to Aqua, the rest going to the pool; 0 is the
///      pool-only path with empty `hookData`. After V2-03 the hint is gone; this oracle then keeps serving the v1
///      numbers (V2-07's gate compares empty-`hookData` swaps against it).
abstract contract ForkOracle is ConfluenceBase {
    /// @dev Bound on the candidate list (a named constant, as every loop is).
    uint256 internal constant MAX_CANDIDATES = 16;

    error TooManyCandidates(uint256 given);

    /// @notice The trader's realised output for an exact-input swap of `amountIn`, once per hint.
    /// @param zeroForOne Swap direction on the main pool.
    /// @param amountIn Exact input.
    /// @param hints Aqua input amounts to try; 0 means pool-only.
    /// @return outs `outs[i]` is the output token the trader received with `hints[i]`. State is restored after
    ///         each candidate, so every one starts from the state the call started in.
    function _realiseExactIn(bool zeroForOne, uint256 amountIn, uint256[] memory hints)
        internal
        virtual
        returns (uint256[] memory outs)
    {
        if (hints.length > MAX_CANDIDATES) revert TooManyCandidates(hints.length);
        outs = new uint256[](hints.length);

        // The output token is currency1 when swapping zero for one, else currency0.
        address tokenOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);

        for (uint256 i; i < hints.length; i++) {
            uint256 snapshot = vm.snapshotState();
            uint256 before = IERC20(tokenOut).balanceOf(trader);
            _swapExactIn(trader, zeroForOne, amountIn, hints[i] == 0 ? bytes("") : _hint(hints[i]));
            outs[i] = IERC20(tokenOut).balanceOf(trader) - before;
            require(vm.revertToStateAndDelete(snapshot), "ForkOracle: revert failed");
        }
    }
}
