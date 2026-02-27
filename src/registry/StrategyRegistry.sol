// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStrategyRegistry} from "../interfaces/registry/IStrategyRegistry.sol";

//errors
error NotGovernance();
error ZeroAddress();
error StrategyAlreadyApproved(address implementation);
error StrategyNotApproved(address implementation);
error InvalidStatus();

contract StrategyRegistry is IStrategyRegistry {
    address public governance;

    mapping(address => StrategyInfo) internal _strategies;
    mapping(address => mapping(address => bool)) internal _supportsAsset;

    //modifiers
    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier nonZero(address a) {
        if (a == address(0)) revert ZeroAddress();
        _;
    }

    constructor(address governance_) {
        if (governance_ == address(0)) revert ZeroAddress();
        governance = governance_;
    }

    //view
    function getStrategyInfo(address implementation) external view override returns (StrategyInfo memory) {
        return _strategies[implementation];
    }

    function status(address implementation) external view override returns (Status) {
        return _strategies[implementation].status;
    }


    function riskScore(address implementation) external view override returns (uint32) {
        return _strategies[implementation].riskScore;
    }

    function isLiquid(address implementation) external view override returns (bool) {
        return _strategies[implementation].isLiquid;
    }

    function metadataURI(address implementation) external view override returns (string memory) {
        return _strategies[implementation].metadataURI;
    }

    function approvedAt(address implementation) external view override returns (uint64) {
        return _strategies[implementation].approvedAt;
    }

    function isActive(address implementation) external view override returns (bool) {
        return _strategies[implementation].status == Status.ACTIVE;
    }

    function supportsAsset(address implementation, address asset) external view override returns (bool) {
        return _supportsAsset[implementation][asset];
    }

    function isApproved(address implementation) public view override returns (bool) {
        Status s = _strategies[implementation].status;
        return (s == Status.ACTIVE || s == Status.INACTIVE || s == Status.DEPRECATED);
    }

    //governance
    function approveStrategy(address implementation, StrategyInfo calldata info)
        external
        override
        onlyGovernance
        nonZero(implementation)
    {
        if (isApproved(implementation)) revert StrategyAlreadyApproved(implementation);

        if (info.status != Status.ACTIVE && info.status != Status.INACTIVE && info.status != Status.DEPRECATED) {
            revert InvalidStatus();
        }
        _strategies[implementation] = StrategyInfo({
            status: info.status,
            riskScore: info.riskScore,
            isLiquid: info.isLiquid,
            metadataURI: info.metadataURI,
            approvedAt: info.approvedAt
        });

        emit StrategyApproved(implementation, info.approvedAt);
        emit StrategyStatusSet(implementation, Status.NONE, info.status);
        emit StrategyRiskSet(implementation, info.riskScore, info.isLiquid);
        if (bytes(info.metadataURI).length != 0) emit StrategyMetadataURISet(implementation, info.metadataURI);
    }

    function setStatus(address implementation, Status newStatus)
        external
        override
        onlyGovernance
        nonZero(implementation)
    {
        if (!isApproved(implementation)) revert StrategyNotApproved(implementation);

        if (newStatus != Status.ACTIVE && newStatus != Status.INACTIVE && newStatus != Status.DEPRECATED) {
            revert InvalidStatus();
        }

        Status old = _strategies[implementation].status;
        _strategies[implementation].status = newStatus;

        emit StrategyStatusSet(implementation, old, newStatus);
    }

    function setRisk(address implementation, uint32 newRiskScore, bool newIsLiquid)
        external
        override
        onlyGovernance
        nonZero(implementation)
    {
        if (!isApproved(implementation)) revert StrategyNotApproved(implementation);

        _strategies[implementation].riskScore = newRiskScore;
        _strategies[implementation].isLiquid = newIsLiquid;

        emit StrategyRiskSet(implementation, newRiskScore, newIsLiquid);
    }

    function setMetadataURI(address implementation, string calldata newURI)
        external
        override
        onlyGovernance
        nonZero(implementation)
    {
        if (!isApproved(implementation)) revert StrategyNotApproved(implementation);

        _strategies[implementation].metadataURI = newURI;
        emit StrategyMetadataURISet(implementation, newURI);
    }

    function setAssetSupport(address implementation, address asset, bool supported)
        external
        override
        onlyGovernance
        nonZero(implementation)
        nonZero(asset)
    {
        if (!isApproved(implementation)) revert StrategyNotApproved(implementation);

        _supportsAsset[implementation][asset] = supported;
        emit StrategyAssetSupportSet(implementation, asset, supported);
    }

    function transferGovernance(address newGov) external onlyGovernance nonZero(newGov) {
        governance = newGov;
    }
}
