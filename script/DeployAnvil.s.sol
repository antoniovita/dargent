// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {MockERC20} from "../test/mocks/MockERC20.sol";
import {StrategyMockLiquid} from "../test/mocks/StrategyMockLiquid.sol";
import {StrategyMockNonLiquid} from "../test/mocks/StrategyMockNonLiquid.sol";

import {Fund} from "../src/Fund.sol";
import {Manager} from "../src/Manager.sol";
import {ProductFactory} from "../src/ProductFactory.sol";

import {FeeCollector} from "../src/FeeCollector.sol";
import {WithdrawalQueue} from "../src/WithdrawalQueue.sol";
import {RiskEngine} from "../src/RiskEngine.sol";

import {AssetRegistry} from "../src/registry/AssetRegistry.sol";
import {StrategyRegistry} from "../src/registry/StrategyRegistry.sol";
import {ProductRegistry} from "../src/registry/ProductRegistry.sol";

import {IAssetRegistry} from "../src/interfaces/registry/IAssetRegistry.sol";
import {IStrategyRegistry} from "../src/interfaces/registry/IStrategyRegistry.sol";

contract DeployAnvil is Script {

    struct Mocks {
        MockERC20 asset;
        StrategyMockLiquid stratImplLiquid;
        StrategyMockNonLiquid stratImplNonLiquid;
    }

    struct Registries {
        AssetRegistry assetRegistry;
        StrategyRegistry strategyRegistry;
        ProductRegistry productRegistry;
    }

    struct Infra {
        RiskEngine riskEngine;
        FeeCollector feeCollector;
        WithdrawalQueue withdrawalQueue;
    }

    struct Impls {
        Fund fundImpl;
        Manager managerImpl;
    }

    struct Deployment {
        address deployer;
        Mocks mocks;
        Registries regs;
        Infra infra;
        Impls impls;
        ProductFactory factory;
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        Deployment memory d;
        d.deployer = deployer;

        d.mocks = _deployMocks();
        d.regs = _deployRegistries(deployer);
        d.infra = _deployInfra(address(d.regs.strategyRegistry), deployer);
        d.impls = _deployImpls();
        d.factory = _deployFactory(d, deployer);

        _initialConfig(d);
        _approveRegistries(d);

        vm.stopBroadcast();

        _writeJson(d);
        _log(d);
    }

    function _deployMocks() internal returns (Mocks memory m) {
        m.asset = new MockERC20("Mock USD", "mUSD", 6);
        m.stratImplLiquid = new StrategyMockLiquid();
        m.stratImplNonLiquid = new StrategyMockNonLiquid();
    }

    function _deployRegistries(address deployer) internal returns (Registries memory r) {
        r.assetRegistry = new AssetRegistry(deployer);
        r.strategyRegistry = new StrategyRegistry(deployer);
        r.productRegistry = new ProductRegistry(deployer);
    }

    function _deployInfra(address strategyRegistry, address deployer) internal returns (Infra memory i) {
        uint32[] memory thresholds = new uint32[](3);
        thresholds[0] = 100;
        thresholds[1] = 200;
        thresholds[2] = 300;

        i.riskEngine = new RiskEngine(strategyRegistry, deployer, thresholds, "ipfs://risk-meta");
        i.feeCollector = new FeeCollector(deployer, deployer, 0, 0);
        i.withdrawalQueue = new WithdrawalQueue();
    }

    function _deployImpls() internal returns (Impls memory imp) {
        imp.fundImpl = new Fund();
        imp.managerImpl = new Manager();
    }

    function _deployFactory(Deployment memory d, address deployer) internal returns (ProductFactory factory) {
        factory = new ProductFactory(
            address(d.impls.fundImpl),
            address(d.impls.managerImpl),
            address(d.regs.productRegistry),
            address(d.regs.strategyRegistry),
            address(d.regs.assetRegistry),
            address(d.infra.feeCollector),
            address(d.infra.withdrawalQueue),
            address(d.infra.riskEngine),
            deployer
        );
    }

    function _initialConfig(Deployment memory d) internal {
        d.regs.productRegistry.setFactoryAllowed(address(d.factory), true);
    }

    function _approveRegistries(Deployment memory d) internal {
        // Asset approve
        IAssetRegistry.AssetInfo memory assetInfo = IAssetRegistry.AssetInfo({
            status: IAssetRegistry.Status.ACTIVE,
            decimals: 6,
            metadataURI: "ipfs://...",
            approvedAt: uint64(block.timestamp)
        });
        d.regs.assetRegistry.approveAsset(address(d.mocks.asset), assetInfo);

        // Strategy approve (liquid)
        IStrategyRegistry.StrategyInfo memory infoLiquid = IStrategyRegistry.StrategyInfo({
            status: IStrategyRegistry.Status.ACTIVE,
            riskTier: 2,
            riskScore: 450,
            isLiquid: true,
            metadataURI: "ipfs://...",
            approvedAt: uint64(block.timestamp)
        });
        d.regs.strategyRegistry.approveStrategy(address(d.mocks.stratImplLiquid), infoLiquid);

        // Strategy approve (non-liquid)
        IStrategyRegistry.StrategyInfo memory infoNotLiquid = IStrategyRegistry.StrategyInfo({
            status: IStrategyRegistry.Status.ACTIVE,
            riskTier: 4,
            riskScore: 450,
            isLiquid: false,
            metadataURI: "ipfs://...",
            approvedAt: uint64(block.timestamp)
        });
        d.regs.strategyRegistry.approveStrategy(address(d.mocks.stratImplNonLiquid), infoNotLiquid);

        // Asset support
        d.regs.strategyRegistry.setAssetSupport(address(d.mocks.stratImplLiquid), address(d.mocks.asset), true);
        d.regs.strategyRegistry.setAssetSupport(address(d.mocks.stratImplNonLiquid), address(d.mocks.asset), true);
    }

    function _writeJson(Deployment memory d) internal {
        string memory chain = "anvil";
        string memory path = "deployments/anvil.json";

        vm.serializeAddress(chain, "deployer", d.deployer);

        vm.serializeAddress(chain, "asset", address(d.mocks.asset));
        vm.serializeAddress(chain, "stratImplLiquid", address(d.mocks.stratImplLiquid));
        vm.serializeAddress(chain, "stratImplNonLiquid", address(d.mocks.stratImplNonLiquid));

        vm.serializeAddress(chain, "assetRegistry", address(d.regs.assetRegistry));
        vm.serializeAddress(chain, "strategyRegistry", address(d.regs.strategyRegistry));
        vm.serializeAddress(chain, "productRegistry", address(d.regs.productRegistry));

        vm.serializeAddress(chain, "feeCollector", address(d.infra.feeCollector));
        vm.serializeAddress(chain, "withdrawalQueue", address(d.infra.withdrawalQueue));
        vm.serializeAddress(chain, "riskEngine", address(d.infra.riskEngine));

        vm.serializeAddress(chain, "fundImpl", address(d.impls.fundImpl));
        vm.serializeAddress(chain, "managerImpl", address(d.impls.managerImpl));

        string memory json = vm.serializeAddress(chain, "factory", address(d.factory));
        vm.writeJson(json, path);

        console2.log("Saved deployment JSON to:", path);
    }

    function _log(Deployment memory d) internal pure {
        console2.log("Deployer:", d.deployer);
        console2.log("Factory:", address(d.factory));

        console2.log("Mock Asset:", address(d.mocks.asset));
        console2.log("Strategy Liquid:", address(d.mocks.stratImplLiquid));
        console2.log("Strategy NonLiquid:", address(d.mocks.stratImplNonLiquid));

        console2.log("AssetRegistry:", address(d.regs.assetRegistry));
        console2.log("StrategyRegistry:", address(d.regs.strategyRegistry));
        console2.log("ProductRegistry:", address(d.regs.productRegistry));

        console2.log("FeeCollector:", address(d.infra.feeCollector));
        console2.log("WithdrawalQueue:", address(d.infra.withdrawalQueue));
        console2.log("RiskEngine:", address(d.infra.riskEngine));

        console2.log("FundImpl:", address(d.impls.fundImpl));
        console2.log("ManagerImpl:", address(d.impls.managerImpl));
    }
}
