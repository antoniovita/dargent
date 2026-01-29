// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStrategy} from "../../src/interfaces/IStrategy.sol";

contract StrategyMockLiquid is IStrategy {
    bool private _initialized;
    address public override asset;
    address public override manager;
    uint256 public aum;

    modifier onlyManager() {
        require(msg.sender == manager, "NOT_MANAGER");
        _;
    }

    modifier onlyInitialized() {
        require(_initialized, "NOT_INITIALIZED");
        _;
    }

    function initialize(address manager_, address asset_) external override {
        require(!_initialized, "ALREADY_INITIALIZED");
        require(manager_ != address(0) && asset_ != address(0), "ZERO_ADDRESS");
        manager = manager_;
        asset = asset_;
        _initialized = true;
    }

    function totalAssets() external view override onlyInitialized returns (uint256) {
        return aum;
    }

    function maxDeposit() external view override onlyInitialized returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw() external view override onlyInitialized returns (uint256) {
        return aum;
    }

    function deposit(uint256 amount) external override onlyManager onlyInitialized returns (uint256) {
        if (amount == 0) return 0;
        aum += amount;
        return amount;
    }

    function withdraw(uint256 amount, address)
        external
        override
        onlyManager
        onlyInitialized
        returns (uint256)
    {
        if (amount == 0) return 0;
        if (amount > aum) amount = aum;
        aum -= amount;
        return amount;
    }

    function maxPossibleWithdraw(address)
        external
        override
        onlyManager
        onlyInitialized
        returns (uint256 freedAssets)
    {
        freedAssets = aum;
        aum = 0;
        return freedAssets;
    }
}
