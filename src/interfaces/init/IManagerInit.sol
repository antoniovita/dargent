// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManagerInit {
    function initialize(
        address fund_,
        address riskEngine_,
        address asset_,
        address strategyRegistry_,
        address[] calldata implementations,
        uint16[] calldata weightsBps
    ) external;
}
