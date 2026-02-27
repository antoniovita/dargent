// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRiskEngine {
    //events
    event GovernanceUpdated(address indexed oldGovernance, address indexed newGovernance);
    event StrategyRegistryUpdated(address indexed oldReg, address indexed newReg);
    event RiskParamsUpdated(uint32 maxScoreDelta, uint64 minUpdateDelay, uint64 thresholdsTimelock);
    event ThresholdsUpdateQueued(bytes32 indexed id, uint64 eta);
    event ThresholdsUpdateExecuted(bytes32 indexed id);
    event TierThresholdsUpdated(uint32[] newThresholds);
    event RiskPublished(address indexed manager, uint32 rawScore, uint32 boundedScore, uint8 tier);
    event MetadataURISet(string newURI);

    //view
    function computeRiskRaw(address manager) external view returns (uint8 riskTier, uint32 riskScore);
    function refreshRisk(address manager) external returns (uint8 riskTier, uint32 riskScore);
    function lastPublishedRisk(address manager) external view returns (uint8 riskTier, uint32 riskScore, uint64 updatedAt);
    function tierThresholds() external view returns (uint32[] memory);

    //governance
    function queueTierThresholds(uint32[] calldata newThresholds) external;
    function executeTierThresholds(uint32[] calldata newThresholds) external;
    function setRiskParams(uint32 maxScoreDelta_, uint64 minUpdateDelay_, uint64 thresholdsTimelock_) external;
}
