// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title LendingPoolToken
 * @notice ERC20 token representing shares in the lending pool
 * @dev Only the lending pool contract can mint and burn tokens
 */
contract LendingPoolToken is ERC20, Ownable {}
