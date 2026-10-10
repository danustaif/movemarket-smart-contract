// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReceiver} from "./interfaces/IReceiver.sol";

/// @title GatedForwarder
/// @notice Forwarder untuk CRE_MODE=mock (SOT D24, docs/CONTRACTS.md bagian 10). Sama dengan MockKeystoneForwarder
///         Chainlink (chainlink-evm contracts/cre/src/dev/MockKeystoneForwarder.sol) untuk bagian yang dipakai runner
///         mock, tetapi hanya `operator` (wallet resolver) yang boleh memanggil report().
contract GatedForwarder {
    /// @dev Sama dengan mock: metadata 109 byte, 45 byte pertama (versi, execution id, timestamp, DON id, versi
    ///      config DON) tidak diteruskan ke receiver.
    uint256 internal constant METADATA_LENGTH = 109;
    uint256 internal constant FORWARDER_METADATA_LENGTH = 45;

    address public immutable operator;

    event ReportProcessed(
        address indexed receiver, bytes32 indexed workflowExecutionId, bytes2 indexed reportId, bool result
    );

    error NotOperator(address caller);
    /// @dev rawReport lebih pendek dari METADATA_LENGTH (selector 0xb55ac754, sama dengan mock).
    error InvalidReport();

    constructor(address operator_) {
        operator = operator_;
    }

    /// @notice Teruskan onReport(rawReport[45:109], rawReport[109:]) ke receiver. reportContext dan signatures
    ///         diabaikan. Revert di onReport (atau receiver tanpa kode) tidak me-revert: ReportProcessed.result = false.
    function report(address receiver, bytes calldata rawReport, bytes calldata, bytes[] calldata) external {
        if (msg.sender != operator) revert NotOperator(msg.sender);
        if (rawReport.length < METADATA_LENGTH) revert InvalidReport();

        (bool ok,) = receiver.call(
            abi.encodeCall(
                IReceiver.onReport, (rawReport[FORWARDER_METADATA_LENGTH:METADATA_LENGTH], rawReport[METADATA_LENGTH:])
            )
        );
        // execution id = byte 1..33, report id = byte 107..109
        emit ReportProcessed(
            receiver, bytes32(rawReport[1:33]), bytes2(rawReport[107:109]), ok && receiver.code.length > 0
        );
    }
}
