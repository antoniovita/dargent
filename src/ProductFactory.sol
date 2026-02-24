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
error NotGovernance();
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

    address public governance;
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
        address governance_
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
            governance_ == address(0)
        ) revert ZeroAddress();

        fundImplementation = fundImpl;
        managerImplementation = managerImpl;
        productRegistry = productReg;
        strategyRegistry = strategyReg;
        assetRegistry = assetReg;
        feeCollector = feeCollector_;
        withdrawalQueue = withdrawalQueue_;
        riskEngine = riskEngine_;
        governance = governance_;
    }

    //modifiers
    modifier isGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier isValid(address a) {
        if (a == address(0)) revert ZeroAddress();
        _;
    }

    //creation
    function _validateCreateParams(CreateParams calldata p) internal view {
    if (p.asset == address(0)) revert ZeroAddress();
    if (p.managerFeeRecipient == address(0)) revert ZeroAddress();
    if (p.bufferBps > 10_000) revert InvalidBps();
    if (p.mgmtFeeBps > 10_000 || p.perfFeeBps > 10_000) revert InvalidBps();

    uint256 len = p.strategyImplementations.length;
    if (len != p.weightsBps.length) revert LengthMismatch();
    if (len == 0) revert InvalidWeights();

    if (p.fundType == FundType.HOUSE) {
        if (msg.sender != governance) revert NotGovernance();
    } else if (p.fundType != FundType.MANAGED) {
        revert InvalidFundType();
    }

    uint256 sum;
    for (uint256 i; i < len; i++) {
        uint256 w = p.weightsBps[i];
        if (w == 0) revert ZeroWeight(i);
        sum += w;
    }
    if (sum != 10_000) revert InvalidWeights();

    {
        IAssetRegistry aReg = IAssetRegistry(assetRegistry);
        if (!aReg.isApproved(p.asset)) revert AssetNotApproved(p.asset);

        IStrategyRegistry sReg = IStrategyRegistry(strategyRegistry);
        for (uint256 i; i < len; i++) {
            address impl = p.strategyImplementations[i];
            if (!sReg.isActive(impl)) revert StrategyNotActive(impl);
            if (!sReg.supportsAsset(impl, p.asset)) revert StrategyNotSupported(impl, p.asset);
        }
    }
}

    function _initializeManager(
        address manager,
        address fund,
        CreateParams calldata p
    ) internal {
        IManagerInit(manager).initialize(
            fund,
            address(this),
            riskEngine,
            p.asset,
            strategyRegistry,
            p.strategyImplementations,
            p.weightsBps
        );
    }

    function _initializeFund(address fund, address manager, CreateParams calldata p) internal {
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
    }

    function _strategyInstances(address manager)
        internal
        view
        returns (address[] memory strategyInstances)
    {
        uint256 len = IManager(manager).strategyCount();
        strategyInstances = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            strategyInstances[i] = IManager(manager).strategyAt(i);
        }
    }

    function _registerAndEmit(
        address fund,
        address manager,
        CreateParams calldata p,
        address productOwner
    ) internal {
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

    function createProduct(CreateParams calldata p)
        external
        returns (address fund, address manager, address[] memory strategyInstances)
    {
        _validateCreateParams(p);

        address productOwner = (p.fundType == FundType.HOUSE) ? governance : msg.sender;

        manager = managerImplementation.clone();
        fund = fundImplementation.clone();

        _initializeFund(fund, manager, p);
        _initializeManager(manager, fund, p);

        strategyInstances = _strategyInstances(manager);
        emit ProductAllocationConfigured(manager, p.strategyImplementations, p.weightsBps);

        _registerAndEmit(fund, manager, p, productOwner);
    }

    //governance
    function setRegistries(
        address productRegistry_,
        address strategyRegistry_,
        address assetRegistry_
    )
        external
        isGovernance
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
        isGovernance
        isValid(feeCollector_)
        isValid(withdrawalQueue_)
    {
        feeCollector = feeCollector_;
        withdrawalQueue = withdrawalQueue_;
        emit DefaultsUpdated(feeCollector_, withdrawalQueue_);
    }

    function setRiskEngine(address riskEngine_)
        external
        isGovernance
        isValid(riskEngine_)
    {
        riskEngine = riskEngine_;
        emit RiskEngineUpdated(riskEngine_);
    }

    function transferGovernance(address newGovernance)
        external
        isGovernance
        isValid(newGovernance)
    {
        address oldGovernance = governance;
        governance = newGovernance;
        emit FactoryGovernanceUpdated(oldGovernance, newGovernance);
    }
}
