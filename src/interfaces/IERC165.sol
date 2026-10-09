// SPDX-License-Identifier: MIT
// Disalin dari OpenZeppelin (utils/introspection/IERC165.sol), sesuai tautan di halaman
// "Building Consumer Contracts" dokumentasi CRE. Jangan diubah.
pragma solidity ^0.8.0;

interface IERC165 {
  function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
