// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";

contract LockMarketsTest is Base {
    uint256 id;

    function setUp() public override {
        super.setUp();
        id = _create();
    }

    function _lock(uint256[] memory ids) internal {
        vm.prank(resolver);
        market.lockMarkets(ids);
    }

    function test_onlyResolver() public {
        vm.prank(stranger);
        vm.expectRevert(ILiveMarket.NotResolver.selector);
        market.lockMarkets(_ids(id));
    }

    function test_batchBounds() public {
        vm.prank(resolver);
        vm.expectRevert(ILiveMarket.BadBatch.selector);
        market.lockMarkets(new uint256[](0));

        uint256[] memory tooMany = new uint256[](MAX_LOCK_BATCH + 1);
        vm.prank(resolver);
        vm.expectRevert(ILiveMarket.BadBatch.selector);
        market.lockMarkets(tooMany);

        _lock(_createN(MAX_LOCK_BATCH));
    }

    function test_movesLockTimeToNow() public {
        skip(10);
        vm.expectEmit(address(market));
        emit ILiveMarket.MarketLocked(id, uint64(block.timestamp));
        _lock(_ids(id));
        assertEq(market.getMarket(id).lockTime, block.timestamp);
    }

    function test_betAfterLockInSameBlockRejected() public {
        _bet(alice, id, true, USDC); // sebelum lock di blok yang sama: sah
        _lock(_ids(id));
        usdc.mint(bob, USDC);
        vm.startPrank(bob);
        usdc.approve(address(market), USDC);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.BettingClosed.selector, id));
        market.bet(id, true, USDC);
        vm.stopPrank();
    }

    function test_neverMovesBackward() public {
        _lock(_ids(id));
        uint64 locked = market.getMarket(id).lockTime;
        skip(30);
        vm.recordLogs();
        _lock(_ids(id)); // sudah terkunci: dilewati tanpa event
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(market.getMarket(id).lockTime, locked);
    }

    function test_skipsLockedFinalAndUnknownWithoutRevert() public {
        uint256 voided = _create();
        market.adminVoid(_ids(voided));
        uint256 open = _create();
        uint64 voidedLock = market.getMarket(voided).lockTime;

        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (voided, 999, 0, open);
        vm.recordLogs();
        _lock(ids);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(uint256(logs[0].topics[1]), open);
        assertEq(market.getMarket(voided).lockTime, voidedLock);
        assertEq(market.getMarket(open).lockTime, block.timestamp);
    }

    function test_worksWhilePaused() public {
        market.pause();
        _lock(_ids(id));
        assertEq(market.getMarket(id).lockTime, block.timestamp);
    }
}
