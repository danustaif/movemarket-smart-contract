// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Base.t.sol";
import {GatedForwarder} from "../src/GatedForwarder.sol";
import {RecordingReceiver} from "./mocks/RecordingReceiver.sol";

/// @dev rawReport = metadata 109 byte (layout mockRunner.ts reportMetadata) + body.
function _raw(bytes32 execId, bytes2 reportId, bytes memory body) pure returns (bytes memory) {
    return bytes.concat(
        hex"01",
        execId,
        bytes4(uint32(1_760_000_000)),
        bytes4(uint32(1)),
        bytes4(uint32(1)),
        bytes32(uint256(0x11)),
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes10("mock-cre"), // literal 8 byte, tidak terpotong
        bytes20(address(0xAA)),
        reportId,
        body
    );
}

/// @notice GatedForwarder (SOT D24): ABI dan perilaku sama dengan MockKeystoneForwarder Chainlink, kecuali hanya operator.
contract GatedForwarderTest is Test {
    GatedForwarder gf;
    address operator = makeAddr("operator");
    address receiver = makeAddr("receiver");
    RecordingReceiver rec;

    bytes32 constant EXEC_ID = keccak256("exec");
    bytes2 constant REPORT_ID = 0x0001;

    function setUp() public {
        gf = new GatedForwarder(operator);
        rec = new RecordingReceiver();
    }

    function test_reportSelectorSameAsMockKeystoneForwarder() public pure {
        // cast sig "report(address,bytes,bytes,bytes[])"; selector yang dipanggil mockRunner.ts
        assertEq(GatedForwarder.report.selector, bytes4(0x11289565));
    }

    function test_reportProcessedTopicSameAsMockKeystoneForwarder() public pure {
        // topic0 log MockKeystoneForwarder 0xB9F79d... di tx Monad Testnet 0x72025fc0...0c53 (receipt, 10 Okt 2026)
        assertEq(
            GatedForwarder.ReportProcessed.selector, 0x3617b009e9785c42daebadb6d3fb553243a4bf586d07ea72d65d80013ce116b5
        );
    }

    function test_operatorFromConstructor() public view {
        assertEq(gf.operator(), operator);
    }

    function test_rejectsNonOperator() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GatedForwarder.NotOperator.selector, stranger));
        gf.report(receiver, _raw(bytes32(0), 0x0001, ""), "", new bytes[](0));
    }

    function test_forwardsMetadataAndBodyWithMockSlicing() public {
        bytes memory body = abi.encode(bytes32(uint256(7)), new uint256[](0), new uint8[](0));
        bytes memory raw = _raw(EXEC_ID, REPORT_ID, body);

        vm.expectEmit(address(gf));
        emit GatedForwarder.ReportProcessed(address(rec), EXEC_ID, REPORT_ID, true);
        vm.prank(operator);
        gf.report(address(rec), raw, hex"dead", new bytes[](1)); // reportContext dan signatures diabaikan

        // MockKeystoneForwarder: onReport(rawReport[45:109], rawReport[109:])
        bytes memory meta = rec.metadata();
        assertEq(meta.length, 64);
        assertEq(keccak256(meta), keccak256(_slice(raw, 45, 109)));
        assertEq(rec.report(), body);
        assertEq(rec.caller(), address(gf));
    }

    function test_metadataOnlyReportForwardsEmptyBody() public {
        vm.prank(operator);
        gf.report(address(rec), _raw(EXEC_ID, REPORT_ID, ""), "", new bytes[](0));
        assertEq(rec.metadata().length, 64);
        assertEq(rec.report().length, 0);
    }

    function test_rejectsReportShorterThanMetadata() public {
        bytes memory raw = _raw(EXEC_ID, REPORT_ID, "");
        assembly { mstore(raw, 108) } // 108 byte
        vm.prank(operator);
        vm.expectRevert(GatedForwarder.InvalidReport.selector);
        gf.report(address(rec), raw, "", new bytes[](0));
    }

    function test_receiverRevertEmitsResultFalseWithoutReverting() public {
        rec.setFail(true);
        vm.expectEmit(address(gf));
        emit GatedForwarder.ReportProcessed(address(rec), EXEC_ID, REPORT_ID, false);
        vm.prank(operator);
        gf.report(address(rec), _raw(EXEC_ID, REPORT_ID, hex"01"), "", new bytes[](0));
    }

    function test_receiverWithoutCodeIsResultFalse() public {
        vm.expectEmit(address(gf));
        emit GatedForwarder.ReportProcessed(receiver, EXEC_ID, REPORT_ID, false);
        vm.prank(operator);
        gf.report(receiver, _raw(EXEC_ID, REPORT_ID, hex"01"), "", new bytes[](0));
    }

    function _slice(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory r) {
        r = new bytes(to - from);
        for (uint256 i; i < r.length; i++) {
            r[i] = b[from + i];
        }
    }
}

/// @notice LiveMarket dengan forwarder = GatedForwarder (operator = wallet resolver), seperti setelah setForwarder D24.
contract GatedForwarderLiveMarketTest is Base {
    GatedForwarder gf;
    uint256 id;

    function setUp() public override {
        super.setUp();
        gf = new GatedForwarder(resolver);
        market.setForwarder(address(gf));
        id = _create();
        _bet(alice, id, true, 10 * USDC);
        _bet(bob, id, false, 10 * USDC);
        _warpToLock(id);
    }

    function _send(address from, uint8 outcome) internal {
        vm.prank(from);
        gf.report(
            address(market),
            _raw(keccak256("exec"), 0x0001, abi.encode(GAME_KEY, _ids(id), _outs(outcome))),
            "",
            new bytes[](0)
        );
    }

    function test_operatorReportResolvesMarket() public {
        vm.expectEmit(address(gf));
        emit GatedForwarder.ReportProcessed(address(market), keccak256("exec"), 0x0001, true);
        _send(resolver, YES);
        ILiveMarket.Market memory m = market.getMarket(id);
        assertEq(uint8(m.status), uint8(Status.RESOLVED));
        assertEq(uint8(m.outcome), uint8(Outcome.YES));
    }

    function test_reportFromOtherAddressReverts() public {
        for (uint256 i; i < 3; i++) {
            address from = [stranger, address(this), alice][i]; // owner LiveMarket juga ditolak
            vm.prank(from);
            vm.expectRevert(abi.encodeWithSelector(GatedForwarder.NotOperator.selector, from));
            gf.report(address(market), _raw(0, 0x0001, abi.encode(GAME_KEY, _ids(id), _outs(YES))), "", new bytes[](0));
        }
        assertEq(uint8(market.getMarket(id).status), uint8(Status.OPEN));
    }

    function test_liveMarketStillRejectsDirectOnReport() public {
        bytes memory report = abi.encode(GAME_KEY, _ids(id), _outs(YES));
        vm.prank(resolver); // operator forwarder pun bukan forwarder
        vm.expectRevert(abi.encodeWithSelector(ILiveMarket.UnauthorizedForwarder.selector, resolver));
        market.onReport("", report);
    }

    function test_afterSetForwarderAwayReportIsResultFalse() public {
        market.setForwarder(address(fwd)); // kembali ke forwarder lain (mis. Chainlink)
        vm.expectEmit(address(gf));
        emit GatedForwarder.ReportProcessed(address(market), keccak256("exec"), 0x0001, false);
        _send(resolver, YES);
        assertEq(uint8(market.getMarket(id).status), uint8(Status.OPEN));
    }
}
