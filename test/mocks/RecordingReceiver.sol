// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Receiver test GatedForwarder: mencatat argumen onReport terakhir, atau revert kalau diminta.
contract RecordingReceiver {
    bytes public metadata;
    bytes public report;
    address public caller;
    bool public fail;

    function setFail(bool f) external {
        fail = f;
    }

    function onReport(bytes calldata metadata_, bytes calldata report_) external {
        require(!fail, "RecordingReceiver: fail");
        (metadata, report, caller) = (metadata_, report_, msg.sender);
    }
}
