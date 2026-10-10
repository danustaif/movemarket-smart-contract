// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployGatedForwarder} from "../script/DeployGatedForwarder.s.sol";
import {GatedForwarder} from "../src/GatedForwarder.sol";

contract DeployGatedForwarderTest is Test {
    address operator = makeAddr("operator");
    DeployGatedForwarder script = new DeployGatedForwarder();

    function test_runReadsOperatorFromEnv() public {
        vm.setEnv("OPERATOR_ADDRESS", vm.toString(operator));
        GatedForwarder gf = script.run();
        assertEq(gf.operator(), operator);
    }

    function test_rejectsOtherChains() public {
        vm.chainId(1);
        vm.expectRevert(bytes("DeployGatedForwarder: hanya Monad Testnet (10143) atau anvil (31337)"));
        script.deploy(operator);
    }
}
