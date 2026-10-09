// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMockUSDC} from "./interfaces/IMockUSDC.sol";

/// @title MockUSDC
/// @notice tUSDC untuk Monad Testnet, 6 desimal. Wallet resolver adalah minter untuk faucet.
contract MockUSDC is ERC20, Ownable, IMockUSDC {
    mapping(address => bool) public minters;

    error NotMinter();

    constructor() ERC20("Test USDC", "tUSDC") Ownable(msg.sender) {}

    function decimals() public pure override(ERC20, IMockUSDC) returns (uint8) {
        return 6;
    }

    function setMinter(address minter, bool ok) external onlyOwner {
        minters[minter] = ok;
    }

    function mint(address to, uint256 amount) external {
        if (!minters[msg.sender]) revert NotMinter();
        _mint(to, amount);
    }
}
