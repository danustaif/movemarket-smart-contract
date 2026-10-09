// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";
import {IReceiver} from "../src/interfaces/IReceiver.sol";
import {IERC165} from "../src/interfaces/IERC165.sol";

contract OnReportTest is Base {
    uint256 constant BPS = 10_000;
    uint256 constant REPORT_GAS_CEILING = 5_000_000; // CONTRACTS.md 7: batch 40 di bawah 5 juta gas

    uint256 id;

    function setUp() public override {
        super.setUp();
        id = _create();
    }

    function test_rejectsNonForwarder() public {
        bytes memory report = abi.encode(GAME_KEY, _ids(id), _outs(YES));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.UnauthorizedForwarder.selector, stranger));
        market.onReport("", report);
        // owner juga bukan forwarder
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.UnauthorizedForwarder.selector, address(this)));
        market.onReport("", report);
    }

    function test_lengthMismatchIsBadReport() public {
        vm.expectRevert(ILiveMarket.BadReport.selector);
        _report(GAME_KEY, _ids(id), _outs(YES, NO));
    }

    function test_oversizedBatchIsBadReport() public {
        uint256 n = MAX_RESOLVE_BATCH + 1;
        vm.expectRevert(ILiveMarket.BadReport.selector);
        _report(GAME_KEY, new uint256[](n), new uint8[](n));
    }

    function test_resolvesYesWithFeeWhenBothPoolsFilled() public {
        _bet(alice, id, true, 30 * USDC);
        _bet(bob, id, false, 70 * USDC);
        _warpToLock(id);

        vm.expectEmit(address(market));
        emit ILiveMarket.MarketResolved(id, YES);
        _report(id, YES);

        ILiveMarket.Market memory m = market.getMarket(id);
        uint256 expectedFee = 100 * USDC * market.feeBps() / BPS;
        assertEq(uint8(m.status), uint8(Status.RESOLVED));
        assertEq(uint8(m.outcome), YES);
        assertEq(m.fee, expectedFee);
        assertEq(market.feesAccrued(), expectedFee);
    }

    function test_noFeeWhenLosingPoolEmpty() public {
        _bet(alice, id, false, 30 * USDC);
        _warpToLock(id);
        _report(id, NO);
        ILiveMarket.Market memory m = market.getMarket(id);
        assertEq(uint8(m.outcome), NO);
        assertEq(m.fee, 0);
        assertEq(market.feesAccrued(), 0);
    }

    function test_voidOutcome() public {
        _bet(alice, id, true, 10 * USDC);
        _warpToLock(id);
        vm.expectEmit(address(market));
        emit ILiveMarket.MarketVoided(id, VOID_ORACLE);
        _report(id, VOID);
        ILiveMarket.Market memory m = market.getMarket(id);
        assertEq(uint8(m.status), uint8(Status.VOIDED));
        assertEq(uint8(m.outcome), VOID);
        assertEq(m.fee, 0);
    }

    function test_emptyWinningPoolVoidsNoWinners() public {
        _bet(alice, id, false, 10 * USDC);
        _warpToLock(id);
        vm.expectEmit(address(market));
        emit ILiveMarket.MarketVoided(id, VOID_NO_WINNERS);
        _report(id, YES);
        ILiveMarket.Market memory m = market.getMarket(id);
        assertEq(uint8(m.status), uint8(Status.VOIDED));
        assertEq(uint8(m.outcome), VOID);
        assertEq(market.feesAccrued(), 0);
    }

    function test_noStakeAtAllVoidsNoWinners() public {
        _warpToLock(id);
        vm.expectEmit(address(market));
        emit ILiveMarket.MarketVoided(id, VOID_NO_WINNERS);
        _report(id, NO);
    }

    function _expectSkip(uint256 marketId, uint8 reason) internal {
        vm.expectEmit(address(market));
        emit ILiveMarket.ResolutionSkipped(marketId, reason);
    }

    function test_skipMarketNotFound() public {
        _warpToLock(id);
        _expectSkip(42, SKIP_MARKET_NOT_FOUND);
        _report(42, YES);
        _expectSkip(0, SKIP_MARKET_NOT_FOUND);
        _report(0, YES);
    }

    function test_skipGameMismatch() public {
        _warpToLock(id);
        _expectSkip(id, SKIP_GAME_MISMATCH);
        _report(keccak256(bytes(OTHER_GAME)), _ids(id), _outs(YES));
        assertEq(uint8(market.getMarket(id).status), uint8(Status.OPEN));
    }

    function test_skipNotOpen() public {
        _bet(alice, id, true, USDC);
        _warpToLock(id);
        _report(id, YES);
        _expectSkip(id, SKIP_NOT_OPEN);
        _report(id, NO); // report kedua tidak mengubah hasil
        assertEq(uint8(market.getMarket(id).outcome), YES);
    }

    function test_skipNotLocked() public {
        vm.warp(market.getMarket(id).lockTime - 1);
        _expectSkip(id, SKIP_NOT_LOCKED);
        _report(id, YES);
        assertEq(uint8(market.getMarket(id).status), uint8(Status.OPEN));
    }

    function test_skipBadOutcome() public {
        _warpToLock(id);
        _expectSkip(id, SKIP_BAD_OUTCOME);
        _report(id, uint8(Outcome.NONE));
        _expectSkip(id, SKIP_BAD_OUTCOME);
        _report(id, VOID + 1);
        assertEq(uint8(market.getMarket(id).status), uint8(Status.OPEN));
    }

    function test_mixedBatchDecodesPerMarket() public {
        uint256 id2 = _create();
        _bet(alice, id, true, USDC);
        _bet(alice, id2, false, USDC);
        _warpToLock(id);
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (id, 99, id2);
        uint8[] memory outs = new uint8[](3);
        (outs[0], outs[1], outs[2]) = (YES, YES, NO);
        _report(GAME_KEY, ids, outs);
        assertEq(uint8(market.getMarket(id).outcome), YES);
        assertEq(uint8(market.getMarket(id2).outcome), NO);
    }

    function test_worksWhilePaused() public {
        _bet(alice, id, true, USDC);
        _warpToLock(id);
        market.pause();
        _report(id, YES);
        assertEq(uint8(market.getMarket(id).status), uint8(Status.RESOLVED));
    }

    function test_feeUsesCurrentFeeBps() public {
        _bet(alice, id, true, 50 * USDC);
        _bet(bob, id, false, 50 * USDC);
        market.setFeeBps(MAX_FEE_BPS);
        _warpToLock(id);
        _report(id, YES);
        assertEq(market.getMarket(id).fee, 100 * USDC * MAX_FEE_BPS / BPS);
    }

    function test_supportsInterface() public view {
        assertTrue(market.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(market.supportsInterface(type(IERC165).interfaceId));
        assertFalse(market.supportsInterface(0xffffffff));
    }

    function _measureReport(uint256 n) internal returns (uint256 gasUsed) {
        uint256[] memory ids = _createN(n);
        uint8[] memory outs = new uint8[](n);
        for (uint256 i; i < n; i++) {
            _bet(alice, ids[i], true, USDC);
            _bet(bob, ids[i], false, USDC);
            outs[i] = YES;
        }
        _warpToLock(ids[0]);
        bytes memory report = abi.encode(GAME_KEY, ids, outs);
        vm.cool(address(market)); // ukur dengan storage dingin, seperti transaksi report sungguhan
        uint256 before = gasleft();
        fwd.forward(address(market), "", report);
        gasUsed = before - gasleft();
        for (uint256 i; i < n; i++) {
            assertEq(uint8(market.getMarket(ids[i]).status), uint8(Status.RESOLVED));
        }
    }

    function test_gas_reportBatch8() public {
        uint256 used = _measureReport(8);
        emit log_named_uint("onReport gas batch 8", used);
    }

    function test_gas_reportBatch40UnderCeiling() public {
        uint256 used = _measureReport(MAX_RESOLVE_BATCH);
        emit log_named_uint("onReport gas batch 40", used);
        assertLt(used, REPORT_GAS_CEILING);
    }
}
