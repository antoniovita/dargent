// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManagerInit {
    function initialize(
        address fund_,
        address riskEngine_,
        address asset_,
        address owner_,
        address strategyRegistry_,
        address factory_
    ) external;
}
