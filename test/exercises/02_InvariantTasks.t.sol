// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockUSDC} from "../../src/MockUSDC.sol";
import {SimpleStablecoin} from "../../src/SimpleStablecoin.sol";
import {Vault} from "../../src/Vault.sol";

/// @title Ex6 — invariant testing
/// @notice Every test so far set up a situation and then checked the result. Invariant
///         testing flips that around: let the machine call operations randomly and
///         repeatedly, then ask "no matter how it thrashes, does this property still
///         hold?"
///
///         That is what a stablecoin should be tested like — you will never guess the
///         order an attacker does things in.
///
///         Acceptance: make exercise.
///
/// @dev How it works: Foundry picks functions from the handler at random, picks random
///      arguments, and calls them N times in a row; after each round it runs every
///      invariant_* function. The first failed assertion is a counterexample.
contract VaultHandler is Test {
    MockUSDC internal usdc;
    SimpleStablecoin internal stable;
    Vault internal vault;

    address[3] public users;

    /// @dev Bookkeeping: proves the fuzzer really reached the handler instead of idling
    uint256 public ghost_deposits;
    uint256 public ghost_redeems;

    constructor(MockUSDC usdc_, SimpleStablecoin stable_, Vault vault_) {
        usdc = usdc_;
        stable = stable_;
        vault = vault_;

        users[0] = makeAddr("user0");
        users[1] = makeAddr("user1");
        users[2] = makeAddr("user2");
        for (uint256 i; i < users.length; ++i) {
            usdc.faucet(users[i], 1_000_000e6);
        }
    }

    /// @dev Given to you — this is the standard shape of "pick a random argument and keep it
    ///      inside a valid range"
    function deposit(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = usdc.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        ghost_deposits++;
    }

    /// @dev Ex6.1: redeem only the selected user's available sUSD. Unlike deposit,
    ///      redemption requires no approval because the vault holds MINTER_ROLE.
    function redeem(uint256 userSeed, uint256 amount) external {
        address user = users[bound(userSeed, 0, users.length - 1)];

        uint256 balance = stable.balanceOf(user);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);

        vm.prank(user);
        vault.redeem(amount);

        ghost_redeems++;
    }
}

contract InvariantTasksTest is Test {
    MockUSDC internal usdc;
    SimpleStablecoin internal stable;
    Vault internal vault;
    VaultHandler internal handler;

    address internal admin = address(this);

    function setUp() public {
        usdc = new MockUSDC();
        stable = new SimpleStablecoin(admin);
        vault = new Vault(usdc, stable);
        stable.grantRole(stable.MINTER_ROLE(), address(vault));

        handler = new VaultHandler(usdc, stable, vault);

        // Let the fuzzer call only the handler's deposit / redeem, not its other functions
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Ex6.2: every coin remains backed. Exact equality is the stronger property
    ///      in this handler's scope: deposits and redemptions only, with no donations
    ///      or privileged mint/burn calls.
    function invariant_CollateralBacksSupply() public view {
        assertEq(vault.totalCollateral(), stable.totalSupply(), "collateral must equal supply");
    }

    /// @dev Ex6.3: minting and burning occur in the user's balance. This property is
    ///      scoped to the handler, since ordinary ERC-20 transfers could send sUSD
    ///      directly to the vault in a broader action space.
    function invariant_VaultHoldsNoStablecoin() public view {
        assertEq(stable.balanceOf(address(vault)), 0, "vault must not retain stablecoins");
    }

    /// @dev Deterministic handler coverage avoids relying on a random sequence to
    ///      happen to exercise both successful actions.
    function test_Handler_DepositAndRedeemForEveryUser() public {
        for (uint256 i; i < 3; ++i) {
            address user = handler.users(i);
            handler.deposit(i, 100e6);
            assertEq(stable.balanceOf(user), 100e6);
            assertEq(stable.allowance(user, address(vault)), 0);

            handler.redeem(i, 100e6);
            assertEq(stable.balanceOf(user), 0);
            assertEq(usdc.balanceOf(user), 1_000_000e6);
        }

        assertEq(handler.ghost_deposits(), 3);
        assertEq(handler.ghost_redeems(), 3);
        assertEq(stable.totalSupply(), 0);
        assertEq(vault.totalCollateral(), 0);
    }

    function test_Handler_RedeemWithNoBalanceReturnsEarly() public {
        handler.redeem(type(uint256).max, type(uint256).max);
        assertEq(handler.ghost_redeems(), 0);
        assertEq(stable.totalSupply(), 0);
        assertEq(vault.totalCollateral(), 0);
    }

    function testFuzz_Handler_RedeemIsBoundedByUserBalance(uint256 userSeed, uint256 raw) public {
        uint256 userIndex = bound(userSeed, 0, 2);
        address user = handler.users(userIndex);
        handler.deposit(userIndex, 100e6);

        uint256 amount = bound(raw, 1, 100e6);
        handler.redeem(userIndex, raw);

        assertEq(stable.balanceOf(user), 100e6 - amount);
        assertEq(usdc.balanceOf(user), 1_000_000e6 - 100e6 + amount);
        assertEq(handler.ghost_redeems(), 1);
        assertEq(vault.totalCollateral(), stable.totalSupply());
    }
}
