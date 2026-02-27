// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IManagerInit {
    function initialize(
        address fund_,
        address factory_,
        address managerOwner_,
        address riskEngine_,
        address asset_,
        address strategyRegistry_,
        uint16 maxTiltBps_,
        uint16 maxStepBps_,
        uint64 tiltCooldown_,
        uint16 defaultRebalanceBandBps_,
        uint16 minRebalanceBandBps_,
        uint16 maxRebalanceBandBps_,
        uint64 bandUpdateCooldown_,
        address[] calldata implementations,
        uint16[] calldata weightsBps
    ) external;
}
