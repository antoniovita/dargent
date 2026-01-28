// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IProductFactory {
    enum FundType {
        HOUSE,
        MANAGED
    }

    struct CreateParams {
        FundType fundType;
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
        uint8 fundType,
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

    function transferGovernance(
        address newGovernance
    ) external;
}
