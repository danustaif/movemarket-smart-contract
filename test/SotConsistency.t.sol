// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiveMarket} from "../src/LiveMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import "../src/interfaces/LiveMarketTypes.sol";

/// @notice Solidity tidak bisa mengimpor sot/constants.json, jadi test ini yang menangkap drift
///         antara literal di src/ dan SOT.
contract SotConsistencyTest is Test {
    string sot;

    function setUp() public {
        sot = vm.readFile("../source/sot/constants.json");
    }

    function _uint(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(sot, key);
    }

    function test_liveMarketDefaultsMatchSot() public {
        LiveMarket market = new LiveMarket(IERC20(address(1)), address(2), address(3));
        assertEq(market.feeBps(), _uint(".contract.defaults.feeBps"), "feeBps");
        assertEq(market.minBet(), _uint(".contract.defaults.minBet"), "minBet");
        assertEq(market.maxStakePerUser(), _uint(".contract.defaults.maxStakePerUser"), "maxStakePerUser");
    }

    function test_maxConstantsMatchSot() public view {
        assertEq(MAX_CREATE_BATCH, _uint(".contract.MAX_CREATE_BATCH"), "MAX_CREATE_BATCH");
        assertEq(MAX_RESOLVE_BATCH, _uint(".contract.MAX_RESOLVE_BATCH"), "MAX_RESOLVE_BATCH");
        assertEq(MAX_LOCK_BATCH, _uint(".contract.MAX_LOCK_BATCH"), "MAX_LOCK_BATCH");
        assertEq(MAX_WINDOW_PLIES, _uint(".contract.MAX_WINDOW_PLIES"), "MAX_WINDOW_PLIES");
        assertEq(MAX_BET_WINDOW_SEC, _uint(".contract.MAX_BET_WINDOW_SEC"), "MAX_BET_WINDOW_SEC");
        assertEq(MAX_RESOLVE_DELAY_SEC, _uint(".contract.MAX_RESOLVE_DELAY_SEC"), "MAX_RESOLVE_DELAY_SEC");
        assertEq(MAX_FEE_BPS, _uint(".contract.MAX_FEE_BPS"), "MAX_FEE_BPS");
        assertEq(MAX_GAMEREF_BYTES, _uint(".contract.MAX_GAMEREF_BYTES"), "MAX_GAMEREF_BYTES");
    }

    function _reason(string memory group, uint8 code, string memory name) internal view {
        string memory key = string.concat(".enums.", group, ".", vm.toString(code));
        assertEq(vm.parseJsonString(sot, key), name, key);
    }

    function test_voidAndSkipReasonsMatchSot() public view {
        assertEq(vm.parseJsonKeys(sot, ".enums.VoidReason").length, 4, "jumlah VoidReason");
        _reason("VoidReason", VOID_ORACLE, "ORACLE");
        _reason("VoidReason", VOID_NO_WINNERS, "NO_WINNERS");
        _reason("VoidReason", VOID_ADMIN, "ADMIN");
        _reason("VoidReason", VOID_EXPIRED, "EXPIRED");

        assertEq(vm.parseJsonKeys(sot, ".enums.SkipReason").length, 5, "jumlah SkipReason");
        _reason("SkipReason", SKIP_MARKET_NOT_FOUND, "MARKET_NOT_FOUND");
        _reason("SkipReason", SKIP_GAME_MISMATCH, "GAME_MISMATCH");
        _reason("SkipReason", SKIP_NOT_OPEN, "NOT_OPEN");
        _reason("SkipReason", SKIP_NOT_LOCKED, "NOT_LOCKED");
        _reason("SkipReason", SKIP_BAD_OUTCOME, "BAD_OUTCOME");
    }

    function test_enumLengthsMatchSot() public view {
        assertEq(vm.parseJsonStringArray(sot, ".enums.MarketType").length, uint256(type(MarketType).max) + 1);
        assertEq(vm.parseJsonStringArray(sot, ".enums.Side").length, uint256(type(Side).max) + 1);
        assertEq(vm.parseJsonStringArray(sot, ".enums.Status").length, uint256(type(Status).max) + 1);
        assertEq(vm.parseJsonStringArray(sot, ".enums.Outcome").length, uint256(type(Outcome).max) + 1);
    }

    function test_mockUsdcMatchesSotToken() public {
        MockUSDC usdc = new MockUSDC();
        assertEq(usdc.name(), vm.parseJsonString(sot, ".token.name"));
        assertEq(usdc.symbol(), vm.parseJsonString(sot, ".token.symbol"));
        assertEq(usdc.decimals(), _uint(".token.decimals"));
    }
}
