// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";

contract RequestResolutionTest is Base {
    function _request(string memory gameRef, uint256[] memory ids) internal {
        vm.prank(resolver);
        market.requestResolution(gameRef, ids);
    }

    function test_onlyResolver() public {
        uint256 id = _create();
        _warpToLock(id);
        vm.prank(stranger);
        vm.expectRevert(ILiveMarket.NotResolver.selector);
        market.requestResolution(GAME, _ids(id));
    }

    function test_batchBounds() public {
        vm.prank(resolver);
        vm.expectRevert(ILiveMarket.BadBatch.selector);
        market.requestResolution(GAME, new uint256[](0));

        uint256[] memory ids = _createN(MAX_RESOLVE_BATCH + 1);
        _warpToLock(ids[0]);
        uint256[] memory tooMany = ids;
        vm.prank(resolver);
        vm.expectRevert(ILiveMarket.BadBatch.selector);
        market.requestResolution(GAME, tooMany);

        uint256 max = MAX_RESOLVE_BATCH;
        assembly {
            mstore(ids, max) // potong array menjadi MAX_RESOLVE_BATCH
        }
        _request(GAME, ids);
    }

    function test_setsFlagAndEmits() public {
        uint256[] memory ids = _createN(2);
        _warpToLock(ids[0]);
        vm.expectEmit(address(market));
        emit ILiveMarket.ResolutionRequested(GAME_KEY, GAME, ids);
        _request(GAME, ids);
        assertTrue(market.getMarket(ids[0]).resolutionRequested);
        assertTrue(market.getMarket(ids[1]).resolutionRequested);
        _request(GAME, ids); // retry boleh
    }

    function test_skipsNonOpenAndEmitsRemaining() public {
        uint256[] memory ids = _createN(3);
        market.adminVoid(_ids(ids[1]));
        _warpToLock(ids[0]);
        vm.expectEmit(address(market));
        emit ILiveMarket.ResolutionRequested(GAME_KEY, GAME, _ids(ids[0], ids[2]));
        _request(GAME, ids);
        assertFalse(market.getMarket(ids[1]).resolutionRequested);
    }

    function test_allNonOpenReverts() public {
        uint256[] memory ids = _createN(2);
        market.adminVoid(ids);
        _warpToLock(ids[0]);
        vm.prank(resolver);
        vm.expectRevert(ILiveMarket.BadBatch.selector);
        market.requestResolution(GAME, ids);
    }

    function test_gameKeyMismatchReverts() public {
        uint256 id = _create();
        _warpToLock(id);
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.InvalidMarket.selector, id));
        market.requestResolution(OTHER_GAME, _ids(id));
    }

    function test_beforeLockTimeReverts() public {
        uint256 id = _create();
        vm.warp(market.getMarket(id).lockTime - 1);
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.InvalidMarket.selector, id));
        market.requestResolution(GAME, _ids(id));
    }

    function test_lockedByLockMarketsCanRequestImmediately() public {
        uint256 id = _create();
        vm.prank(resolver);
        market.lockMarkets(_ids(id));
        _request(GAME, _ids(id));
        assertTrue(market.getMarket(id).resolutionRequested);
    }

    function test_unknownMarketReverts() public {
        uint256 id = _create();
        _warpToLock(id);
        vm.prank(resolver);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.InvalidMarket.selector, 77));
        market.requestResolution(GAME, _ids(id, 77));
    }

    function test_worksWhilePaused() public {
        uint256 id = _create();
        _warpToLock(id);
        market.pause();
        _request(GAME, _ids(id));
    }
}
