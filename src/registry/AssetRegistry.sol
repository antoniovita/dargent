// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAssetRegistry} from "../interfaces/registry/IAssetRegistry.sol";

//errors
error NotGovernance();
error ZeroAddress();
error AssetAlreadyApproved();
error AssetNotApproved();
error InvalidStatus();
error InvalidDecimals();

contract AssetRegistry is IAssetRegistry {
    address public governance;
    mapping(address => AssetInfo) internal _info;

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
    function getAssetInfo(address asset) external view override returns (AssetInfo memory) {
        return _info[asset];
    }

    function status(address asset) external view override returns (Status) {
        return _info[asset].status;
    }

    function decimals(address asset) external view override returns (uint8) {
        return _info[asset].decimals;
    }

    function metadataURI(address asset) external view override returns (string memory) {
        return _info[asset].metadataURI;
    }

    function approvedAt(address asset) external view override returns (uint64) {
        return _info[asset].approvedAt;
    }

    function isApproved(address asset) public view override returns (bool) {
        Status s = _info[asset].status;
        return (s == Status.ACTIVE || s == Status.INACTIVE || s == Status.DEPRECATED);
    }

    //governance
    function approveAsset(address asset, AssetInfo calldata info)
        external
        override
        onlyGovernance
        nonZero(asset)
    {
        AssetInfo storage cur = _info[asset];
        if (isApproved(asset)) revert AssetAlreadyApproved();

        if (info.status != Status.ACTIVE && info.status != Status.INACTIVE && info.status != Status.DEPRECATED) {
            revert InvalidStatus();
        }

        if (info.decimals > 77) revert InvalidDecimals();
        if (info.approvedAt == 0) revert InvalidStatus();

        cur.status = info.status;
        cur.decimals = info.decimals;
        cur.metadataURI = info.metadataURI;
        cur.approvedAt = info.approvedAt;

        emit AssetApproved(asset, info.decimals, info.approvedAt);
        emit AssetStatusSet(asset, Status.NONE, info.status);
        if (bytes(info.metadataURI).length != 0) emit AssetMetadataURISet(asset, info.metadataURI);
    }

    function setStatus(address asset, Status newStatus)
        external
        override
        onlyGovernance
        nonZero(asset)
    {
        if (!isApproved(asset)) revert AssetNotApproved();

        if (newStatus != Status.ACTIVE && newStatus != Status.INACTIVE && newStatus != Status.DEPRECATED) {
            revert InvalidStatus();
        }

        Status old = _info[asset].status;
        _info[asset].status = newStatus;

        emit AssetStatusSet(asset, old, newStatus);
    }

    function setMetadataURI(address asset, string calldata newURI)
        external
        override
        onlyGovernance
        nonZero(asset)
    {
        if (!isApproved(asset)) revert AssetNotApproved();

        _info[asset].metadataURI = newURI;
        emit AssetMetadataURISet(asset, newURI);
    }

    function setDecimals(address asset, uint8 newDecimals)
        external
        override
        onlyGovernance
        nonZero(asset)
    {
        if (!isApproved(asset)) revert AssetNotApproved();
        if (newDecimals > 77) revert InvalidDecimals();

        uint8 old = _info[asset].decimals;
        _info[asset].decimals = newDecimals;

        emit AssetDecimalsSet(asset, old, newDecimals);
    }

    function transferGovernance(address newGov) external onlyGovernance nonZero(newGov) {
        governance = newGov;
    }
}
