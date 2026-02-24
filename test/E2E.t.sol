// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./BaseTest.t.sol";

import {IProductFactory} from "../src/interfaces/IProductFactory.sol";
import {IProductRegistry} from "../src/interfaces/registry/IProductRegistry.sol";
import {Fund} from "../src/Fund.sol";
import {Manager} from "../src/Manager.sol";
import {StrategyMockNonLiquid} from "./mocks/StrategyMockNonLiquid.sol";

contract E2ETest is BaseTest {
    function test_productInfo_mirrorsFundRiskAndSharePrice() external {
        address[] memory impls = new address[](2);
        impls[0] = address(stratImplLiquid);
        impls[1] = address(stratImplNonLiquid);

        uint16[] memory weights = new uint16[](2);
        weights[0] = 7_000;
        weights[1] = 3_000;

        vm.startPrank(owner);
        IProductFactory.CreateParams memory params = IProductFactory.CreateParams({
            fundType: IProductFactory.FundType.MANAGED,
            asset: address(asset),
            fundMetadataURI: "ipfs://product-meta",
            bufferBps: 1000,
            mgmtFeeBps: 200,
            perfFeeBps: 1000,
            managerFeeRecipient: owner,
            strategyImplementations: impls,
            weightsBps: weights
        });
        (address fundAddr, , ) = factory.createProduct(params);
        vm.stopPrank();

        Fund fund = Fund(fundAddr);
        IProductRegistry.ProductInfo memory info = productRegistry.getProductInfo(fundAddr);

        assertEq(info.sharePrice, fund.convertToAssets(1e18));
        assertEq(info.riskTier, fund.riskTier());
        assertEq(info.riskScore, fund.riskScore());
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
            fundType: IProductFactory.FundType.MANAGED,
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
            fundType: IProductFactory.FundType.MANAGED,
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
}
