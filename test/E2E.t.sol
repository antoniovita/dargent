// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./BaseTest.t.sol";

import {IProductFactory} from "../src/interfaces/IProductFactory.sol";
import {IProductRegistry} from "../src/interfaces/registry/IProductRegistry.sol";
import {Fund} from "../src/Fund.sol";
import {Manager} from "../src/Manager.sol";
import {StrategyMockLiquid} from "./mocks/StrategyMockLiquid.sol";
import {StrategyMockNonLiquid} from "./mocks/StrategyMockNonLiquid.sol";

contract E2ETest is BaseTest {
    function _createDefaultProduct(uint16 w0, uint16 w1, uint16 bufferBps)
        internal
        returns (address fundAddr, address managerAddr, address[] memory instances)
    {
        address[] memory impls = new address[](2);
        impls[0] = address(stratImplLiquid);
        impls[1] = address(stratImplNonLiquid);

        uint16[] memory weights = new uint16[](2);
        weights[0] = w0;
        weights[1] = w1;

        vm.startPrank(owner);
        IProductFactory.CreateParams memory params = IProductFactory.CreateParams({
            asset: address(asset),
            fundMetadataURI: "ipfs://product-meta",
            bufferBps: bufferBps,
            mgmtFeeBps: 0,
            perfFeeBps: 0,
            managerFeeRecipient: owner,
            strategyImplementations: impls,
            weightsBps: weights
        });
        (fundAddr, managerAddr, instances) = factory.createProduct(params);
        vm.stopPrank();
    }

    function test_getProductInfo_returnsRegisteredMetadata() external {
        address[] memory impls = new address[](2);
        impls[0] = address(stratImplLiquid);
        impls[1] = address(stratImplNonLiquid);

        uint16[] memory weights = new uint16[](2);
        weights[0] = 7_000;
        weights[1] = 3_000;

        vm.startPrank(owner);
        IProductFactory.CreateParams memory params = IProductFactory.CreateParams({
            asset: address(asset),
            fundMetadataURI: "ipfs://product-meta",
            bufferBps: 1000,
            mgmtFeeBps: 200,
            perfFeeBps: 1000,
            managerFeeRecipient: owner,
            strategyImplementations: impls,
            weightsBps: weights
        });
        (address fundAddr, address managerAddr, ) = factory.createProduct(params);
        vm.stopPrank();

        IProductRegistry.ProductInfo memory info = productRegistry.getProductInfo(fundAddr);

        assertEq(uint8(info.status), uint8(IProductRegistry.Status.ACTIVE));
        assertEq(info.manager, managerAddr);
        assertEq(info.asset, address(asset));
        assertEq(info.productOwner, owner);
        assertEq(info.metadataURI, "ipfs://product-meta");
        assertGt(info.createdAt, 0);
    }

    function test_deposit_allocate_withdraw_process_claim() external {
        address[] memory impls = new address[](2);
        impls[0] = address(stratImplLiquid);
        impls[1] = address(stratImplNonLiquid);

        uint16[] memory weights = new uint16[](2);
        weights[0] = 7_000; // 70%
        weights[1] = 3_000; // 30%

        vm.startPrank(owner);

        IProductFactory.CreateParams memory params = IProductFactory.CreateParams({
            asset: address(asset),
            fundMetadataURI: "ipfs://product-meta",
            bufferBps: 1000,
            mgmtFeeBps: 200,
            perfFeeBps: 1000,
            managerFeeRecipient: owner,
            strategyImplementations: impls,
            weightsBps: weights
        });

        (address fundAddr, address managerAddr, ) = factory.createProduct(params);

        vm.stopPrank();

        Fund fund = Fund(fundAddr);
        Manager manager = Manager(managerAddr);
        assertTrue(manager.initialized());

        uint256 depositAmt = 1_000 * 10**asset.decimals();

        vm.startPrank(user);
        asset.approve(fundAddr, depositAmt);
        uint256 sharesOut = fund.deposit(depositAmt, user);
        assertGt(sharesOut, 0);
        vm.stopPrank();

        uint256 sharesToWithdraw = sharesOut / 2;

        vm.startPrank(user);
        uint256 requestId = fund.requestWithdraw(sharesToWithdraw, user, user);
        vm.stopPrank();

        vm.prank(owner);
        fund.processWithdrawals(50);

        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        withdrawalQueue.claim(requestId);

        uint256 balAfter = asset.balanceOf(user);
        assertGt(balAfter, balBefore);
    }

    function test_withdraw_nonLiquidBlocks_untilUnlock_then_process() external {
        address[] memory impls = new address[](2);
        impls[0] = address(stratImplLiquid);
        impls[1] = address(stratImplNonLiquid);

        uint16[] memory weights = new uint16[](2);
        weights[0] = 2_000; // 20% liquid
        weights[1] = 8_000; // 80% non-liquid

        vm.startPrank(owner);
        IProductFactory.CreateParams memory params = IProductFactory.CreateParams({
            asset: address(asset),
            fundMetadataURI: "ipfs://product-meta",
            bufferBps: 10_000,
            mgmtFeeBps: 0,
            perfFeeBps: 0,
            managerFeeRecipient: owner,
            strategyImplementations: impls,
            weightsBps: weights
        });

        (address fundAddr, , address[] memory instances) = factory.createProduct(params);
        vm.stopPrank();

        Fund fund = Fund(fundAddr);

        uint256 depositAmt = 1_000 * 10**asset.decimals();

        vm.startPrank(user);
        asset.approve(fundAddr, depositAmt);
        uint256 sharesOut = fund.deposit(depositAmt, user);

        uint256 requestId = fund.requestWithdraw(sharesOut * 9 / 10, user, user);
        vm.stopPrank();

        vm.prank(owner);
        fund.processWithdrawals(50);

        StrategyMockNonLiquid(instances[1]).setUnlocked(true);

        vm.prank(owner);
        fund.processWithdrawals(50);

        uint256 balBefore = asset.balanceOf(user);
        vm.prank(user);
        withdrawalQueue.claim(requestId);
        uint256 balAfter = asset.balanceOf(user);
        assertGt(balAfter, balBefore);
    }

    function test_rebalanceBand_default_and_local_update_with_cooldown() external {
        (, address managerAddr,) = _createDefaultProduct(7_000, 3_000, 1000);
        Manager manager = Manager(managerAddr);

        assertEq(manager.rebalanceBandBps(), 200);
        assertEq(manager.minRebalanceBandBps(), 150);
        assertEq(manager.maxRebalanceBandBps(), 300);

        vm.prank(owner);
        manager.setRebalanceBandBps(250);
        assertEq(manager.rebalanceBandBps(), 250);

        vm.prank(owner);
        vm.expectRevert();
        manager.setRebalanceBandBps(260);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(owner);
        manager.setRebalanceBandBps(260);
        assertEq(manager.rebalanceBandBps(), 260);
    }

    function test_allocate_prioritizes_underweight_strategy() external {
        vm.prank(owner);
        factory.setDefaultTiltParams(1000, 1000, 1 days);

        (address fundAddr, address managerAddr, address[] memory instances) = _createDefaultProduct(7_000, 3_000, 0);
        Fund fund = Fund(fundAddr);
        Manager manager = Manager(managerAddr);

        uint256 unit = 10**asset.decimals();
        StrategyMockLiquid(instances[0]).setAum(700 * unit);
        StrategyMockNonLiquid(instances[1]).setAum(300 * unit);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(owner);
        manager.setTilt(_arr2(1000, -1000), bytes32("t1"));

        uint256 a0Before = StrategyMockLiquid(instances[0]).aum();
        uint256 a1Before = StrategyMockNonLiquid(instances[1]).aum();

        uint256 d1 = 100 * unit;
        vm.startPrank(user);
        asset.approve(fundAddr, d1);
        fund.deposit(d1, user);
        vm.stopPrank();

        uint256 a0 = StrategyMockLiquid(instances[0]).aum();
        uint256 a1 = StrategyMockNonLiquid(instances[1]).aum();
        assertEq(a0 - a0Before, d1);
        assertEq(a1 - a1Before, 0);
    }

    function test_rebalance_moves_from_overweight_to_underweight() external {
        (, address managerAddr, address[] memory instances) = _createDefaultProduct(7_000, 3_000, 0);
        Manager manager = Manager(managerAddr);

        uint256 unit = 10**asset.decimals();
        StrategyMockLiquid(instances[0]).setAum(900 * unit);
        StrategyMockNonLiquid(instances[1]).setAum(100 * unit);
        StrategyMockNonLiquid(instances[1]).setUnlocked(true);
        
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(owner);
        uint256 moved = manager.rebalance(type(uint256).max, 5);

        uint256 a0 = StrategyMockLiquid(instances[0]).aum();
        uint256 a1 = StrategyMockNonLiquid(instances[1]).aum();
        assertEq(moved, 186 * unit);
        assertEq(a0, 714 * unit);
        assertEq(a1, 286 * unit);
    }

    function test_rebalance_reverts_for_unauthorized_caller() external {
        (, address managerAddr,) = _createDefaultProduct(7_000, 3_000, 1000);
        Manager manager = Manager(managerAddr);

        vm.prank(user);
        vm.expectRevert();
        manager.rebalance(1, 1);
    }

    function test_factory_updates_default_rebalance_policy() external {
        vm.prank(owner);
        factory.setDefaultRebalancePolicy(220, 180, 320, 8 days);

        assertEq(factory.defaultRebalanceBandBps(), 220);
        assertEq(factory.rebalanceBandMinBps(), 180);
        assertEq(factory.rebalanceBandMaxBps(), 320);
        assertEq(factory.rebalanceBandCooldown(), 8 days);

        vm.prank(owner);
        vm.expectRevert();
        factory.setDefaultRebalancePolicy(100, 150, 300, 7 days);
    }

    function _arr2(int16 a, int16 b) internal pure returns (int16[] memory arr) {
        arr = new int16[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
