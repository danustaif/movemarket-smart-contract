// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiveMarket} from "../src/LiveMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {ILiveMarket} from "../src/interfaces/ILiveMarket.sol";
import "../src/interfaces/LiveMarketTypes.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockForwarder} from "./mocks/MockForwarder.sol";

/// @notice Setup bersama: tUSDC, forwarder tiruan, LiveMarket, dan helper.
abstract contract Base is Test {
    LiveMarket market;
    MockUSDC usdc;
    MockForwarder fwd;

    address resolver = makeAddr("resolver");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address stranger = makeAddr("stranger");

    string constant GAME = "lichess:game:abcd1234";
    string constant OTHER_GAME = "lichess:game:zzzz9999";
    bytes32 immutable GAME_KEY = keccak256(bytes(GAME));

    uint128 constant USDC = 1e6; // 1 tUSDC, sot token.decimals = 6
    uint64 constant BET_WINDOW = 60; // jarak createMarkets ke lockTime di test
    uint64 constant RESOLVE_DELAY = 3600; // jarak lockTime ke resolveDeadline di test

    uint8 constant YES = uint8(Outcome.YES);
    uint8 constant NO = uint8(Outcome.NO);
    uint8 constant VOID = uint8(Outcome.VOID);

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        usdc = new MockUSDC();
        fwd = new MockForwarder();
        market = new LiveMarket(IERC20(address(usdc)), address(fwd), resolver);
        usdc.setMinter(address(this), true);
    }

    function _params(string memory gameRef, uint16 fromPly, uint16 toPly)
        internal
        view
        returns (ILiveMarket.MarketParams memory)
    {
        uint64 lockTime = uint64(block.timestamp) + BET_WINDOW;
        return ILiveMarket.MarketParams(
            gameRef, MarketType.CHECK, Side.ANY, fromPly, toPly, lockTime, lockTime + RESOLVE_DELAY
        );
    }

    function _params() internal view returns (ILiveMarket.MarketParams memory) {
        return _params(GAME, 31, 34);
    }

    function _createBatch(ILiveMarket.MarketParams[] memory p) internal returns (uint256 firstId) {
        vm.prank(resolver);
        firstId = market.createMarkets(p);
    }

    function _create() internal returns (uint256) {
        return _createBatch(_wrap(_params()));
    }

    /// @dev n pasar untuk partai GAME, id berurutan.
    function _createN(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        uint256 left = n;
        uint256 k;
        while (left > 0) {
            uint256 size = left > MAX_CREATE_BATCH ? MAX_CREATE_BATCH : left;
            ILiveMarket.MarketParams[] memory p = new ILiveMarket.MarketParams[](size);
            for (uint256 i; i < size; i++) p[i] = _params();
            uint256 first = _createBatch(p);
            for (uint256 i; i < size; i++) ids[k++] = first + i;
            left -= size;
        }
    }

    function _bet(address user, uint256 id, bool yes, uint128 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(market), amount);
        market.bet(id, yes, amount);
        vm.stopPrank();
    }

    function _warpToLock(uint256 id) internal {
        vm.warp(market.getMarket(id).lockTime);
    }

    function _report(bytes32 gameKey, uint256[] memory ids, uint8[] memory outcomes) internal {
        fwd.forward(address(market), "", abi.encode(gameKey, ids, outcomes));
    }

    function _report(uint256 id, uint8 outcome) internal {
        _report(GAME_KEY, _ids(id), _outs(outcome));
    }

    function _wrap(ILiveMarket.MarketParams memory p) internal pure returns (ILiveMarket.MarketParams[] memory a) {
        a = new ILiveMarket.MarketParams[](1);
        a[0] = p;
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        (r[0], r[1]) = (a, b);
    }

    function _outs(uint8 a) internal pure returns (uint8[] memory r) {
        r = new uint8[](1);
        r[0] = a;
    }

    function _outs(uint8 a, uint8 b) internal pure returns (uint8[] memory r) {
        r = new uint8[](2);
        (r[0], r[1]) = (a, b);
    }
}
