// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockMUMB
/// @notice Mock long-tail ERC-20 (18 decimals) for the MUMB/USDC pair.
contract MockMUMB is ERC20 {
    /// @dev Caller of `mint` is not the account that deployed this token.
    error NotDeployer();

    /// @notice The account allowed to mint: the deployer.
    address public immutable deployer;

    constructor() ERC20("Mumbai Token", "MUMB") {
        deployer = msg.sender;
    }

    /// @notice Mint `amount` MUMB to `to`. Only the deployer may call.
    function mint(address to, uint256 amount) external {
        if (msg.sender != deployer) revert NotDeployer();
        _mint(to, amount);
    }
}
