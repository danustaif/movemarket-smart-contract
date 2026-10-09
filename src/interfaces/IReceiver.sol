// SPDX-License-Identifier: MIT
// Disalin dari dokumentasi CRE, "Building Consumer Contracts" bagian 2.1 (dicek 9 Oktober 2026).
// Jangan diubah. MoveMarket tidak memakai ReceiverTemplate (docs/CONTRACTS.md 3.3).
pragma solidity ^0.8.0;

import {IERC165} from "./IERC165.sol";

/// @title IReceiver - receives keystone reports
/// @notice Implementations must support the IReceiver interface through ERC165.
interface IReceiver is IERC165 {
  /// @notice Handles incoming keystone reports.
  /// @dev If this function call reverts, it can be retried with a higher gas
  /// limit. The receiver is responsible for discarding stale reports.
  /// @param metadata Report's metadata.
  /// @param report Workflow report.
  function onReport(
    bytes calldata metadata,
    bytes calldata report
  ) external;
}
