// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {StrategyMockLiquid} from "./mocks/StrategyMockLiquid.sol";
import {StrategyMockNonLiquid} from "./mocks/StrategyMockNonLiquid.sol";

import {ProductFactory} from "../src/ProductFactory.sol";
import {Fund} from "../src/Fund.sol";
import {Manager} from "../src/Manager.sol";

import {IAssetRegistry} from "../src/interfaces/registry/IAssetRegistry.sol";
import {AssetRegistry} from "../src/registry/AssetRegistry.sol";

import {IStrategyRegistry} from "../src/interfaces/registry/IStrategyRegistry.sol";
import {StrategyRegistry} from "../src/registry/StrategyRegistry.sol";

import {ProductRegistry} from "../src/registry/ProductRegistry.sol";

import {FeeCollector} from "../src/FeeCollector.sol";
import {WithdrawalQueue} from "../src/WithdrawalQueue.sol";
import {RiskEngine} from "../src/RiskEngine.sol";

contract BaseTest is Test {
    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);

    MockERC20 internal asset;

    AssetRegistry internal assetRegistry;
    StrategyRegistry internal strategyRegistry;
    ProductRegistry internal productRegistry;

    FeeCollector internal feeCollector;
    WithdrawalQueue internal withdrawalQueue;
    RiskEngine internal riskEngine;

    Fund internal fundImpl;
    Manager internal managerImpl;

    ProductFactory internal factory;

    StrategyMockLiquid internal stratImplLiquid;
    StrategyMockNonLiquid internal stratImplNonLiquid;

    function setUp() public virtual {
        vm.startPrank(owner);

        // mock ERC20 for testing
        asset = new MockERC20("Mock USD", "mUSD", 6);

        // registries + infra
        assetRegistry = new AssetRegistry(owner);
        strategyRegistry = new StrategyRegistry(owner);
        productRegistry = new ProductRegistry(owner);

        feeCollector = new FeeCollector(owner, owner, 0, 0);
        withdrawalQueue = new WithdrawalQueue();
        uint32[] memory thresholds = new uint32[](3);
        thresholds[0] = 100;
        thresholds[1] = 200;
        thresholds[2] = 300;
        riskEngine = new RiskEngine(address(strategyRegistry), owner, thresholds, "ipfs://risk-meta");

        // manager and fund implementations
        fundImpl = new Fund();
        managerImpl = new Manager();

        stratImplLiquid = new StrategyMockLiquid();
        stratImplNonLiquid = new StrategyMockNonLiquid();

        factory = new ProductFactory(
            address(fundImpl),
            address(managerImpl),
            address(productRegistry),
            address(strategyRegistry),
            address(assetRegistry),
            address(feeCollector),
            address(withdrawalQueue),
            address(riskEngine),
            owner
        );

        // allow factory in ProductRegistry
        productRegistry.setFactoryAllowed(address(factory), true);

        // register/activate asset
        IAssetRegistry.AssetInfo memory info = IAssetRegistry.AssetInfo({
            status: IAssetRegistry.Status.ACTIVE,
            decimals: 6,
            metadataURI: "ipfs://...",
            approvedAt: uint64(block.timestamp)
        });
        assetRegistry.approveAsset(address(asset), info);

        // register/activate strategy
        IStrategyRegistry.StrategyInfo memory infoLiquid = IStrategyRegistry.StrategyInfo({
            status: IStrategyRegistry.Status.ACTIVE,
            riskTier: 2,
            riskScore: 450,
            isLiquid: true,
            metadataURI: "ipfs://...",
            approvedAt: uint64(block.timestamp)
        });
        strategyRegistry.approveStrategy(address(stratImplLiquid), infoLiquid);

        IStrategyRegistry.StrategyInfo memory infoNotLiquid = IStrategyRegistry.StrategyInfo({
            status: IStrategyRegistry.Status.ACTIVE,
            riskTier: 4,
            riskScore: 450,
            isLiquid: false,
            metadataURI: "ipfs://...",
            approvedAt: uint64(block.timestamp)
        });
        strategyRegistry.approveStrategy(address(stratImplNonLiquid), infoNotLiquid);

        // set asset support for each strategy
        strategyRegistry.setAssetSupport(address(stratImplLiquid), address(asset), true);
        strategyRegistry.setAssetSupport(address(stratImplNonLiquid), address(asset), true);

        vm.stopPrank();

        // user funds
        asset.mint(user, 1_000_000 * 10**asset.decimals());
    }
}
