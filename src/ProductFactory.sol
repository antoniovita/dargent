// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IProductFactory} from "./interfaces/IProductFactory.sol";
import {IFundInit} from "./interfaces/init/IFundInit.sol";
import {IManagerInit} from "./interfaces/init/IManagerInit.sol";
import {IManager} from "./interfaces/IManager.sol";

import {IProductRegistry} from "./interfaces/registry/IProductRegistry.sol";
import {IStrategyRegistry} from "./interfaces/registry/IStrategyRegistry.sol";
import {IAssetRegistry} from "./interfaces/registry/IAssetRegistry.sol";

// errors
error NotOwner();
error ZeroAddress();
error InvalidWeights();
error LengthMismatch();
error InvalidFundType();
error InvalidBps();
error AssetNotApproved(address asset);
error StrategyNotActive(address implementation);
error StrategyNotSupported(address implementation, address asset);
error ZeroWeight(uint256 index);

contract ProductFactory is IProductFactory {
    using Clones for address;

    address public owner;
    address public immutable fundImplementation;
    address public immutable managerImplementation;
    address public productRegistry;
    address public strategyRegistry;
    address public assetRegistry;
    address public feeCollector;
    address public withdrawalQueue;
    address public riskEngine;

    constructor(
        address fundImpl,
        address managerImpl,
        address productReg,
        address strategyReg,
        address assetReg,
        address feeCollector_,
        address withdrawalQueue_,
        address riskEngine_,
        address owner_
    ) {
        if (
            fundImpl == address(0) ||
            managerImpl == address(0) ||
            productReg == address(0) ||
            strategyReg == address(0) ||
            assetReg == address(0) ||
            feeCollector_ == address(0) ||
            withdrawalQueue_ == address(0) ||
            riskEngine_ == address(0) ||
            owner_ == address(0)
        ) revert ZeroAddress();

        fundImplementation = fundImpl;
        managerImplementation = managerImpl;
        productRegistry = productReg;
        strategyRegistry = strategyReg;
        assetRegistry = assetReg;
        feeCollector = feeCollector_;
        withdrawalQueue = withdrawalQueue_;
        riskEngine = riskEngine_;
        owner = owner_;
    }

    //modifiers
    modifier isOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier isValid(address a) {
        if (a == address(0)) revert ZeroAddress();
        _;
    }

    //create
    function createProduct(CreateParams calldata p)
        external
        returns (address fund, address manager, address[] memory strategyInstances)
    {
        if (p.asset == address(0)) revert ZeroAddress();
        if (p.managerFeeRecipient == address(0)) revert ZeroAddress();

        if (p.bufferBps > 10_000) revert InvalidBps();
        if (p.mgmtFeeBps > 10_000 || p.perfFeeBps > 10_000) revert InvalidBps();

        uint256 len = p.strategyImplementations.length;
        if (len != p.weightsBps.length) revert LengthMismatch();
        if (len == 0) revert InvalidWeights();

        if (p.fundType == FundType.HOUSE) {
            if (msg.sender != owner) revert NotOwner();
        } else if (p.fundType != FundType.MANAGED) {
            revert InvalidFundType();
        }

        uint256 sum;
        for (uint256 i = 0; i < len; i++) {
            uint256 w = p.weightsBps[i];
            if (w == 0) revert ZeroWeight(i);
            sum += w;
        }
        if (sum != 10_000) revert InvalidWeights();

        IAssetRegistry aReg = IAssetRegistry(assetRegistry);
        IStrategyRegistry sReg = IStrategyRegistry(strategyRegistry);

        if (!aReg.isApproved(p.asset)) revert AssetNotApproved(p.asset);

        for (uint256 i = 0; i < len; i++) {
            address impl = p.strategyImplementations[i];
            if (!sReg.isActive(impl)) revert StrategyNotActive(impl);
            if (!sReg.supportsAsset(impl, p.asset)) revert StrategyNotSupported(impl, p.asset);
        }

        manager = managerImplementation.clone();
        fund = fundImplementation.clone();

        address productOwner = (p.fundType == FundType.HOUSE) ? owner : msg.sender;

        IManagerInit(manager).initialize(
            fund,
            riskEngine,
            p.asset,
            productOwner,
            strategyRegistry
        );

        IFundInit(fund).initialize(
            p.asset,
            manager,
            IFundInit.FundType(uint8(p.fundType)),
            p.bufferBps,
            IFundInit.FeeConfig({
                mgmtFeeBps: p.mgmtFeeBps,
                perfFeeBps: p.perfFeeBps,
                managerFeeRecipient: p.managerFeeRecipient
            }),
            feeCollector,
            withdrawalQueue
        );

        strategyInstances = IManager(manager).addStrategyViaImplementations(
            p.strategyImplementations,
            p.weightsBps
        );

        emit ProductAllocationConfigured(manager, p.strategyImplementations, p.weightsBps);

        IProductRegistry(productRegistry).registerProduct(
            fund,
            IProductRegistry.FundType(uint8(p.fundType)),
            manager,
            p.asset,
            productOwner,
            p.fundMetadataURI
        );

        emit ProductCreated(
            fund,
            manager,
            msg.sender,
            uint8(p.fundType),
            p.asset,
            productOwner,
            feeCollector,
            withdrawalQueue
        );
    }

    //governance
    function setRegistries(
        address productRegistry_,
        address strategyRegistry_,
        address assetRegistry_
    )
        external
        isOwner
        isValid(productRegistry_)
        isValid(strategyRegistry_)
        isValid(assetRegistry_)
    {
        productRegistry = productRegistry_;
        strategyRegistry = strategyRegistry_;
        assetRegistry = assetRegistry_;

        emit RegistriesUpdated(productRegistry_, strategyRegistry_, assetRegistry_);
    }

    function setDefaults(address feeCollector_, address withdrawalQueue_)
        external
        isOwner
        isValid(feeCollector_)
        isValid(withdrawalQueue_)
    {
        feeCollector = feeCollector_;
        withdrawalQueue = withdrawalQueue_;
        emit DefaultsUpdated(feeCollector_, withdrawalQueue_);
    }

    function setRiskEngine(address riskEngine_)
        external
        isOwner
        isValid(riskEngine_)
    {
        riskEngine = riskEngine_;
        emit RiskEngineUpdated(riskEngine_);
    }

    function transferOwnership(address newOwner)
        external
        isOwner
        isValid(newOwner)
    {
        address oldOwner = owner;
        owner = newOwner;
        emit FactoryOwnerUpdated(oldOwner, newOwner);
    }
}
