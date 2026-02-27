// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFundInit {

    struct FeeConfig {
        uint16 mgmtFeeBps;
        uint16 perfFeeBps;
        address managerFeeRecipient;
    }

    function initialize(
        address asset_,
        address manager_,
        uint16 bufferBps_,
        FeeConfig calldata feeConfig_,
        address feeCollector_,
        address withdrawalQueue_
    ) external;
}
