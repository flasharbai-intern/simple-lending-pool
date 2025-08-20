// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ILendingPool.sol";
import "./LendingPoolToken.sol";

/**
 * @title LendingPool
 * @notice A simple lending pool where users can deposit tokens to earn yield and borrow against collateral
 * @dev Implements a basic lending/borrowing mechanism with interest accrual
 */
contract LendingPool is ILendingPool, Ownable, ReentrancyGuard {}
