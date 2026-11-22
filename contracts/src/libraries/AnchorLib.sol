// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice STUB (V2-03 red step): every function reverts until the implementation lands.
library AnchorLib {
    error NotImplemented();

    struct Anchor {
        uint40 lastTimestamp;
        uint64 lastBlock;
        int24 snapTick;
        int56 emaTickX;
    }

    uint256 internal constant CUTOFF_HALF_LIVES = 16;

    function decayX128(uint256, uint256) internal pure returns (uint256) {
        revert NotImplemented();
    }

    function nextEmaX(int256, int24, uint256, uint256) internal pure returns (int56) {
        revert NotImplemented();
    }

    function emaTick(int56) internal pure returns (int24) {
        revert NotImplemented();
    }

    function next(Anchor memory, int24, uint256, uint256, uint256) internal pure returns (Anchor memory) {
        revert NotImplemented();
    }
}
