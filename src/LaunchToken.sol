// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mnemo (MNEMO) launch token
/// @notice Fixed-supply ERC-20 for the MNEMO launch. The whole supply of 1,000,000,000 tokens
///         (10^27 minor units, 18 decimals) is minted once to the deployer, which is the launch
///         factory. There is no owner, no mint, no pause, no blocklist, no fee and no upgrade path:
///         transfers are the plain OpenZeppelin ERC-20 transfers.
/// @dev    The factory splits the supply (swarm, pool and requester) after deployment. Nothing in
///         this contract or in MnemoVault is allocated any of it at launch.
contract LaunchToken is ERC20 {
    /// @notice Total and only supply, in minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    constructor() ERC20("Mnemo", "MNEMO") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
