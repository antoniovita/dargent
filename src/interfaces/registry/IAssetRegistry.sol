// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAssetRegistry {
    enum Status {
        NONE,
        ACTIVE,
        INACTIVE,
        DEPRECATED
    }

    struct AssetInfo {
        Status status;
        uint8 decimals;
        string metadataURI;
        uint64 approvedAt;
    }

    //event
    event AssetApproved(
        address indexed asset,
        uint8 decimals,
        uint64 approvedAt
    );
    event AssetStatusSet(
        address indexed asset,
        Status oldStatus,
        Status newStatus
    );
    event AssetMetadataURISet(
        address indexed asset,
        string newURI
    );
    event AssetDecimalsSet(
        address indexed asset,
        uint8 oldDecimals,
        uint8 newDecimals
    );

    //view
    function getAssetInfo(address asset) external view returns (AssetInfo memory);
    function status(address asset) external view returns (Status);
    function decimals(address asset) external view returns (uint8);
    function metadataURI(address asset) external view returns (string memory);
    function approvedAt(address asset) external view returns (uint64);
    function isApproved(address asset) external view returns (bool);

    //governance
    function approveAsset(address asset, AssetInfo calldata info) external;
    function setStatus(address asset, Status newStatus) external;
    function setMetadataURI(address asset, string calldata newURI) external;
    function setDecimals(address asset, uint8 newDecimals) external;
}
