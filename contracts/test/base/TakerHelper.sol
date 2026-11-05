// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "@1inch/swap-vm/src/libs/TakerTraits.sol";

/// @notice Stand-in for the hook as the router's taker: pays by transfer and holds nothing afterwards.
/// @dev Tests fund it with `deal` where the hook would `take` from the PoolManager. It forwards the output to
///      `recipient` where the hook would `settle` it.
contract TakerHelper {
    using SafeERC20 for IERC20;

    ISwapVM public immutable router;

    constructor(ISwapVM router_) {
        router = router_;
    }

    /// @notice Exact-input swap paying from this contract's balance. Anyone may call.
    function swapExactIn(
        ISwapVM.Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external returns (uint256 swappedIn, uint256 swappedOut, bytes32 orderHash) {
        // The router is what calls transferFrom on the taker (SwapVM.sol:235), so it gets the approval, not Aqua.
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        (swappedIn, swappedOut, orderHash) = router.swap(order, tokenIn, tokenOut, amountIn, _takerData(minOut));
        IERC20(tokenIn).forceApprove(address(router), 0);

        IERC20(tokenOut).safeTransfer(recipient, swappedOut);
    }

    /// @notice The router's quote, with this contract as taker and the same taker data as the swap. Anyone may call.
    function quoteExactIn(
        ISwapVM.Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external view returns (uint256 quotedIn, uint256 quotedOut, bytes32 orderHash) {
        return router.quote(order, tokenIn, tokenOut, amountIn, _takerData(minOut));
    }

    /// @dev `to` stays zero so the output lands on this contract, as it will on the hook. The maker-to-taker
    ///      transfer runs first, matching ARCHITECTURE section 3 step 7.
    function _takerData(uint256 minOut) private view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: false,
                useTransferFromAndAquaPush: true,
                threshold: abi.encode(minOut),
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }
}
