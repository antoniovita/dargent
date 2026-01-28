// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRiskEngine {
    // events
    event GovernanceUpdated(address indexed oldGov, address indexed newGov);
    event StrategyRegistryUpdated(address indexed oldReg, address indexed newReg);
    event TierThresholdsUpdated(uint32[] newThresholds);


    //view
    function computeRisk(address manager) external view returns (uint8 riskTier, uint32 riskScore);
}
