// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiveMarket} from "../src/LiveMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ILiveMarket} from "../src/interfaces/ILiveMarket.sol";
import "../src/interfaces/LiveMarketTypes.sol";
import {MockForwarder} from "./mocks/MockForwarder.sol";

/// @notice Aksi acak terhadap LiveMarket plus catatan "ghost" untuk dicek oleh InvariantTest.
///         Handler ini adalah owner dan resolver; report lewat MockForwarder.
contract Handler is Test {
    uint256 constant MAX_MARKETS = 12;
    uint256 constant MAX_WARP = 120; // lompatan waktu kecil supaya pasar sempat menerima bet sebelum terkunci
    string constant GAME = "lichess:game:invariant";

    LiveMarket immutable market;
    MockUSDC immutable usdc;
    MockForwarder immutable fwd;
    bytes32 immutable gameKey = keccak256(bytes(GAME));

    address[] actors;
    uint256[] public ids;

    mapping(uint256 => uint256) public paid;
    mapping(uint256 => uint256) public refunded;
    mapping(uint256 => uint64) public initialLock;
    mapping(uint256 => bool) public resolvedByForwarder;
    mapping(uint256 => mapping(address => uint256)) public settleCount;
    mapping(uint256 => bool) finalized;
    mapping(uint256 => Status) finalStatus;
    mapping(uint256 => Outcome) finalOutcome;
    bool public betAfterLock;
    bool public finalChanged;

    constructor(LiveMarket market_, MockUSDC usdc_, MockForwarder fwd_) {
        (market, usdc, fwd) = (market_, usdc_, fwd_);
        for (uint256 i; i < 4; i++) actors.push(makeAddr(string(abi.encodePacked("actor", vm.toString(i)))));
    }

    function marketCount() external view returns (uint256) {
        return ids.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    modifier tracked() {
        _;
        // invarian 2: status/outcome final tidak pernah berubah
        for (uint256 i; i < ids.length; i++) {
            ILiveMarket.Market memory m = market.getMarket(ids[i]);
            if (finalized[ids[i]]) {
                if (m.status != finalStatus[ids[i]] || m.outcome != finalOutcome[ids[i]]) finalChanged = true;
            } else if (m.status != Status.OPEN) {
                finalized[ids[i]] = true;
                finalStatus[ids[i]] = m.status;
                finalOutcome[ids[i]] = m.outcome;
            }
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _id(uint256 seed) internal view returns (uint256) {
        // sesekali id yang tidak ada
        return ids.length == 0 || seed % 10 == 0 ? 1000 + seed % 3 : ids[seed % ids.length];
    }

    function create(uint256 lockSeed, uint256 delaySeed) external tracked {
        if (ids.length >= MAX_MARKETS) return;
        uint64 lockTime = uint64(block.timestamp + bound(lockSeed, 1, MAX_WARP));
        uint64 deadline = lockTime + uint64(bound(delaySeed, 1, 2 * MAX_BET_WINDOW_SEC));
        ILiveMarket.MarketParams[] memory p = new ILiveMarket.MarketParams[](1);
        p[0] = ILiveMarket.MarketParams(GAME, MarketType.CHECK, Side.ANY, 31, 34, lockTime, deadline);
        uint256 id = market.createMarkets(p);
        ids.push(id);
        initialLock[id] = lockTime;
        // pasar langsung punya stake di dua sisi, supaya report menghasilkan pemenang dan claim teruji
        _bet(_actor(lockSeed), id, true, lockSeed);
        _bet(_actor(delaySeed), id, false, delaySeed);
    }

    function bet(uint256 actorSeed, uint256 idSeed, bool yes, uint256 amountSeed) external tracked {
        _bet(_actor(actorSeed), _id(idSeed), yes, amountSeed);
    }

    function _bet(address user, uint256 id, bool yes, uint256 amountSeed) internal {
        uint128 amount = uint128(bound(amountSeed, market.minBet(), market.maxStakePerUser()));
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(market), amount);
        try market.bet(id, yes, amount) {
            if (block.timestamp >= market.getMarket(id).lockTime) betAfterLock = true;
        } catch {}
        vm.stopPrank();
    }

    function lock(uint256 idSeed) external tracked {
        uint256[] memory one = new uint256[](1);
        one[0] = _id(idSeed);
        market.lockMarkets(one);
    }

    function report(uint256 idSeed, uint256 outcomeSeed) external tracked {
        uint256[] memory one = new uint256[](1);
        one[0] = _id(idSeed);
        uint8[] memory outs = new uint8[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        outs[0] = uint8(1 + outcomeSeed % 3); // YES, NO, VOID
        bytes32 key = gameKey;
        // sesekali report yang harus di-skip: outcome tidak sah atau partai lain
        if (outcomeSeed % 16 == 0) outs[0] = uint8(Outcome.VOID) + 1;
        if (outcomeSeed % 16 == 1) key = bytes32(uint256(1));
        Status before = market.getMarket(one[0]).status;
        fwd.forward(address(market), "", abi.encode(key, one, outs));
        if (before == Status.OPEN && market.getMarket(one[0]).status == Status.RESOLVED) {
            resolvedByForwarder[one[0]] = true;
        }
    }

    /// invarian 7: onReport dari selain forwarder (termasuk owner/resolver) wajib revert
    /// UnauthorizedForwarder tanpa mengubah state, walaupun isi report sah.
    function reportFromStranger(uint256 callerSeed, uint256 idSeed, uint256 outcomeSeed) external tracked {
        address caller = callerSeed % 4 == 0 ? address(this) : address(uint160(bound(callerSeed, 1, type(uint160).max)));
        if (caller == address(fwd)) caller = address(uint160(caller) + 1);
        uint256[] memory one = new uint256[](1);
        one[0] = _id(idSeed);
        uint8[] memory outs = new uint8[](1);
        // forge-lint: disable-next-line(unsafe-typecast)
        outs[0] = uint8(1 + outcomeSeed % 3);

        bytes32 marketBefore = keccak256(abi.encode(market.getMarket(one[0])));
        uint256 feesBefore = market.feesAccrued();
        vm.prank(caller);
        try market.onReport("", abi.encode(gameKey, one, outs)) {
            fail("inv7: onReport dari selain forwarder diterima");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(ILiveMarket.UnauthorizedForwarder.selector, caller), "inv7: revert lain");
        }
        assertEq(keccak256(abi.encode(market.getMarket(one[0]))), marketBefore, "inv7: state pasar berubah");
        assertEq(market.feesAccrued(), feesBefore, "inv7: feesAccrued berubah");
    }

    function claim(uint256 actorSeed, uint256 idSeed) external tracked {
        address user = _actor(actorSeed);
        uint256 id = _id(idSeed);
        vm.prank(user);
        try market.claim(id) returns (uint256 payout) {
            paid[id] += payout;
            settleCount[id][user]++;
        } catch {}
    }

    function claimMany(uint256 actorSeed) external tracked {
        address user = _actor(actorSeed);
        uint256[] memory before = new uint256[](ids.length);
        bool[] memory wasSettled = new bool[](ids.length);
        for (uint256 i; i < ids.length; i++) {
            before[i] = market.claimable(ids[i], user);
            wasSettled[i] = market.getPosition(ids[i], user).settled;
        }
        vm.prank(user);
        uint256 total = market.claimMany(ids);
        uint256 sum;
        for (uint256 i; i < ids.length; i++) {
            if (!wasSettled[i] && market.getPosition(ids[i], user).settled) {
                paid[ids[i]] += before[i];
                settleCount[ids[i]][user]++;
                sum += before[i];
            }
        }
        assertEq(total, sum, "claimMany total != jumlah claimable");
    }

    function refund(uint256 actorSeed, uint256 idSeed) external tracked {
        address user = _actor(actorSeed);
        uint256 id = _id(idSeed);
        vm.prank(user);
        try market.refund(id) returns (uint256 amount) {
            refunded[id] += amount;
            settleCount[id][user]++;
        } catch {}
    }

    function adminVoid(uint256 idSeed) external tracked {
        uint256[] memory one = new uint256[](1);
        one[0] = _id(idSeed);
        try market.adminVoid(one) {} catch {}
    }

    function setFeeBps(uint256 seed) external tracked {
        market.setFeeBps(uint16(bound(seed, 0, MAX_FEE_BPS)));
    }

    function withdrawFees() external tracked {
        market.withdrawFees(address(0xFEE));
    }

    function warp(uint256 secs) external tracked {
        skip(bound(secs, 1, MAX_WARP));
    }
}

contract InvariantTest is Test {
    LiveMarket market;
    MockUSDC usdc;
    Handler handler;

    function setUp() public {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        MockForwarder fwd = new MockForwarder();
        market = new LiveMarket(IERC20(address(usdc)), address(fwd), address(0));
        handler = new Handler(market, usdc, fwd);
        market.setResolver(address(handler));
        market.transferOwnership(address(handler));
        usdc.setMinter(address(handler), true);
        targetContract(address(handler));
        // hanya aksi; getter publik handler bukan target fuzz
        bytes4[] memory actions = new bytes4[](12);
        actions[0] = Handler.create.selector;
        actions[1] = Handler.bet.selector;
        actions[2] = Handler.lock.selector;
        actions[3] = Handler.report.selector;
        actions[4] = Handler.claim.selector;
        actions[5] = Handler.claimMany.selector;
        actions[6] = Handler.refund.selector;
        actions[7] = Handler.adminVoid.selector;
        actions[8] = Handler.setFeeBps.selector;
        actions[9] = Handler.withdrawFees.selector;
        actions[10] = Handler.warp.selector;
        actions[11] = Handler.reportFromStranger.selector;
        targetSelector(FuzzSelector(address(handler), actions));
    }

    /// invarian 1 (dicek handler setiap bet sukses) dan 2 (dicek handler setelah setiap aksi)
    function invariant_noBetAfterLockAndFinalIsFinal() public view {
        assertFalse(handler.betAfterLock(), "BetPlaced saat block.timestamp >= lockTime");
        assertFalse(handler.finalChanged(), "status/outcome final berubah");
    }

    /// invarian 3, 4, 7, 8
    function invariant_perMarket() public view {
        for (uint256 i; i < handler.marketCount(); i++) {
            uint256 id = handler.ids(i);
            ILiveMarket.Market memory m = market.getMarket(id);
            uint256 total = uint256(m.poolYes) + m.poolNo;
            if (m.status == Status.RESOLVED) {
                assertLe(handler.paid(id), total - m.fee, "inv3: payout > pool - fee");
                assertTrue(handler.resolvedByForwarder(id), "inv7: RESOLVED bukan lewat forwarder");
                assertTrue(m.outcome == Outcome.YES || m.outcome == Outcome.NO, "RESOLVED tanpa YES/NO");
            } else {
                assertEq(handler.paid(id), 0, "payout dari pasar yang tidak RESOLVED");
            }
            if (m.status == Status.VOIDED) {
                assertLe(handler.refunded(id), total, "inv4: refund > pool");
                assertEq(m.fee, 0, "inv4: fee pasar VOIDED");
                assertTrue(m.outcome == Outcome.VOID, "VOIDED tanpa outcome VOID");
            } else {
                assertEq(handler.refunded(id), 0, "refund dari pasar yang tidak VOIDED");
            }
            assertLe(m.lockTime, handler.initialLock(id), "inv8: lockTime bertambah");
        }
    }

    /// invarian 5
    function invariant_settleOnce() public view {
        for (uint256 i; i < handler.marketCount(); i++) {
            uint256 id = handler.ids(i);
            for (uint256 a; a < handler.actorCount(); a++) {
                assertLe(handler.settleCount(id, handler.actorAt(a)), 1, "inv5: posisi di-settle dua kali");
            }
        }
    }

    /// invarian 6: saldo >= feesAccrued + kewajiban yang belum dibayar
    function invariant_solvent() public view {
        uint256 owed = market.feesAccrued();
        for (uint256 i; i < handler.marketCount(); i++) {
            uint256 id = handler.ids(i);
            ILiveMarket.Market memory m = market.getMarket(id);
            uint256 total = uint256(m.poolYes) + m.poolNo;
            if (m.status == Status.OPEN) owed += total;
            else if (m.status == Status.RESOLVED) owed += total - m.fee - handler.paid(id);
            else owed += total - handler.refunded(id);
        }
        assertGe(usdc.balanceOf(address(market)), owed, "inv6: saldo kurang dari kewajiban");
    }
}
