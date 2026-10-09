// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract MockUSDCTest is Test {
    MockUSDC usdc;
    address minter = makeAddr("minter");
    address alice = makeAddr("alice");

    function setUp() public {
        usdc = new MockUSDC();
    }

    function test_metadata() public view {
        assertEq(usdc.name(), "Test USDC");
        assertEq(usdc.symbol(), "tUSDC");
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.owner(), address(this));
    }

    function test_minterCanMint() public {
        usdc.setMinter(minter, true);
        assertTrue(usdc.minters(minter));
        vm.prank(minter);
        usdc.mint(alice, 50e6);
        assertEq(usdc.balanceOf(alice), 50e6);
    }

    function test_nonMinterCannotMint() public {
        vm.prank(alice);
        vm.expectRevert(MockUSDC.NotMinter.selector);
        usdc.mint(alice, 1);
    }

    function test_revokedMinterCannotMint() public {
        usdc.setMinter(minter, true);
        usdc.setMinter(minter, false);
        vm.prank(minter);
        vm.expectRevert(MockUSDC.NotMinter.selector);
        usdc.mint(alice, 1);
    }

    function test_onlyOwnerSetsMinter() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        usdc.setMinter(alice, true);
    }
}
