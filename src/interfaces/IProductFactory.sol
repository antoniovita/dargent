// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IProductFactory {

    struct CreateParams {
        address asset;
        string fundMetadataURI;
        uint16 bufferBps;
        uint16 mgmtFeeBps;
        uint16 perfFeeBps;
        address managerFeeRecipient;
        address[] strategyImplementations;
        uint16[] weightsBps;
    }

    // events
    event ProductCreated(
        address indexed fund,
        address indexed manager,
        address indexed creator,
        address asset,
        address productOwner,
        address feeCollector,
        address withdrawalQueue
    );

    event ProductAllocationConfigured(
        address indexed manager,
        address[] strategyImplementations,
        uint16[] weightsBps
    );

    event RegistriesUpdated(
        address productRegistry,
        address strategyRegistry,
        address assetRegistry
    );

    event DefaultsUpdated(
        address feeCollector,
        address withdrawalQueue
    );

    event RiskEngineUpdated(
        address indexed newRiskEngine
    );
    
    event DefaultTiltParamsUpdated(
        uint16 maxTiltBps,
        uint16 maxStepBps,
        uint64 tiltCooldown
    );
    
    event DefaultRebalancePolicyUpdated(
        uint16 defaultBand,
        uint16 minBand,
        uint16 maxBand,
        uint64 cooldown
    );

    event FactoryGovernanceUpdated(
        address indexed oldGovernance,
        address indexed newGovernance
    );

    // view
    function governance() external view returns (address);

    function fundImplementation() external view returns (address);
    function managerImplementation() external view returns (address);

    function productRegistry() external view returns (address);
    function strategyRegistry() external view returns (address);
    function assetRegistry() external view returns (address);

    function feeCollector() external view returns (address);
    function withdrawalQueue() external view returns (address);
    function riskEngine() external view returns (address);

    function defaultTiltMaxBps() external view returns (uint16);
    function defaultTiltMaxStepBps() external view returns (uint16);
    function defaultTiltCooldown() external view returns (uint64);
    
    function defaultRebalanceBandBps() external view returns (uint16);
    function rebalanceBandMinBps() external view returns (uint16);
    function rebalanceBandMaxBps() external view returns (uint16);
    function rebalanceBandCooldown() external view returns (uint64);

    // create
    function createProduct(CreateParams calldata p)
        external
        returns (
            address fund,
            address manager,
            address[] memory strategyInstances
        );

    // governance
    function setRegistries(
        address productRegistry_,
        address strategyRegistry_,
        address assetRegistry_
    ) external;

    function setDefaults(
        address feeCollector_,
        address withdrawalQueue_
    ) external;

    function setRiskEngine(
        address riskEngine_
    ) external;
    
    function setDefaultTiltParams(
        uint16 maxTiltBps_,
        uint16 maxStepBps_,
        uint64 cooldown_
    ) external;
    
    function setDefaultRebalancePolicy(
        uint16 defaultBand_,
        uint16 minBand_,
        uint16 maxBand_,
        uint64 cooldown_
    ) external;

    function transferGovernance(
        address newGovernance
    ) external;
}
