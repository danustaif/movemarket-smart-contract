// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";

contract CreateMarketsTest is Base {
    function test_createsMarketWithSequentialIds() public {
        ILiveMarket.MarketParams[] memory p = new ILiveMarket.MarketParams[](2);
        p[0] = _params();
        p[1] = _params(GAME, 35, 38);

        vm.expectEmit(address(market));
        emit ILiveMarket.MarketCreated(
            1, GAME_KEY, GAME, uint8(MarketType.CHECK), uint8(Side.ANY), 31, 34, p[0].lockTime, p[0].resolveDeadline
        );
        uint256 first = _createBatch(p);

        assertEq(first, 1);
        assertEq(market.nextMarketId(), 3);
        ILiveMarket.Market memory m = market.getMarket(2);
        assertEq(m.gameKey, GAME_KEY);
        assertEq(m.fromPly, 35);
        assertEq(m.toPly, 38);
        assertEq(m.lockTime, p[1].lockTime);
        assertEq(m.resolveDeadline, p[1].resolveDeadline);
        assertEq(uint8(m.status), uint8(Status.OPEN));
        assertEq(uint8(m.outcome), uint8(Outcome.NONE));
        assertEq(market.gameRefOf(GAME_KEY), GAME);
    }

    function test_secondBatchContinuesIds() public {
        _create();
        assertEq(_create(), 2);
    }

    function test_onlyResolver() public {
        vm.prank(stranger);
        vm.expectRevert(ILiveMarket.NotResolver.selector);
        market.createMarkets(_wrap(_params()));
    }

    function test_rejectsWhenPaused() public {
        market.pause();
        ILiveMarket.MarketParams[] memory p = _wrap(_params());
        vm.prank(resolver);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.createMarkets(p);
    }

    function test_batchBounds() public {
        ILiveMarket.MarketParams[] memory empty = new ILiveMarket.MarketParams[](0);
        vm.prank(resolver);
        vm.expectRevert(ILiveMarket.BadBatch.selector);
        market.createMarkets(empty);

        ILiveMarket.MarketParams[] memory tooMany = new ILiveMarket.MarketParams[](MAX_CREATE_BATCH + 1);
        for (uint256 i; i < tooMany.length; i++) tooMany[i] = _params();
        vm.prank(resolver);
        vm.expectRevert(ILiveMarket.BadBatch.selector);
        market.createMarkets(tooMany);

        ILiveMarket.MarketParams[] memory max = new ILiveMarket.MarketParams[](MAX_CREATE_BATCH);
        for (uint256 i; i < max.length; i++) max[i] = _params();
        _createBatch(max);
        assertEq(market.nextMarketId(), MAX_CREATE_BATCH + 1);
    }

    function _expectInvalid(ILiveMarket.MarketParams memory bad) internal {
        // pasar valid di index 0, yang salah di index 1: index di error harus 1
        ILiveMarket.MarketParams[] memory p = new ILiveMarket.MarketParams[](2);
        p[0] = _params();
        p[1] = bad;
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.InvalidParams.selector, 1));
        market.createMarkets(p);
    }

    function test_gameRefLength() public {
        _expectInvalid(_params("", 31, 34));
        bytes memory longRef = new bytes(MAX_GAMEREF_BYTES + 1);
        for (uint256 i; i < longRef.length; i++) longRef[i] = "a";
        _expectInvalid(_params(string(longRef), 31, 34));

        bytes memory maxRef = new bytes(MAX_GAMEREF_BYTES);
        for (uint256 i; i < maxRef.length; i++) maxRef[i] = "a";
        _createBatch(_wrap(_params(string(maxRef), 31, 34)));
    }

    function test_plyRange() public {
        _expectInvalid(_params(GAME, 0, 4));
        _expectInvalid(_params(GAME, 10, 9));
        _expectInvalid(_params(GAME, 1, MAX_WINDOW_PLIES + 1));
        _createBatch(_wrap(_params(GAME, 1, MAX_WINDOW_PLIES)));
        _createBatch(_wrap(_params(GAME, 7, 7)));
    }

    function test_lockTimeWindow() public {
        ILiveMarket.MarketParams memory p = _params();
        p.lockTime = uint64(block.timestamp);
        _expectInvalid(p);
        p.lockTime = uint64(block.timestamp) + MAX_BET_WINDOW_SEC + 1;
        p.resolveDeadline = p.lockTime + 1;
        _expectInvalid(p);
        p.lockTime = uint64(block.timestamp) + MAX_BET_WINDOW_SEC;
        _createBatch(_wrap(p));
    }

    function test_resolveDeadlineWindow() public {
        ILiveMarket.MarketParams memory p = _params();
        p.resolveDeadline = p.lockTime;
        _expectInvalid(p);
        p.resolveDeadline = p.lockTime + MAX_RESOLVE_DELAY_SEC + 1;
        _expectInvalid(p);
        p.resolveDeadline = p.lockTime + MAX_RESOLVE_DELAY_SEC;
        _createBatch(_wrap(p));
    }

    function test_castleRequiresSide() public {
        ILiveMarket.MarketParams memory p = _params();
        p.marketType = MarketType.CASTLE;
        _expectInvalid(p);
        p.side = Side.WHITE;
        _createBatch(_wrap(p));

        p.marketType = MarketType.CAPTURE;
        p.side = Side.ANY;
        _createBatch(_wrap(p));
    }

    function test_gameRefStoredOnce() public {
        _create();
        assertEq(market.gameRefOf(keccak256(bytes(OTHER_GAME))), "");
        _createBatch(_wrap(_params(OTHER_GAME, 1, 4)));
        assertEq(market.gameRefOf(keccak256(bytes(OTHER_GAME))), OTHER_GAME);
    }
}
