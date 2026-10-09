// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";

contract BetTest is Base {
    uint256 id;

    function setUp() public override {
        super.setUp();
        id = _create();
    }

    function test_betUpdatesPoolsPositionAndBalance() public {
        usdc.mint(alice, 10 * USDC);
        vm.startPrank(alice);
        usdc.approve(address(market), 10 * USDC);
        vm.expectEmit(address(market));
        emit ILiveMarket.BetPlaced(id, alice, true, 10 * USDC, 10 * USDC, 0);
        market.bet(id, true, 10 * USDC);
        vm.stopPrank();

        ILiveMarket.Market memory m = market.getMarket(id);
        assertEq(m.poolYes, 10 * USDC);
        assertEq(m.poolNo, 0);
        ILiveMarket.Position memory p = market.getPosition(id, alice);
        assertEq(p.yes, 10 * USDC);
        assertEq(p.no, 0);
        assertFalse(p.settled);
        assertEq(usdc.balanceOf(address(market)), 10 * USDC);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_bothSidesAllowed() public {
        _bet(alice, id, true, 5 * USDC);
        _bet(alice, id, false, 7 * USDC);
        ILiveMarket.Position memory p = market.getPosition(id, alice);
        assertEq(p.yes, 5 * USDC);
        assertEq(p.no, 7 * USDC);
        ILiveMarket.Market memory m = market.getMarket(id);
        assertEq(m.poolYes, 5 * USDC);
        assertEq(m.poolNo, 7 * USDC);
    }

    function test_rejectedAtAndAfterLockTime() public {
        _warpToLock(id);
        usdc.mint(alice, USDC);
        vm.startPrank(alice);
        usdc.approve(address(market), USDC);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.BettingClosed.selector, id));
        market.bet(id, true, USDC);
        vm.stopPrank();
    }

    function test_acceptedOneSecondBeforeLock() public {
        vm.warp(market.getMarket(id).lockTime - 1);
        _bet(alice, id, true, USDC);
    }

    function test_belowMinBet() public {
        uint128 amount = market.minBet() - 1;
        vm.prank(alice);
        vm.expectRevert(ILiveMarket.AmountTooSmall.selector);
        market.bet(id, true, amount);
    }

    function test_stakeCapCountsBothSides() public {
        uint128 cap = market.maxStakePerUser();
        _bet(alice, id, true, cap - USDC);
        _bet(alice, id, false, USDC); // tepat di cap
        uint128 more = market.minBet();
        usdc.mint(alice, more);
        vm.startPrank(alice);
        usdc.approve(address(market), more);
        vm.expectRevert(ILiveMarket.StakeCapExceeded.selector);
        market.bet(id, true, more);
        vm.stopPrank();
    }

    function test_capIsPerUser() public {
        uint128 cap = market.maxStakePerUser();
        _bet(alice, id, true, cap);
        _bet(bob, id, true, cap);
        assertEq(market.getMarket(id).poolYes, 2 * cap);
    }

    function test_rejectedWhenPaused() public {
        market.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.bet(id, true, USDC);
    }

    function test_unknownMarket() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.MarketNotOpen.selector, 99));
        market.bet(99, true, USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.MarketNotOpen.selector, 0));
        market.bet(0, true, USDC);
    }

    function test_needsApproval() public {
        usdc.mint(alice, USDC);
        vm.prank(alice);
        vm.expectRevert();
        market.bet(id, true, USDC);
    }
}
