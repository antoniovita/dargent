// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManager {
    event ManagerOwnerTransferStarted(address indexed oldOwner, address indexed newOwner);
    event ManagerOwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event TiltUpdated(address indexed manager, int16[] newTiltBps, uint64 effectiveAt, bytes32 rationaleHash);
    event TiltParamsSet(uint16 maxTiltBps, uint16 maxStepBps, uint64 tiltCooldown);
    event RebalanceExecuted(address indexed caller, uint256 assetsMoved, uint8 legsExecuted);
    event RebalanceBandUpdated(uint16 oldBandBps, uint16 newBandBps);
    event StrategyAdded(address indexed implementation, address indexed strategyInstance, uint16 weightBps);
    event EmergencyStopped();

    function initialized() external view returns (bool);
    function emergencyStopped() external view returns (bool);

    function fund() external view returns (address);
    function asset() external view returns (address);
    function managerOwner() external view returns (address);
    function pendingManagerOwner() external view returns (address);
    function strategyRegistry() external view returns (address);
    function riskEngine() external view returns (address);
    function rebalanceBandBps() external view returns (uint16);
    function minRebalanceBandBps() external view returns (uint16);
    function maxRebalanceBandBps() external view returns (uint16);
    function bandUpdateCooldown() external view returns (uint64);
    function lastBandUpdateAt() external view returns (uint64);

    function getEffectiveWeights() external view returns (uint16[] memory);
    function getCoreWeights() external view returns (uint16[] memory);
    function getTiltBps() external view returns (int16[] memory);
    function previewAllocationWeights() external view returns (uint16[] memory);
    function previewDriftBps() external view returns (int32[] memory driftBps);

    function setTilt(int16[] calldata newTiltBps, bytes32 rationaleHash) external;
    function setRebalanceBandBps(uint16 newBandBps) external;
    function transferManagerOwner(address newOwner) external;
    function acceptManagerOwner() external;

    function totalAssets() external view returns (uint256);
    function strategyCount() external view returns (uint256);
    function strategyAt(uint256 index) external view returns (address);
    function strategyWeight(address strategyInstance) external view returns (uint16);
    function getAllocation() external view returns (address[] memory strategyInstances, uint16[] memory weightsBps);
    function strategyImplementationOf(address instance) external view returns (address);
    function minWeightBps() external view returns (uint16);

    function allocate(uint256 assets) external;
    function deallocate(uint256 assets) external returns (uint256 freed);
    function rebalance(uint256 maxAssetsToMove, uint8 maxLegs) external returns (uint256 assetsMoved);
    function emergencyStop() external;
}
