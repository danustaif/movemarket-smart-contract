// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {LiveMarket} from "../src/LiveMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

contract DeployTest is Test {
    address resolver = makeAddr("resolver");
    Deploy script = new Deploy();

    function test_defaultForwarderIsSotMockForwarder() public view {
        string memory sot = vm.readFile("../source/sot/constants.json");
        assertEq(script.sotForwarder(), vm.parseJsonAddress(sot, ".addresses.creMockKeystoneForwarder"));
        assertTrue(script.sotForwarder() != address(0));
    }

    function test_deployWiresTokenForwarderResolverAndMinter() public {
        address forwarder = script.sotForwarder();
        (LiveMarket market, MockUSDC usdc) = script.deploy(forwarder, resolver);
        assertEq(market.forwarder(), forwarder);
        assertEq(market.resolver(), resolver);
        assertEq(market.token(), address(usdc));
        assertTrue(usdc.minters(resolver));
        assertEq(market.owner(), usdc.owner());
    }

    function test_runReadsResolverFromEnv() public {
        vm.setEnv("RESOLVER_ADDRESS", vm.toString(resolver));
        (LiveMarket market,) = script.run();
        assertEq(market.resolver(), resolver);
    }

    function test_rejectsOtherChains() public {
        vm.chainId(1);
        vm.expectRevert(bytes("Deploy: hanya Monad Testnet (10143) atau anvil (31337)"));
        script.deploy(address(1), resolver);
    }
}
