// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Ryfinite Token
/// @notice A fixed supply of one billion RFN, with 18 decimals, minted entirely to the deployer.
/// @dev The immediate creator receives the supply, including when deployment is through a factory.
/// There are no external mint/burn functions, administrative roles, fees, or upgrade mechanisms.
contract RyfiniteToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Ryfinite Token", "RFN") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
