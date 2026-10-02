// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {SimpleStablecoin} from "../SimpleStablecoin.sol";
import {IPriceFeed} from "./IPriceFeed.sol";

/// @title Over-collateralized vault (Ex5)
/// @notice Unlike the 1:1 loop in Vault.sol, $1 of collateral deposited here mints at most
///         0.667 sUSD (a 150% collateral ratio). Once the collateral ratio falls below
///         120%, anyone can take that collateral at a discount by paying sUSD — that is
///         liquidation, the core mechanism behind MakerDAO.
///
///         Three decimal scales must be told apart:
///           collateral  18 decimals (like WETH)
///           stable       6 decimals (like USDC)
///           priceFeed    8 decimals (like Chainlink ETH/USD)
contract OverCollateralizedVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateral;
    SimpleStablecoin public immutable stable;
    IPriceFeed public immutable priceFeed;

    uint256 public constant RATIO_PRECISION = 100;
    uint256 public constant MIN_COLLATERAL_RATIO = 150; // 150% is the floor for minting
    uint256 public constant LIQUIDATION_RATIO = 120; // below 120% you can be liquidated
    uint256 public constant LIQUIDATION_BONUS = 10; // the liquidator takes an extra 10%

    /// @dev Collateral the user has deposited, 18 decimals
    mapping(address => uint256) public collateralOf;
    /// @dev Stablecoin the user owes, 6 decimals
    mapping(address => uint256) public debtOf;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralRedeemed(address indexed user, uint256 amount);
    event StableMinted(address indexed user, uint256 amount);
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    error ZeroAddress();
    error ZeroAmount();
    error Undercollateralized();
    error NotLiquidatable();
    error InsufficientCollateral();

    constructor(IERC20 collateral_, SimpleStablecoin stable_, IPriceFeed priceFeed_) {
        if (
            address(collateral_) == address(0) || address(stable_) == address(0)
                || address(priceFeed_) == address(0)
        ) {
            revert ZeroAddress();
        }
        collateral = collateral_;
        stable = stable_;
        priceFeed = priceFeed_;
    }

    // ==================================================================
    // Given to you — no decimal conversion involved, do not touch
    // ==================================================================

    /// @notice What one unit of collateral is worth in USD, 8 decimals
    /// @dev Production code would also check whether updatedAt is stale and whether
    ///      answer <= 0 — the oracle is an attack surface of its own
    function collateralPrice() public view returns (uint256) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        if (answer <= 0) revert ZeroAmount();
        return uint256(answer);
    }

    /// @notice The user's collateral, converted into sUSD smallest units (6 decimals)
    function collateralValueOf(address user) public view returns (uint256) {
        return collateralValue(collateralOf[user]);
    }

    /// @notice Current collateral ratio; 150 means 150%. Returns the maximum when there is
    ///         no debt at all
    function collateralRatio(address user) public view returns (uint256) {
        if (debtOf[user] == 0) return type(uint256).max;
        return collateralValueOf(user) * RATIO_PRECISION / debtOf[user];
    }

    /// @notice Deposit collateral
    function depositCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);
    }

    /// @notice Repay debt: burn sUSD and reduce what is owed
    function repay(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (amount > debtOf[msg.sender]) revert InsufficientCollateral();
        stable.burn(msg.sender, amount);
        debtOf[msg.sender] -= amount;
    }

    // ==================================================================
    // Ex5.1 — decimal conversion
    // ==================================================================

    /// @notice Convert `amount` units of collateral (18 decimals) into sUSD smallest units
    ///         (6 decimals)
    /// @dev 18 + 8 - 6 = 20: round down so fractional sUSD units cannot back extra debt.
    ///      Ratio checks use this conservative value and discard less than one sUSD
    ///      smallest unit ($0.000001), including when assessing liquidation eligibility.
    function collateralValue(uint256 amount) public view returns (uint256) {
        return Math.mulDiv(amount, collateralPrice(), 1e20);
    }

    // ==================================================================
    // Ex5.2 — minting has to leave enough collateral behind
    // ==================================================================

    /// @notice Mint `amount` of sUSD, but the collateral ratio afterwards must not fall
    ///         below MIN_COLLATERAL_RATIO
    /// @dev Check the post-mint debt against the supported debt, rounded down. A revert
    ///      rolls back the debt update as well as any token state.
    function mintStable(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        debtOf[msg.sender] += amount;
        uint256 maxDebt =
            Math.mulDiv(collateralValueOf(msg.sender), RATIO_PRECISION, MIN_COLLATERAL_RATIO);
        if (debtOf[msg.sender] > maxDebt) revert Undercollateralized();

        stable.mint(msg.sender, amount);
        emit StableMinted(msg.sender, amount);
    }

    // ==================================================================
    // Ex5.3 — withdrawing collateral must not leave the position unhealthy either
    // ==================================================================

    /// @notice Withdraw `amount` units of collateral; the ratio afterwards must not fall
    ///         below MIN_COLLATERAL_RATIO
    function redeemCollateral(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (amount > collateralOf[msg.sender]) revert InsufficientCollateral();
        collateralOf[msg.sender] -= amount;

        // With no debt there is no ratio to protect, even if the oracle is unavailable.
        if (debtOf[msg.sender] != 0) {
            uint256 maxDebt =
                Math.mulDiv(collateralValueOf(msg.sender), RATIO_PRECISION, MIN_COLLATERAL_RATIO);
            if (debtOf[msg.sender] > maxDebt) revert Undercollateralized();
        }

        collateral.safeTransfer(msg.sender, amount);
        emit CollateralRedeemed(msg.sender, amount);
    }

    // ==================================================================
    // Ex5.4 — liquidation
    // ==================================================================

    /// @notice Once the ratio falls below LIQUIDATION_RATIO, anyone may burn their own
    ///         sUSD to repay that user's entire debt and seize collateral worth
    ///         "debt value × (100% + LIQUIDATION_BONUS)".
    /// @dev Do not forget: the collateral may not be enough to pay that bonus. In that case
    ///      take everything the user has left. The caller still pays the full debt, so a
    ///      deeply underwater position may lack a willing liquidator.
    function liquidate(address user) external {
        uint256 debt = debtOf[user];
        if (debt == 0) revert NotLiquidatable();

        uint256 available = collateralOf[user];
        uint256 price = collateralPrice();
        uint256 value = Math.mulDiv(available, price, 1e20);
        // Equality at 120% of the rounded six-decimal collateral value is healthy.
        if (debt <= Math.mulDiv(value, RATIO_PRECISION, LIQUIDATION_RATIO)) {
            revert NotLiquidatable();
        }

        // debt (6 decimals) * 110% * 10^20 / price (8 decimals) gives 18 decimals.
        // Apply the bonus before rounding to avoid losing precision on small debts.
        uint256 seizureScale = (RATIO_PRECISION + LIQUIDATION_BONUS) * 1e18;
        uint256 debtForAllCollateral =
            Math.mulDiv(available, price, seizureScale, Math.Rounding.Ceil);
        // Cap first: an extremely low price can make an uncapped payout overflow.
        uint256 seized =
            debt >= debtForAllCollateral ? available : Math.mulDiv(debt, seizureScale, price);

        debtOf[user] = 0;
        collateralOf[user] = available - seized;
        stable.burn(msg.sender, debt);
        collateral.safeTransfer(msg.sender, seized);
        emit Liquidated(user, msg.sender, debt, seized);
    }
}
