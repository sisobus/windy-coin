// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Windy} from "../src/Windy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract WindyTest is Test {
    Windy internal windy;

    address internal admin = address(0xA11CE);
    address internal minter = address(0xB0B);
    address internal alice = address(0xCAFE);
    address internal bob = address(0xBABE);

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    function setUp() public {
        vm.prank(admin);
        windy = new Windy();
    }

    // --- metadata / initial state ---

    function test_metadata() public view {
        assertEq(windy.name(), "Windy");
        assertEq(windy.symbol(), "WNDY");
        assertEq(windy.decimals(), 18);
    }

    function test_initialSupplyIsZero() public view {
        assertEq(windy.totalSupply(), 0);
    }

    function test_maxSupplyConstant() public view {
        assertEq(windy.MAX_SUPPLY(), 21_000_000 * 10 ** 18);
    }

    function test_adminHasOnlyAdminRole() public view {
        assertTrue(windy.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertFalse(windy.hasRole(windy.MINTER_ROLE(), admin));
    }

    // --- mint authorization ---

    function test_mintRevertsForNonMinter() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, windy.MINTER_ROLE())
        );
        vm.prank(alice);
        windy.mint(alice, 1e18);
    }

    function test_adminCannotMint() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, windy.MINTER_ROLE())
        );
        vm.prank(admin);
        windy.mint(admin, 1e18);
    }

    function test_mintSucceedsAfterRoleGranted() public {
        bytes32 role = windy.MINTER_ROLE();
        vm.prank(admin);
        windy.grantRole(role, minter);

        vm.prank(minter);
        windy.mint(alice, 1_000 * 10 ** 18);

        assertEq(windy.balanceOf(alice), 1_000 * 10 ** 18);
        assertEq(windy.totalSupply(), 1_000 * 10 ** 18);
    }

    // --- cap enforcement ---

    function test_mintExactlyCapSucceeds() public {
        bytes32 role = windy.MINTER_ROLE();
        uint256 cap = windy.MAX_SUPPLY();
        vm.prank(admin);
        windy.grantRole(role, minter);

        vm.prank(minter);
        windy.mint(alice, cap);

        assertEq(windy.totalSupply(), cap);
    }

    function test_mintCapPlusOneReverts() public {
        bytes32 role = windy.MINTER_ROLE();
        uint256 cap = windy.MAX_SUPPLY();
        vm.prank(admin);
        windy.grantRole(role, minter);

        vm.expectRevert(abi.encodeWithSelector(Windy.MaxSupplyExceeded.selector, cap + 1, cap));
        vm.prank(minter);
        windy.mint(alice, cap + 1);
    }

    function test_mintOverCapInTwoStepsReverts() public {
        bytes32 role = windy.MINTER_ROLE();
        uint256 cap = windy.MAX_SUPPLY();
        vm.prank(admin);
        windy.grantRole(role, minter);

        vm.prank(minter);
        windy.mint(alice, cap);

        vm.expectRevert(abi.encodeWithSelector(Windy.MaxSupplyExceeded.selector, cap + 1, cap));
        vm.prank(minter);
        windy.mint(bob, 1);
    }

    // --- burn ---

    function test_burnReducesSenderBalanceAndSupply() public {
        bytes32 role = windy.MINTER_ROLE();
        vm.prank(admin);
        windy.grantRole(role, minter);

        vm.prank(minter);
        windy.mint(alice, 100e18);

        vm.prank(alice);
        windy.burn(40e18);

        assertEq(windy.balanceOf(alice), 60e18);
        assertEq(windy.totalSupply(), 60e18);
    }

    function test_burnFreesCapHeadroom() public {
        bytes32 role = windy.MINTER_ROLE();
        uint256 cap = windy.MAX_SUPPLY();
        vm.prank(admin);
        windy.grantRole(role, minter);

        vm.prank(minter);
        windy.mint(alice, cap);

        vm.prank(alice);
        windy.burn(10e18);

        vm.prank(minter);
        windy.mint(bob, 10e18);

        assertEq(windy.totalSupply(), cap);
    }

    // --- role administration ---

    function test_adminCanGrantAndRevokeMinterRole() public {
        bytes32 role = windy.MINTER_ROLE();

        vm.prank(admin);
        windy.grantRole(role, minter);
        assertTrue(windy.hasRole(role, minter));

        vm.prank(admin);
        windy.revokeRole(role, minter);
        assertFalse(windy.hasRole(role, minter));

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, minter, role));
        vm.prank(minter);
        windy.mint(alice, 1e18);
    }

    function test_nonAdminCannotGrantRole() public {
        bytes32 role = windy.MINTER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(alice);
        windy.grantRole(role, alice);
    }

    function test_adminCannotGrantAfterRenounce() public {
        bytes32 role = windy.MINTER_ROLE();

        vm.prank(admin);
        windy.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        assertFalse(windy.hasRole(DEFAULT_ADMIN_ROLE, admin));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(admin);
        windy.grantRole(role, minter);
    }
}
