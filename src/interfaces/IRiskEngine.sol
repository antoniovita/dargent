// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRiskEngine {
    function compute(address[] calldata strategies, uint16[] calldata weightsBps) external view returns (uint32 score, uint8 tier);
}