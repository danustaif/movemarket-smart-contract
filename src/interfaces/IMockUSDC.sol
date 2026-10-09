// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMockUSDC
/// @notice Token testnet tUSDC (6 desimal). Implementasi: ERC20 + Ownable OpenZeppelin.
/// @dev Fungsi di bawah adalah tambahan di atas ERC20 standar (sot/abi.json bagian mockUsdc).
///      Wallet resolver adalah minter untuk faucet.
interface IMockUSDC {
    /// @dev onlyOwner.
    function setMinter(address minter, bool ok) external;
    /// @dev Hanya minter.
    function mint(address to, uint256 amount) external;
    function minters(address) external view returns (bool);
    function decimals() external pure returns (uint8);
}
