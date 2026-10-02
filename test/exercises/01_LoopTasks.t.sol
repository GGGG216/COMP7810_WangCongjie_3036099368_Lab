// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {SimpleStablecoin} from "../../src/SimpleStablecoin.sol";
import {Vault} from "../../src/Vault.sol";

/// @title Ex2 + Ex4 — decimals, permissions, and pausing
/// @notice Acceptance: make exercise.
contract LoopTasksTest is Test {
    MockUSDC internal usdc;
    SimpleStablecoin internal stable;
    Vault internal vault;

    address internal admin = address(this);
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockUSDC();
        stable = new SimpleStablecoin(admin);
        vault = new Vault(usdc, stable);
        stable.grantRole(stable.MINTER_ROLE(), address(vault));
    }

    // ==================================================================
    // Ex2 · the decimals trap: a 6-decimal stablecoin meets 18-decimal intuition
    // ==================================================================

    /// @dev For any legitimate amount x, totalSupply() must grow by exactly x after
    ///      deposit(x). Hint: use vm.assume to rule out x == 0, and faucet alice enough
    ///      usdc first.
    function test_Ex2_DepositIncreasesSupplyByExactly(uint96 raw) public {
        uint256 amount = uint256(raw) % 1_000_000e6;
        vm.assume(amount > 0);

        // Start with an existing deposit so this checks the increase, not just an
        // empty vault's final supply.
        _depositAsAlice(25e6);
        uint256 supplyBefore = stable.totalSupply();
        uint256 collateralBefore = vault.totalCollateral();
        uint256 balanceBefore = stable.balanceOf(alice);

        _depositAsAlice(amount);

        assertEq(stable.totalSupply() - supplyBefore, amount);
        assertEq(vault.totalCollateral() - collateralBefore, amount);
        assertEq(stable.balanceOf(alice) - balanceBefore, amount);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(vault.totalCollateral(), stable.totalSupply());
    }

    /// @dev Run deposit with 1000e18 instead of 1000e6, see what happens, then assert what
    ///      you observed. MockUSDC has 6 decimals — 1000e18 is 10^15 USDC.
    ///      There is no expected answer here; the point is that you run it yourself and
    ///      read the numbers.
    function test_Ex2_DecimalsTrap() public {
        uint256 intendedAmount = 1000e6;
        uint256 mistakenAmount = 1000e18;

        // The unrestricted test faucet can supply the mistaken quantity. Neither
        // ERC-20 nor the vault knows that the caller intended only 1,000 coins.
        _depositAsAlice(mistakenAmount);

        assertEq(usdc.decimals(), 6);
        assertEq(stable.decimals(), 6);
        assertEq(stable.balanceOf(alice), mistakenAmount);
        assertEq(stable.totalSupply(), mistakenAmount);
        assertEq(vault.totalCollateral(), mistakenAmount);
        assertEq(mistakenAmount / (10 ** uint256(usdc.decimals())), 1e15);
        assertEq(mistakenAmount / intendedAmount, 1e12);
    }

    // ==================================================================
    // Ex4 · permissions and pausing: where the guard is, who holds the key
    // ==================================================================

    /// @dev The attacker has no MINTER_ROLE, so calling mint directly must revert. Use
    ///      vm.expectRevert + abi.encodeWithSelector to pin down the exact error.
    function test_Ex4_Mint_RevertsForNonMinter() public {
        bytes32 minterRole = stable.MINTER_ROLE();
        assertFalse(stable.hasRole(minterRole, attacker));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, minterRole
            )
        );
        vm.prank(attacker);
        stable.mint(attacker, 100e6);

        assertEq(stable.balanceOf(attacker), 0);
        assertEq(stable.totalSupply(), 0);
    }

    /// @dev After pause(), an ordinary transfer must revert
    function test_Ex4_Pause_BlocksTransfers() public {
        _depositAsAlice(100e6);
        stable.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        stable.transfer(attacker, 10e6);

        assertEq(stable.balanceOf(alice), 100e6);
        assertEq(stable.balanceOf(attacker), 0);
        assertEq(stable.totalSupply(), 100e6);

        stable.unpause();
        vm.prank(alice);
        assertTrue(stable.transfer(attacker, 10e6));
        assertEq(stable.balanceOf(alice), 90e6);
        assertEq(stable.balanceOf(attacker), 10e6);
    }

    /// @dev What pause() freezes is _update, so redemption is frozen along with everything
    ///      else — why is that bad news in a real crisis?
    ///      (This is STUDENT-QUESTIONS.md B1 and B2.)
    function test_Ex4_Pause_BlocksRedeem() public {
        _depositAsAlice(100e6);
        stable.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        vault.redeem(40e6);

        assertEq(stable.balanceOf(alice), 100e6);
        assertEq(stable.totalSupply(), 100e6);
        assertEq(vault.totalCollateral(), 100e6);
        assertEq(usdc.balanceOf(alice), 0);

        stable.unpause();
        vm.prank(alice);
        vault.redeem(40e6);
        assertEq(stable.balanceOf(alice), 60e6);
        assertEq(stable.totalSupply(), 60e6);
        assertEq(vault.totalCollateral(), 60e6);
        assertEq(usdc.balanceOf(alice), 40e6);
    }

    /// @dev An attacker cannot burn someone else's balance
    function test_Ex4_AttackerCannotBurnOthersBalance() public {
        _depositAsAlice(100e6);
        bytes32 minterRole = stable.MINTER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, minterRole
            )
        );
        vm.prank(attacker);
        stable.burn(alice, 40e6);

        assertEq(stable.balanceOf(alice), 100e6);
        assertEq(stable.totalSupply(), 100e6);
        assertEq(vault.totalCollateral(), 100e6);
    }

    /// @dev ...but the vault can, because it holds MINTER_ROLE and burn() answers to that
    ///      same role. This test proves the backdoor exists; it does not justify it.
    function test_Ex4_VaultHoldsTheKey_CanBurnAnyonesBalance() public {
        _depositAsAlice(100e6);
        assertTrue(stable.hasRole(stable.MINTER_ROLE(), address(vault)));
        assertEq(stable.allowance(alice, address(vault)), 0);

        // Impersonation demonstrates the token-level permission. The current
        // Vault has no public function that lets callers choose another owner.
        vm.prank(address(vault));
        stable.burn(alice, 40e6);

        assertEq(stable.balanceOf(alice), 60e6);
        assertEq(stable.totalSupply(), 60e6);
        assertEq(vault.totalCollateral(), 100e6);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function _depositAsAlice(uint256 amount) internal {
        usdc.faucet(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();
    }
}
