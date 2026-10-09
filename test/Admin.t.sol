// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AdminTest is Base {
    function _expectNotOwner() internal {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
    }

    function test_initialState() public view {
        assertEq(market.owner(), address(this));
        assertEq(market.token(), address(usdc));
        assertEq(market.forwarder(), address(fwd));
        assertEq(market.resolver(), resolver);
        assertEq(market.nextMarketId(), 1);
        assertEq(market.feesAccrued(), 0);
        string memory sot = vm.readFile("../source/sot/constants.json");
        assertEq(market.feeBps(), vm.parseJsonUint(sot, ".contract.defaults.feeBps"));
        assertEq(market.minBet(), vm.parseJsonUint(sot, ".contract.defaults.minBet"));
        assertEq(market.maxStakePerUser(), vm.parseJsonUint(sot, ".contract.defaults.maxStakePerUser"));
    }

    function test_ownerCannotSetOutcome() public {
        uint256 id = _create();
        _bet(alice, id, true, USDC);
        _warpToLock(id);
        // owner bukan forwarder
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.UnauthorizedForwarder.selector, address(this)));
        market.onReport("", abi.encode(GAME_KEY, _ids(id), _outs(YES)));
        // satu-satunya kuasa owner atas hasil: void, dan hanya untuk pasar OPEN
        market.adminVoid(_ids(id));
        assertEq(uint8(market.getMarket(id).outcome), VOID);

        uint256 resolved = _create();
        _bet(alice, resolved, true, USDC);
        _warpToLock(resolved);
        _report(resolved, YES);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.MarketNotOpen.selector, resolved));
        market.adminVoid(_ids(resolved));
        assertEq(uint8(market.getMarket(resolved).outcome), YES);
    }

    function test_adminVoidUnknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.MarketNotOpen.selector, 5));
        market.adminVoid(_ids(5));
    }

    function test_setForwarderSwitchesWhoCanReport() public {
        MockForwarder keystone = new MockForwarder();
        vm.expectEmit(address(market));
        emit ILiveMarket.ForwarderUpdated(address(keystone));
        market.setForwarder(address(keystone));
        assertEq(market.forwarder(), address(keystone));

        uint256 id = _create();
        _warpToLock(id);
        bytes memory report = abi.encode(GAME_KEY, _ids(id), _outs(VOID));
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.UnauthorizedForwarder.selector, address(fwd)));
        fwd.forward(address(market), "", report);
        keystone.forward(address(market), "", report);
        assertEq(uint8(market.getMarket(id).status), uint8(Status.VOIDED));
    }

    function test_setResolver() public {
        vm.expectEmit(address(market));
        emit ILiveMarket.ResolverUpdated(alice);
        market.setResolver(alice);
        assertEq(market.resolver(), alice);
        ILiveMarket.MarketParams[] memory p = _wrap(_params());
        vm.prank(resolver);
        vm.expectRevert(ILiveMarket.NotResolver.selector);
        market.createMarkets(p);
        vm.prank(alice);
        market.createMarkets(p);
    }

    function test_setFeeBps() public {
        market.setFeeBps(MAX_FEE_BPS);
        assertEq(market.feeBps(), MAX_FEE_BPS);
        vm.expectRevert(ILiveMarket.FeeTooHigh.selector);
        market.setFeeBps(MAX_FEE_BPS + 1);
    }

    function test_setLimits() public {
        market.setLimits(2 * USDC, 5 * USDC);
        assertEq(market.minBet(), 2 * USDC);
        assertEq(market.maxStakePerUser(), 5 * USDC);
    }

    function test_withdrawFees() public {
        uint256 id = _create();
        _bet(alice, id, true, 50 * USDC);
        _bet(bob, id, false, 50 * USDC);
        _warpToLock(id);
        _report(id, YES);
        uint256 fees = market.feesAccrued();
        assertEq(fees, 2 * USDC);

        vm.expectEmit(address(market));
        emit ILiveMarket.FeesWithdrawn(carol, fees);
        market.withdrawFees(carol);
        assertEq(usdc.balanceOf(carol), fees);
        assertEq(market.feesAccrued(), 0);

        vm.prank(alice);
        market.claim(id); // fee yang ditarik tidak mengurangi bagian pemenang
        assertEq(usdc.balanceOf(alice), 98 * USDC);
    }

    function test_onlyOwner() public {
        _expectNotOwner();
        market.adminVoid(_ids(1));
        _expectNotOwner();
        market.setForwarder(stranger);
        _expectNotOwner();
        market.setResolver(stranger);
        _expectNotOwner();
        market.setFeeBps(0);
        _expectNotOwner();
        market.setLimits(0, 0);
        _expectNotOwner();
        market.withdrawFees(stranger);
        _expectNotOwner();
        market.pause();
        _expectNotOwner();
        market.unpause();
    }

    function test_pauseUnpause() public {
        market.pause();
        assertTrue(market.paused());
        market.unpause();
        _create();
    }

    function test_getMarketsView() public {
        uint256 a = _create();
        ILiveMarket.MarketParams memory p = _params(OTHER_GAME, 5, 9);
        p.marketType = MarketType.CASTLE;
        p.side = Side.BLACK;
        uint256 b = _createBatch(_wrap(p));
        market.adminVoid(_ids(b));

        ILiveMarket.MarketView[] memory v = market.getMarkets(_ids(a, b));
        assertEq(v.length, 2);
        assertEq(v[0].id, a);
        assertEq(v[0].gameKey, GAME_KEY);
        assertEq(v[0].fromPly, 31);
        assertEq(v[0].status, uint8(Status.OPEN));
        assertEq(v[1].id, b);
        assertEq(v[1].gameKey, keccak256(bytes(OTHER_GAME)));
        assertEq(v[1].marketType, uint8(MarketType.CASTLE));
        assertEq(v[1].side, uint8(Side.BLACK));
        assertEq(v[1].fromPly, 5);
        assertEq(v[1].toPly, 9);
        assertEq(v[1].lockTime, p.lockTime);
        assertEq(v[1].status, uint8(Status.VOIDED));
    }
}
