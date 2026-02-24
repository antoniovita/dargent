// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManager {
    event StrategyAdded(address indexed implementation, address indexed strategyInstance, uint16 weightBps);
    event EmergencyStopped();

    function initialized() external view returns (bool);
    function emergencyStopped() external view returns (bool);

    function fund() external view returns (address);
    function asset() external view returns (address);
    function strategyRegistry() external view returns (address);
    function riskEngine() external view returns (address);

    function totalAssets() external view returns (uint256);
    function strategyCount() external view returns (uint256);
    function strategyAt(uint256 index) external view returns (address);
    function strategyWeight(address strategyInstance) external view returns (uint16);
    function getAllocation() external view returns (address[] memory strategyInstances, uint16[] memory weightsBps);
    function strategyImplementationOf(address instance) external view returns (address);
    function minWeightBps() external view returns (uint16);

    function allocate(uint256 assets) external;
    function deallocate(uint256 assets) external returns (uint256 freed);
    function emergencyStop() external;
}
