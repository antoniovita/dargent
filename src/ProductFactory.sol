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
error InvalidBps();
error AssetNotApproved(address asset);
error StrategyNotActive(address implementation);
error StrategyNotSupported(address implementation, address asset);
error ZeroWeight(uint256 index);
error InvalidTiltParams();
error InvalidRebalancePolicy();

contract ProductFactory is IProductFactory {
    using Clones for address;

    uint16 internal constant MAX_ALLOWED_TILT_BPS = 1500; //15%
    uint64 internal constant MIN_TILT_COOLDOWN = 1 days;
    uint64 internal constant MAX_TILT_COOLDOWN = 14 days;

    uint16 internal constant MAX_ALLOWED_REBALANCE_BAND_BPS = 500; //5%
    uint64 internal constant MIN_REBALANCE_COOLDOWN = 1 days;
    uint64 internal constant MAX_REBALANCE_COOLDOWN = 30 days;

    address public governance;
    address public immutable fundImplementation;
    address public immutable managerImplementation;
    address public productRegistry;
    address public strategyRegistry;
    address public assetRegistry;
    address public feeCollector;
    address public withdrawalQueue;
    address public riskEngine;
    uint16 public defaultTiltMaxBps;
    uint16 public defaultTiltMaxStepBps;
    uint64 public defaultTiltCooldown;
    uint16 public defaultRebalanceBandBps;
    uint16 public rebalanceBandMinBps;
    uint16 public rebalanceBandMaxBps;
    uint64 public rebalanceBandCooldown;

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

        defaultTiltMaxBps = 1000;
        defaultTiltMaxStepBps = 300;
        defaultTiltCooldown = 3 days;

        defaultRebalanceBandBps = 200;
        rebalanceBandMinBps = 150;
        rebalanceBandMaxBps = 300;
        rebalanceBandCooldown = 7 days;
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
        CreateParams calldata p,
        address managerOwner
    ) internal {
        IManagerInit(manager).initialize(
            fund,
            address(this),
            managerOwner,
            riskEngine,
            p.asset,
            strategyRegistry,

            defaultTiltMaxBps,
            defaultTiltMaxStepBps,
            defaultTiltCooldown,

            defaultRebalanceBandBps,
            rebalanceBandMinBps,
            rebalanceBandMaxBps,
            rebalanceBandCooldown,
            
            p.strategyImplementations,
            p.weightsBps
        );
    }

    function _initializeFund(address fund, address manager, CreateParams calldata p) internal {
        IFundInit(fund).initialize(
            p.asset,
            manager,
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
            manager,
            p.asset,
            productOwner,
            p.fundMetadataURI
        );

        emit ProductCreated(
            fund,
            manager,
            msg.sender,
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

        address productOwner = msg.sender;

        manager = managerImplementation.clone();
        fund = fundImplementation.clone();

        _initializeFund(fund, manager, p);
        _initializeManager(manager, fund, p, productOwner);

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

    function setDefaultTiltParams(uint16 maxTiltBps_, uint16 maxStepBps_, uint64 cooldown_) external isGovernance {
        if (
            maxTiltBps_ == 0 ||
            maxStepBps_ == 0 ||
            maxStepBps_ > maxTiltBps_ ||
            maxTiltBps_ > MAX_ALLOWED_TILT_BPS ||
            cooldown_ < MIN_TILT_COOLDOWN ||
            cooldown_ > MAX_TILT_COOLDOWN
        ) revert InvalidTiltParams();

        defaultTiltMaxBps = maxTiltBps_;
        defaultTiltMaxStepBps = maxStepBps_;
        defaultTiltCooldown = cooldown_;

        emit DefaultTiltParamsUpdated(maxTiltBps_, maxStepBps_, cooldown_);
    }

    function setDefaultRebalancePolicy(
        uint16 defaultBand_,
        uint16 minBand_,
        uint16 maxBand_,
        uint64 cooldown_
    ) external isGovernance {
        if (
            minBand_ == 0 ||
            minBand_ > defaultBand_ ||
            defaultBand_ > maxBand_ ||
            maxBand_ > MAX_ALLOWED_REBALANCE_BAND_BPS ||
            cooldown_ < MIN_REBALANCE_COOLDOWN ||
            cooldown_ > MAX_REBALANCE_COOLDOWN
        ) revert InvalidRebalancePolicy();

        defaultRebalanceBandBps = defaultBand_;
        rebalanceBandMinBps = minBand_;
        rebalanceBandMaxBps = maxBand_;
        rebalanceBandCooldown = cooldown_;

        emit DefaultRebalancePolicyUpdated(defaultBand_, minBand_, maxBand_, cooldown_);
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
