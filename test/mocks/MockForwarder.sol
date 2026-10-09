// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReceiver} from "../../src/interfaces/IReceiver.sol";

/// @notice Pengganti KeystoneForwarder untuk test lokal: meneruskan report apa adanya.
contract MockForwarder {
    function forward(address receiver, bytes calldata metadata, bytes calldata report) external {
        IReceiver(receiver).onReport(metadata, report);
    }
}
