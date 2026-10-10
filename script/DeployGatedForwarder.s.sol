// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, VmSafe} from "forge-std/Script.sol";
import {GatedForwarder} from "../src/GatedForwarder.sol";

/// @notice Deploy GatedForwarder untuk CRE_MODE=mock (SOT D24, docs/CONTRACTS.md bagian 10).
/// Env:
///   OPERATOR_ADDRESS  wajib. Wallet resolver (RESOLVER_PRIVATE_KEY resolver service), satu-satunya pemanggil report().
/// Kunci deployer dari CLI (--account <keystore> atau --private-key), tidak pernah dari file ini.
///   forge script script/DeployGatedForwarder.s.sol --rpc-url $MONAD_TESTNET_RPC --account <nama> --broadcast
/// deployments/gated-forwarder.monad-testnet.json hanya ditulis saat --broadcast di chain 10143.
/// LiveMarket tidak disentuh: setForwarder dikirim owner terpisah (DEPLOY.md bagian i).
contract DeployGatedForwarder is Script {
    uint256 constant ANVIL = 31337;
    string constant SOT_CONSTANTS = "../source/sot/constants.json";
    string constant OUT = "deployments/gated-forwarder.monad-testnet.json";

    function run() external returns (GatedForwarder gf) {
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        gf = deploy(operator);

        if (block.chainid == sotChainId() && vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            vm.createDir("deployments", true);
            string memory o = "gated";
            vm.serializeUint(o, "chainId", block.chainid);
            vm.serializeAddress(o, "gatedForwarder", address(gf));
            vm.writeJson(vm.serializeAddress(o, "operator", operator), OUT);
        }
    }

    function sotChainId() public view returns (uint256) {
        return vm.parseJsonUint(vm.readFile(SOT_CONSTANTS), ".network.chainId");
    }

    function deploy(address operator) public returns (GatedForwarder gf) {
        require(
            block.chainid == sotChainId() || block.chainid == ANVIL,
            "DeployGatedForwarder: hanya Monad Testnet (10143) atau anvil (31337)"
        );
        vm.startBroadcast();
        gf = new GatedForwarder(operator);
        vm.stopBroadcast();
    }
}
