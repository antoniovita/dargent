// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManager {

    //events
    event StrategyAdded(address indexed implementation, address indexed strategyInstance, uint16 weightBps);
    event StrategyRemovingStarted(address indexed strategyInstance, uint16 removedWeightBps);
    event StrategyRemoved(address indexed strategyInstance, address indexed implementation);
    event WeightsUpdated(address[] strategyInstances, uint16[] weightsBps);
    event WeightsChangeAnnounced(uint256 indexed epoch, uint256 eta, uint256 expiresAt);
    event WeightsChangeExecuted(uint256 indexed epoch);
    event StrategyAddAnnounced(address indexed implementation, uint16 weightBps, uint256 eta, uint256 expiresAt);
    event StrategyAddExecuted(address indexed implementation, address indexed instance, uint16 weightBps);

    //view
    function fund() external view returns (address);
    function asset() external view returns (address);
    function owner() external view returns (address);
    function strategyRegistry() external view returns (address);
    function riskEngine() external view returns (address);
    function totalAssets() external view returns (uint256);
    function strategyCount() external view returns (uint256);
    function strategyAt(uint256 index) external view returns (address);
    function strategyWeight(address strategyInstance) external view returns (uint16);
    function getAllocation() external view returns (address[] memory strategyInstances, uint16[] memory weightsBps);
    function strategyImplementationOf(address instance) external view returns (address);
    function minWeightBps() external view returns (uint16);
    function changeDelay() external view returns (uint48);
    function epochLength() external view returns (uint48);
    function maxDeltaBpsPerEpoch() external view returns (uint16);

    function pendingWeights()
        external
        view
        returns (bool exists, uint256 eta, uint256 expiresAt, address[] memory strategies, uint16[] memory weights);

    function pendingAddStrategy()
        external
        view
        returns (bool exists, uint256 eta, uint256 expiresAt, address implementation, uint16 weightBps);

    //write fund-only
    function allocate(uint256 assets) external;
    function deallocate(uint256 assets) external returns (uint256 freed);
    function drainRemoving() external;
    function setRiskEngine(address newRiskEngine) external;


    //owner-governance-only
    function addStrategyViaImplementations(address[] calldata implementations, uint16[] calldata weightsBps)
        external
        returns (address[] memory newStrategyInstances);

    function removeStrategyInstance(address strategyInstance) external returns (uint256 freedAssets);

    function announceStrategyWeights(address[] calldata strategyInstances, uint16[] calldata weightsBps) external;
    function executeStrategyWeights() external;

    function announceAddStrategyViaImplementation(address strategyImplementation, uint16 weightBps) external;
    function executeAddStrategyViaImplementation() external returns (address newStrategyInstance);

    function cancelPendingWeights() external;
    function cancelPendingAddStrategy() external;
}
