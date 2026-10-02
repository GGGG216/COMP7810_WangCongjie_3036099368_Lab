// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {SimpleStablecoin} from "../../src/SimpleStablecoin.sol";
import {MockWETH} from "../../src/exercises/MockWETH.sol";
import {MockPriceFeed} from "../../src/exercises/MockPriceFeed.sol";
import {OverCollateralizedVault} from "../../src/exercises/OverCollateralizedVault.sol";

/// @notice Additional checks for rounding, atomic rollback and liquidation boundaries.
contract OverCollateralEdgeCasesTest is Test {
    MockWETH internal weth;
    SimpleStablecoin internal stable;
    MockPriceFeed internal feed;
    OverCollateralizedVault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        weth = new MockWETH();
        stable = new SimpleStablecoin(address(this));
        feed = new MockPriceFeed(2000e8);
        vault = new OverCollateralizedVault(weth, stable, feed);
        stable.grantRole(stable.MINTER_ROLE(), address(vault));
    }

    function _position(uint256 collateralAmount, uint256 debt) internal {
        weth.faucet(alice, collateralAmount);
        vm.startPrank(alice);
        weth.approve(address(vault), collateralAmount);
        vault.depositCollateral(collateralAmount);
        if (debt != 0) vault.mintStable(debt);
        vm.stopPrank();
    }

    function _fundLiquidator(uint256 amount) internal {
        vm.prank(alice);
        stable.transfer(bob, amount);
    }

    function test_ZeroAmountsRejected() public {
        vm.expectRevert(OverCollateralizedVault.ZeroAmount.selector);
        vault.mintStable(0);
        vm.expectRevert(OverCollateralizedVault.ZeroAmount.selector);
        vault.redeemCollateral(0);
    }

    function test_CollateralValueRoundsDownAtSmallestStableUnit() public view {
        assertEq(vault.collateralValue(499_999_999), 0);
        assertEq(vault.collateralValue(500_000_000), 1);
    }

    function test_CollateralValueAvoidsIntermediateOverflow() public {
        feed.setPrice(1e8);
        assertEq(vault.collateralValue(type(uint256).max), type(uint256).max / 1e12);
    }

    function test_MintAtExact150PercentRejectsOneMoreUnitAndRollsBack() public {
        feed.setPrice(1500e8);
        _position(1e18, 1000e6);

        vm.expectRevert(OverCollateralizedVault.Undercollateralized.selector);
        vm.prank(alice);
        vault.mintStable(1);

        assertEq(vault.debtOf(alice), 1000e6);
        assertEq(stable.balanceOf(alice), 1000e6);
        assertEq(stable.totalSupply(), 1000e6);
    }

    function test_RedeemOneWeiBeyond150PercentRollsBack() public {
        _position(2e18, 2000e6);

        vm.expectRevert(OverCollateralizedVault.Undercollateralized.selector);
        vm.prank(alice);
        vault.redeemCollateral(0.5e18 + 1);

        assertEq(vault.collateralOf(alice), 2e18);
        assertEq(weth.balanceOf(address(vault)), 2e18);
        assertEq(weth.balanceOf(alice), 0);
    }

    function test_RedeemCannotTakeAnotherUsersCollateral() public {
        _position(1e18, 0);
        vm.expectRevert(OverCollateralizedVault.InsufficientCollateral.selector);
        vm.prank(bob);
        vault.redeemCollateral(1);
        assertEq(vault.collateralOf(alice), 1e18);
    }

    function test_RepayingAllDebtAllowsFullWithdrawalWithoutOracle() public {
        _position(1e18, 1000e6);
        feed.setPrice(0);

        vm.startPrank(alice);
        vault.repay(1000e6);
        vault.redeemCollateral(1e18);
        vm.stopPrank();

        assertEq(vault.debtOf(alice), 0);
        assertEq(vault.collateralOf(alice), 0);
        assertEq(stable.totalSupply(), 0);
        assertEq(weth.balanceOf(alice), 1e18);
    }

    function test_LiquidationRejectsZeroDebt() public {
        _position(1e18, 0);
        vm.expectRevert(OverCollateralizedVault.NotLiquidatable.selector);
        vm.prank(bob);
        vault.liquidate(alice);
    }

    function test_LiquidationRejectsExactly120Percent() public {
        _position(1e18, 1000e6);
        _fundLiquidator(1000e6);
        feed.setPrice(1200e8);

        vm.expectRevert(OverCollateralizedVault.NotLiquidatable.selector);
        vm.prank(bob);
        vault.liquidate(alice);
        assertEq(vault.debtOf(alice), 1000e6);
    }

    function test_LiquidationJustBelow120PercentLeavesSurplusWithBorrower() public {
        _position(1e18, 1000e6);
        _fundLiquidator(1000e6);
        uint256 price = 1200e8 - 1;
        feed.setPrice(int256(price));
        uint256 expectedSeizure = uint256(1000e6) * 110e18 / price;

        vm.prank(bob);
        vault.liquidate(alice);

        assertEq(vault.debtOf(alice), 0);
        assertEq(stable.balanceOf(bob), 0);
        assertEq(weth.balanceOf(bob), expectedSeizure);
        assertEq(vault.collateralOf(alice), 1e18 - expectedSeizure);
        vm.prank(alice);
        vault.redeemCollateral(1e18 - expectedSeizure);
        assertEq(weth.balanceOf(address(vault)), 0);
    }

    function test_LiquidationRoundsOnlyAfterApplyingBonus() public {
        // One smallest unit of debt must still receive a 10% bonus in WETH precision.
        _position(1.15e9, 1);
        _fundLiquidator(1);
        feed.setPrice(1000e8);

        vm.prank(bob);
        vault.liquidate(alice);

        assertEq(weth.balanceOf(bob), 1.1e9);
        assertEq(vault.collateralOf(alice), 0.05e9);
    }

    function test_UnfundedLiquidatorCannotBurnBorrowersStablecoin() public {
        _position(1e18, 1000e6);
        feed.setPrice(1100e8);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1000e6)
        );
        vm.prank(bob);
        vault.liquidate(alice);

        assertEq(vault.debtOf(alice), 1000e6);
        assertEq(vault.collateralOf(alice), 1e18);
        assertEq(stable.balanceOf(alice), 1000e6);
        assertEq(weth.balanceOf(address(vault)), 1e18);
    }

    function test_PausedMintAndLiquidationRollBackAccounting() public {
        _position(1e18, 1000e6);
        _fundLiquidator(1000e6);
        stable.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        vault.mintStable(1);
        assertEq(vault.debtOf(alice), 1000e6);

        feed.setPrice(1100e8);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        vault.liquidate(alice);

        assertEq(vault.debtOf(alice), 1000e6);
        assertEq(vault.collateralOf(alice), 1e18);
        assertEq(stable.balanceOf(bob), 1000e6);
    }

    function test_ExtremePriceDropCapsBeforeUnboundedSeizureOverflows() public {
        feed.setPrice(1e20);
        uint256 collateralAmount = type(uint256).max / 4;
        uint256 debt = collateralAmount / 2;
        _position(collateralAmount, debt);
        _fundLiquidator(debt);
        feed.setPrice(1);

        vm.prank(bob);
        vault.liquidate(alice);

        assertEq(vault.debtOf(alice), 0);
        assertEq(vault.collateralOf(alice), 0);
        assertEq(weth.balanceOf(bob), collateralAmount);
        assertEq(stable.totalSupply(), 0);
    }
}
