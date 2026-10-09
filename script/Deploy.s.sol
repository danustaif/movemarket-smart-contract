// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, VmSafe} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiveMarket} from "../src/LiveMarket.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/// @notice Deploy MockUSDC + LiveMarket ke Monad Testnet (docs/CONTRACTS.md bagian 9 langkah 1-4).
/// Env:
///   RESOLVER_ADDRESS   wajib. Wallet resolver: role resolver LiveMarket dan minter tUSDC.
///   FORWARDER_ADDRESS  opsional. Default addresses.creMockKeystoneForwarder di source/sot/constants.json.
/// Kunci deployer dari CLI (--account <keystore> atau --private-key), tidak pernah dari file ini.
///   forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC --account <nama> --broadcast
/// deployments/monad-testnet.json hanya ditulis saat --broadcast di chain 10143.
contract Deploy is Script {
    uint256 constant ANVIL = 31337;
    string constant SOT_CONSTANTS = "../source/sot/constants.json";
    string constant OUT = "deployments/monad-testnet.json";

    function run() external returns (LiveMarket market, MockUSDC usdc) {
        address resolver = vm.envAddress("RESOLVER_ADDRESS");
        address forwarder = vm.envOr("FORWARDER_ADDRESS", sotForwarder());
        uint256 deployBlock = block.number;
        (market, usdc) = deploy(forwarder, resolver);

        if (block.chainid == sotChainId() && vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            vm.createDir("deployments", true);
            string memory o = "deployment";
            vm.serializeUint(o, "chainId", block.chainid);
            vm.serializeAddress(o, "liveMarket", address(market));
            vm.serializeAddress(o, "mockUsdc", address(usdc));
            vm.serializeAddress(o, "forwarder", forwarder);
            vm.serializeAddress(o, "owner", market.owner());
            // block.number saat simulasi: batas bawah blok deploy, aman sebagai start block indexer
            vm.serializeUint(o, "deployBlock", deployBlock);
            vm.writeJson(vm.serializeAddress(o, "resolver", resolver), OUT);
        }
    }

    function sotForwarder() public view returns (address) {
        return vm.parseJsonAddress(vm.readFile(SOT_CONSTANTS), ".addresses.creMockKeystoneForwarder");
    }

    function sotChainId() public view returns (uint256) {
        return vm.parseJsonUint(vm.readFile(SOT_CONSTANTS), ".network.chainId");
    }

    function deploy(address forwarder, address resolver) public returns (LiveMarket market, MockUSDC usdc) {
        require(
            block.chainid == sotChainId() || block.chainid == ANVIL,
            "Deploy: hanya Monad Testnet (10143) atau anvil (31337)"
        );
        vm.startBroadcast();
        usdc = new MockUSDC();
        market = new LiveMarket(IERC20(address(usdc)), forwarder, resolver);
        usdc.setMinter(resolver, true);
        vm.stopBroadcast();
    }
}
