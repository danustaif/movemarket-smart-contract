// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";

contract ClaimTest is Base {
    uint256 id;

    /// Contoh CONTRACTS.md 7: YES A 10, B 30; NO C 60; fee 2%.
    function setUp() public override {
        super.setUp();
        id = _create();
        _bet(alice, id, true, 10 * USDC);
        _bet(bob, id, true, 30 * USDC);
        _bet(carol, id, false, 60 * USDC);
        _warpToLock(id);
    }

    function _claim(address user, uint256 marketId) internal returns (uint256) {
        vm.prank(user);
        return market.claim(marketId);
    }

    function test_specExampleYes() public {
        _report(id, YES);
        assertEq(market.getMarket(id).fee, 2 * USDC);
        assertEq(market.claimable(id, alice), 24_500_000); // 24.5 tUSDC
        assertEq(market.claimable(id, bob), 73_500_000); // 73.5 tUSDC
        assertEq(market.claimable(id, carol), 0);

        vm.expectEmit(address(market));
        emit ILiveMarket.Claimed(id, alice, 24_500_000);
        assertEq(_claim(alice, id), 24_500_000);
        assertEq(_claim(bob, id), 73_500_000);
        assertEq(usdc.balanceOf(alice), 24_500_000);
        assertEq(usdc.balanceOf(bob), 73_500_000);
        assertEq(usdc.balanceOf(address(market)), 2 * USDC); // tinggal fee
        assertTrue(market.getPosition(id, alice).settled);
        assertEq(market.claimable(id, alice), 0);
    }

    function test_specExampleNo() public {
        _report(id, NO);
        assertEq(_claim(carol, id), 98 * USDC);
    }

    function test_roundingNeverExceedsPool() public {
        uint256 m2 = _create();
        _bet(alice, m2, true, USDC);
        _bet(bob, m2, true, USDC);
        _bet(carol, m2, true, USDC);
        _bet(stranger, m2, false, USDC);
        _warpToLock(m2);
        _report(m2, YES);
        // total 4, fee 0.08, distributable 3.92 dibagi tiga: dibulatkan ke bawah
        uint256 sum = _claim(alice, m2) + _claim(bob, m2) + _claim(carol, m2);
        assertEq(market.claimable(m2, alice), 0);
        assertEq(sum, 3 * 1_306_666);
        assertLe(sum, 4 * USDC - market.getMarket(m2).fee);
    }

    function test_claimTwiceReverts() public {
        _report(id, YES);
        _claim(alice, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.AlreadySettled.selector, id));
        market.claim(id);
    }

    function test_losingSideNothingToClaim() public {
        _report(id, YES);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.NothingToClaim.selector, id));
        market.claim(id);
    }

    function test_notClaimableBeforeResolution() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.NotClaimable.selector, id));
        market.claim(id);
    }

    function test_notClaimableWhenVoided() public {
        _report(id, VOID);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.NotClaimable.selector, id));
        market.claim(id);
        assertEq(market.claimable(id, alice), 0);
    }

    function test_bothSidesStakerGetsWinningSideOnly() public {
        uint256 m2 = _create();
        _bet(alice, m2, true, 10 * USDC);
        _bet(alice, m2, false, 10 * USDC);
        _bet(bob, m2, false, 20 * USDC);
        _warpToLock(m2);
        _report(m2, YES);
        // total 40, fee 0.8, distributable 39.2, alice satu-satunya YES
        assertEq(_claim(alice, m2), 39_200_000);
    }

    function test_claimWorksWhilePaused() public {
        _report(id, YES);
        market.pause();
        assertEq(_claim(alice, id), 24_500_000);
    }

    function test_claimManySkipsInvalidAndTransfersOnce() public {
        uint256 m2 = _create();
        _bet(alice, m2, false, 5 * USDC);
        _bet(bob, m2, true, 5 * USDC);
        uint256 lost = _create();
        _bet(alice, lost, true, 5 * USDC);
        _bet(bob, lost, false, 5 * USDC);
        uint256 open = _create();
        _warpToLock(m2);

        uint256[] memory rep = new uint256[](3);
        (rep[0], rep[1], rep[2]) = (id, m2, lost);
        uint8[] memory outs = new uint8[](3);
        (outs[0], outs[1], outs[2]) = (YES, NO, NO);
        _report(GAME_KEY, rep, outs);
        _claim(alice, id); // sudah settled sebelum claimMany

        uint256[] memory ids = new uint256[](5);
        (ids[0], ids[1], ids[2], ids[3], ids[4]) = (id, m2, lost, open, 999);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 total = market.claimMany(ids);
        // m2: total 10, fee 0.2, alice satu-satunya NO
        assertEq(total, 9_800_000);
        assertEq(usdc.balanceOf(alice) - before, 9_800_000);
        assertTrue(market.getPosition(id, alice).settled);
        assertTrue(market.getPosition(m2, alice).settled);
        assertFalse(market.getPosition(lost, alice).settled);
    }

    function test_claimManyNothingClaimable() public {
        vm.prank(alice);
        assertEq(market.claimMany(_ids(id)), 0);
    }
}
