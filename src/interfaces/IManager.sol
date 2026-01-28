// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManager {

    //events
    event StrategyAdded(address indexed implementation, address indexed strategyInstance, uint16 weightBps);
    event StrategyRemovingStarted(address indexed strategyInstance, uint16 removedWeightBps);
    event StrategyRemoved(address indexed strategyInstance, address indexed implementation);
    event WeightsUpdated(address[] strategyInstances, uint16[] weightsBps);
    event StrategyReplaced(address indexed oldStrategyInstance, address indexed oldImplementation, address indexed newStrategyInstance, address newImplementation, uint16 newWeightBps);
    event Rebalanced();

    //view
    function fund() external view returns (address);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function strategyCount() external view returns (uint256);
    function strategyAt(uint256 index) external view returns (address);
    function strategyWeight(address strategyInstance) external view returns (uint16);
    function getAllocation() external view returns (address[] memory strategyInstances, uint16[] memory weightsBps);
    function strategyRegistry() external view returns (address);
    function riskEngine() external view returns (address);
    function strategyImplementationOf(address instance) external view returns(address);

    //write
    function allocate(uint256 assets) external;
    function deallocate(uint256 assets) external returns (uint256 freed);

    //only fund
    function setRiskEngine(address newRiskEngine) external;

    //governance and manager owner only
    function addStrategyViaImplementation(address strategyImplementation, uint16 weightBps) external returns (address newStrategyInstance);
    function addStrategyViaImplementations(address[] calldata implementations, uint16[] calldata weightsBps) external returns (address[] memory newStrategyInstances);
    function removeStrategyInstance(address strategyInstance) external returns (uint256 freedAssets);
    function updateStrategyWeights(address[] calldata strategyInstances, uint16[] calldata weightsBps) external;

    //em breve fazer uma function para rebalance com threshold
}
