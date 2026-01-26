// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRiskEngine {
    //view
    function computeRisk(address manager) external view returns (uint8 riskTier, uint32 riskScore);
}
