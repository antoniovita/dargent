// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFeeCollector {
    struct ProtocolFeeConfig {
        address protocolFeeRecipient;
        uint16 protocolMgmtTakeBps;
        uint16 protocolPerfTakeBps;
    }

    struct FundFeeState {
        uint64 lastAccrual;
        uint192 highWaterMark;
    }

    //view
    function protocolFeeConfig() external view returns (ProtocolFeeConfig memory);
    function fundFeeState(address fund) external view returns (FundFeeState memory);
    function previewAccrue(address fund) external view returns (uint256 totalFeeShares, uint256 protocolFeeShares, uint256 managerFeeShares);

    //write
    function accrue(address fund) external returns (uint256 totalFeeShares,uint256 protocolFeeShares,uint256 managerFeeShares);

    //governance
    function setProtocolFeeRecipient(address newRecipient) external;
    function setProtocolTakes(uint16 newMgmtTakeBps, uint16 newPerfTakeBps) external;
    function setHighWaterMark(address fund, uint192 newHighWaterMark) external;
}
