// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IProductRegistry} from "../interfaces/registry/IProductRegistry.sol";
import {IFund} from "../interfaces/IFund.sol";

//errors
error NotGovernance();
error InvalidLimit();
error ZeroAddress();
error ProductAlreadyRegistered(address fund);
error ProductNotRegistered(address fund);
error InvalidStatus();
error InvalidFundType();
error ManagerAlreadyMapped(address manager);
error FactoryNotAllowed(address factory);

contract ProductRegistry is IProductRegistry {
    address public governance;
    mapping(address => ProductInfo) internal _products;
    mapping(address => address) internal _fundByManager;
    mapping(address => address[]) internal _fundsByOwner;
    mapping(address => mapping(address => uint256)) internal _ownerFundIndexPlus1;
    mapping(address => string) internal _ownerURI;
    mapping(address => bool) internal _factoryAllowed;

    //modifiers
    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier nonZero(address a) {
        if (a == address(0)) revert ZeroAddress();
        _;
    }

    modifier onlyAllowedFactory() {
        if (!_factoryAllowed[msg.sender]) revert FactoryNotAllowed(msg.sender);
        _;
    }

    constructor(address governance_) {
        if (governance_ == address(0)) revert ZeroAddress();
        governance = governance_;
    }

    function getProductInfo(address fund) external view override returns (ProductInfo memory) {
        if (!isProduct(fund)) revert ProductNotRegistered(fund);
        return _products[fund];
    }

    function isProduct(address fund) public view override returns (bool) {
        return _products[fund].status != Status.NONE;
    }

    function isActive(address fund) external view override returns (bool) {
        return _products[fund].status == Status.ACTIVE;
    }

    function status(address fund) external view override returns (Status) {
        return _products[fund].status;
    }

    function fundType(address fund) external view override returns (FundType) {
        return _products[fund].fundType;
    }

    function managerOf(address fund) external view override returns (address) {
        return _products[fund].manager;
    }

    function assetOf(address fund) external view override returns (address) {
        return _products[fund].asset;
    }

    function ownerOf(address fund) external view override returns (address) {
        return _products[fund].productOwner;
    }

    function metadataURI(address fund) external view override returns (string memory) {
        return _products[fund].metadataURI;
    }

    function createdAt(address fund) external view override returns (uint64) {
        return _products[fund].createdAt;
    }

    function fundByManager(address manager) external view override returns (address fund) {
        return _fundByManager[manager];
    }

    function fundCountByOwner(address productOwner) external view override returns (uint256) {
        return _fundsByOwner[productOwner].length;
    }

    function fundByOwnerAt(address productOwner, uint256 index) external view override returns (address fund) {
        return _fundsByOwner[productOwner][index];
    }

    function fundsByOwner(address productOwner, uint256 start, uint256 limit)
        external
        view
        override
        returns (address[] memory funds)
    {
        address[] storage arr = _fundsByOwner[productOwner];
        uint256 len = arr.length;

        if (start >= len || limit == 0) revert InvalidLimit();

        uint256 end = start + limit;
        if (end > len) end = len;

        uint256 outLen = end - start;
        funds = new address[](outLen);

        for (uint256 i = 0; i < outLen; i++) {
            funds[i] = arr[start + i];
        }
    }

    function ownerURI(address productOwner) external view override returns (string memory) {
        return _ownerURI[productOwner];
    }

    function isFactoryAllowed(address factory) external view override returns (bool) {
        return _factoryAllowed[factory];
    }

    //write
    function registerProduct(
        address fund,
        FundType fundType_,
        address manager,
        address asset,
        address productOwner,
        string calldata metadataURI_
    )
        external
        override
        onlyAllowedFactory
        nonZero(fund)
        nonZero(manager)
        nonZero(asset)
        nonZero(productOwner)
    {
        if (isProduct(fund)) revert ProductAlreadyRegistered(fund);

        if (fundType_ != FundType.HOUSE && fundType_ != FundType.MANAGED) revert InvalidFundType();

        if (_fundByManager[manager] != address(0)) revert ManagerAlreadyMapped(manager);

        uint256 sharePrice_ = IFund(fund).convertToAssets(1e18);
        uint8 riskTier_ = IFund(fund).riskTier();
        uint32 riskScore_ = IFund(fund).riskScore();

        _products[fund] = ProductInfo({
            status: Status.ACTIVE,
            fundType: fundType_,
            manager: manager,
            asset: asset,
            productOwner: productOwner,
            metadataURI: metadataURI_,
            createdAt: uint64(block.timestamp)
        });

        _fundByManager[manager] = fund;

        _fundsByOwner[productOwner].push(fund);
        _ownerFundIndexPlus1[productOwner][fund] = _fundsByOwner[productOwner].length;

        emit ProductRegistered(
            fund,
            manager,
            asset,
            productOwner,
            fundType_,
            metadataURI_,
            sharePrice_,
            riskTier_,
            riskScore_
        );
    }

    //governance
    function setStatus(address fund, Status newStatus)
        external
        override
        onlyGovernance
        nonZero(fund)
    {
        if (!isProduct(fund)) revert ProductNotRegistered(fund);

        if (newStatus != Status.ACTIVE && newStatus != Status.INACTIVE && newStatus != Status.DEPRECATED) {
            revert InvalidStatus();
        }

        Status old = _products[fund].status;
        _products[fund].status = newStatus;

        emit ProductStatusSet(fund, old, newStatus);
    }

    function setMetadataURI(address fund, string calldata newURI)
        external
        override
        onlyGovernance
        nonZero(fund)
    {
        if (!isProduct(fund)) revert ProductNotRegistered(fund);

        _products[fund].metadataURI = newURI;
        emit ProductMetadataURISet(fund, newURI);
    }

    function setFactoryAllowed(address factory, bool allowed)
        external
        override
        onlyGovernance
        nonZero(factory)
    {
        _factoryAllowed[factory] = allowed;
        emit FactoryAllowedSet(factory, allowed);
    }

    function setOwnerURI(address productOwner, string calldata newURI)
        external
        override
        onlyGovernance
        nonZero(productOwner)
    {
        _ownerURI[productOwner] = newURI;
        emit OwnerURISet(productOwner, newURI);
    }

    function transferGovernance(address newGov) external onlyGovernance nonZero(newGov) {
        governance = newGov;
    }
}
