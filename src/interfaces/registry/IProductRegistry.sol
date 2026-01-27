// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IProductRegistry {
    enum Status {
        NONE,
        ACTIVE,
        INACTIVE,
        DEPRECATED
    }

    enum FundType {
        HOUSE,
        MANAGED
    }

    struct ProductInfo {
        Status status;
        FundType fundType;
        address manager;
        address asset;
        address productOwner;
        string metadataURI;
        uint64 createdAt;
    }

    //events
    event ProductRegistered(
        address indexed fund,
        address indexed manager,
        address indexed asset,
        address productOwner,
        FundType fundType,
        string metadataURI
    );
    event ProductStatusSet(address indexed fund, Status oldStatus, Status newStatus);
    event ProductMetadataURISet(address indexed fund, string newURI);
    event OwnerURISet(address indexed productOwner, string newURI);
    event FactoryAllowedSet(address indexed factory, bool allowed);

    //view
    function getProductInfo(address fund) external view returns (ProductInfo memory);
    function isProduct(address fund) external view returns (bool);
    function isActive(address fund) external view returns (bool);
    function status(address fund) external view returns (Status);
    function fundType(address fund) external view returns (FundType);
    function managerOf(address fund) external view returns (address);
    function assetOf(address fund) external view returns (address);
    function ownerOf(address fund) external view returns (address);
    function metadataURI(address fund) external view returns (string memory);
    function createdAt(address fund) external view returns (uint64);
    function fundByManager(address manager) external view returns (address fund);
    function fundCountByOwner(address productOwner) external view returns (uint256);
    function fundByOwnerAt(address productOwner, uint256 index) external view returns (address fund);
    function fundsByOwner( address productOwner, uint256 start, uint256 limit) external view returns (address[] memory funds);
    function ownerURI(address productOwner) external view returns (string memory);
    function isFactoryAllowed(address factory) external view returns (bool);

    //write
    function registerProduct(
        address fund,
        FundType fundType_,
        address manager,
        address asset,
        address productOwner,
        string calldata metadataURI_
    ) external;

    //governance
    function setStatus(address fund, Status newStatus) external;
    function setMetadataURI(address fund, string calldata newURI) external;
    function setFactoryAllowed(address factory, bool allowed) external;
    function setOwnerURI(address productOwner, string calldata newURI) external;
    function transferGovernance(address newGov) external;
}
