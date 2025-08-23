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
contract LendingPool is ILendingPool, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // State variables
    IERC20 public immutable asset;
    LendingPoolToken public immutable lpToken;

    uint256 public totalDeposits;
    uint256 public totalBorrows;
    uint256 public lastUpdateTimestamp;
    uint256 public borrowIndex;

    // Interest rate model parameters (annual rates in basis points)
    uint256 public constant BASE_RATE = 200; // 2%
    uint256 public constant SLOPE1 = 1000; // 10%
    uint256 public constant SLOPE2 = 5000; // 50%
    uint256 public constant OPTIMAL_UTILIZATION = 8000; // 80%
    uint256 public constant MAX_UTILIZATION = 9500; // 95%

    // Collateralization parameters
    uint256 public constant COLLATERAL_FACTOR = 7500; // 75% - max borrow vs collateral
    uint256 public constant LIQUIDATION_THRESHOLD = 8500; // 85% - liquidation threshold
    uint256 public constant LIQUIDATION_BONUS = 500; // 5% - liquidator bonus

    // Precision constants
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // User data
    mapping(address => UserInfo) public userInfo;

    struct UserInfo {
        uint256 collateralBalance;
        uint256 borrowBalance;
        uint256 borrowIndex;
    }

    // Events
    event Deposit(address indexed user, uint256 amount, uint256 lpTokens);
    event Withdraw(address indexed user, uint256 amount, uint256 lpTokens);
    event DepositCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Liquidation(address indexed liquidator, address indexed borrower, uint256 collateralSeized, uint256 debtRepaid);

    constructor(address _asset, string memory _name, string memory _symbol) Ownable(msg.sender) {
        asset = IERC20(_asset);
        lpToken = new LendingPoolToken(_name, _symbol);
        borrowIndex = PRECISION;
        lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @notice Updates the borrow index based on accrued interest
     */
    function updateBorrowIndex() public {
        uint256 timeDelta = block.timestamp - lastUpdateTimestamp;
        if (timeDelta == 0) return;
        
        uint256 borrowRate = getBorrowRate();
        uint256 interestAccrued = (borrowRate * timeDelta * borrowIndex) / (SECONDS_PER_YEAR * BASIS_POINTS);
        borrowIndex += interestAccrued;
        lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @notice Deposits assets into the pool and mints LP tokens
     * @param amount Amount of assets to deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        updateBorrowIndex();
        
        uint256 lpTokensToMint;
        if (lpToken.totalSupply() == 0) {
            lpTokensToMint = amount;
        } else {
            lpTokensToMint = (amount * lpToken.totalSupply()) / getTotalAssets();
        }
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposits += amount;
        lpToken.mint(msg.sender, lpTokensToMint);
        
        emit Deposit(msg.sender, amount, lpTokensToMint);
    }

    /**
     * @notice Withdraws assets from the pool by burning LP tokens
     * @param lpTokenAmount Amount of LP tokens to burn
     */
    function withdraw(uint256 lpTokenAmount) external nonReentrant {
        require(lpTokenAmount > 0, "Amount must be greater than 0");
        require(lpToken.balanceOf(msg.sender) >= lpTokenAmount, "Insufficient LP tokens");
        updateBorrowIndex();
        
        uint256 assetsToWithdraw = (lpTokenAmount * getTotalAssets()) / lpToken.totalSupply();
        require(asset.balanceOf(address(this)) >= assetsToWithdraw, "Insufficient liquidity");
        
        lpToken.burn(msg.sender, lpTokenAmount);
        totalDeposits -= assetsToWithdraw;
        asset.safeTransfer(msg.sender, assetsToWithdraw);
        
        emit Withdraw(msg.sender, assetsToWithdraw, lpTokenAmount);
    }

    /**
     * @notice Deposits collateral to enable borrowing
     * @param amount Amount of collateral to deposit
     */
    function depositCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        userInfo[msg.sender].collateralBalance += amount;
        
        emit DepositCollateral(msg.sender, amount);
    }

    /**
     * @notice Withdraws collateral if health factor allows
     * @param amount Amount of collateral to withdraw
     */
    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(userInfo[msg.sender].collateralBalance >= amount, "Insufficient collateral");
        updateBorrowIndex();
        
        UserInfo storage user = userInfo[msg.sender];
        user.collateralBalance -= amount;
        
        // Check health factor after withdrawal
        uint256 borrowBalance = getUserBorrowBalance(msg.sender);
        if (borrowBalance > 0) {
            require(getHealthFactor(msg.sender) >= PRECISION, "Health factor too low");
        }
        
        asset.safeTransfer(msg.sender, amount);
        emit WithdrawCollateral(msg.sender, amount);
    }

    /**
     * @notice Borrows assets against collateral
     * @param amount Amount to borrow
     */
    function borrow(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(asset.balanceOf(address(this)) >= amount, "Insufficient liquidity");
        updateBorrowIndex();
        
        UserInfo storage user = userInfo[msg.sender];
        
        // Update user's borrow balance
        if (user.borrowBalance > 0) {
            user.borrowBalance = (user.borrowBalance * borrowIndex) / user.borrowIndex;
        }
        user.borrowBalance += amount;
        user.borrowIndex = borrowIndex;
        
        // Check borrow capacity
        uint256 maxBorrow = (user.collateralBalance * COLLATERAL_FACTOR) / BASIS_POINTS;
        require(user.borrowBalance <= maxBorrow, "Insufficient collateral");
        
        totalBorrows += amount;
        asset.safeTransfer(msg.sender, amount);
        
        emit Borrow(msg.sender, amount);
    }

    /**
     * @notice Repays borrowed assets
     * @param amount Amount to repay
     */
    function repay(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        updateBorrowIndex();
        
        UserInfo storage user = userInfo[msg.sender];
        uint256 currentBorrowBalance = getUserBorrowBalance(msg.sender);
        require(currentBorrowBalance > 0, "No debt to repay");
        
        uint256 repayAmount = amount > currentBorrowBalance ? currentBorrowBalance : amount;
        
        user.borrowBalance = currentBorrowBalance - repayAmount;
        user.borrowIndex = borrowIndex;
        
        totalBorrows -= repayAmount;
        asset.safeTransferFrom(msg.sender, address(this), repayAmount);
        
        emit Repay(msg.sender, repayAmount);
    }
}
