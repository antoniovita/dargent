// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRiskEngine {
    //events
    event GovernanceUpdated(address indexed oldGovernance, address indexed newGovernance);
    event StrategyRegistryUpdated(address indexed oldReg, address indexed newReg);
    event TierThresholdsUpdated(uint32[] newThresholds);
    event MetadataURISet(string newURI);


    //view
    function computeRisk(address manager) external view returns (uint8 riskTier, uint32 riskScore);
}
