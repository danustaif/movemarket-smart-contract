// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";

contract RefundTest is Base {
    uint256 id;

    function setUp() public override {
        super.setUp();
        id = _create();
        _bet(alice, id, true, 10 * USDC);
        _bet(alice, id, false, 5 * USDC);
        _bet(bob, id, true, 20 * USDC);
    }

    function _refund(address user, uint256 marketId) internal returns (uint256) {
        vm.prank(user);
        return market.refund(marketId);
    }

    function test_oracleVoidRefundsFullStake() public {
        _warpToLock(id);
        _report(id, VOID);
        assertEq(market.refundable(id, alice), 15 * USDC);
        vm.expectEmit(address(market));
        emit ILiveMarket.Refunded(id, alice, 15 * USDC);
        assertEq(_refund(alice, id), 15 * USDC);
        assertEq(usdc.balanceOf(alice), 15 * USDC);
        assertTrue(market.getPosition(id, alice).settled);
        assertEq(market.refundable(id, alice), 0);
        assertEq(_refund(bob, id), 20 * USDC);
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    function test_adminVoidRefunds() public {
        vm.expectEmit(address(market));
        emit ILiveMarket.MarketVoided(id, VOID_ADMIN);
        market.adminVoid(_ids(id));
        assertEq(_refund(bob, id), 20 * USDC);
    }

    function test_expiredOpenMarketVoidsOnFirstRefund() public {
        vm.warp(market.getMarket(id).resolveDeadline);
        assertEq(market.refundable(id, alice), 0); // tepat di deadline belum boleh
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.NotRefundable.selector, id));
        market.refund(id);

        skip(1);
        assertEq(market.refundable(id, alice), 15 * USDC);
        vm.expectEmit(address(market));
        emit ILiveMarket.MarketVoided(id, VOID_EXPIRED);
        _refund(alice, id);
        ILiveMarket.Market memory m = market.getMarket(id);
        assertEq(uint8(m.status), uint8(Status.VOIDED));
        assertEq(uint8(m.outcome), VOID);

        vm.recordLogs();
        _refund(bob, id); // refund kedua tidak memancarkan MarketVoided lagi
        assertEq(vm.getRecordedLogs().length, 2); // Transfer + Refunded
    }

    function test_openBeforeDeadlineNotRefundable() public {
        _warpToLock(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.NotRefundable.selector, id));
        market.refund(id);
    }

    function test_resolvedNotRefundable() public {
        _warpToLock(id);
        _report(id, YES);
        vm.warp(market.getMarket(id).resolveDeadline + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.NotRefundable.selector, id));
        market.refund(id);
        assertEq(market.refundable(id, alice), 0);
    }

    function test_refundTwiceReverts() public {
        market.adminVoid(_ids(id));
        _refund(alice, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.AlreadySettled.selector, id));
        market.refund(id);
    }

    function test_refundAfterClaimImpossible() public {
        _warpToLock(id);
        _report(id, YES);
        vm.prank(alice);
        market.claim(id);
        // pasar RESOLVED tidak pernah bisa jadi VOIDED, jadi refund ditolak
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.NotRefundable.selector, id));
        market.refund(id);
    }

    function test_noStakeNotRefundable() public {
        market.adminVoid(_ids(id));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.NotRefundable.selector, id));
        market.refund(id);
    }

    function test_unknownMarketNotRefundable() public {
        vm.warp(block.timestamp + MAX_BET_WINDOW_SEC + MAX_RESOLVE_DELAY_SEC + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.NotRefundable.selector, 99));
        market.refund(99);
    }

    function test_refundWorksWhilePaused() public {
        market.adminVoid(_ids(id));
        market.pause();
        assertEq(_refund(bob, id), 20 * USDC);
    }
}
