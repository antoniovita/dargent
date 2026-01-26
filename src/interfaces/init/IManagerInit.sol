// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManagerInit {
    function initialize(
        address fund_,
        address asset_,
        address owner_,
        address strategyRegistry_
    ) external;
}
