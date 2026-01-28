// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IStrategy} from "../interfaces/IStrategy.sol";
import {IAavePool} from "../interfaces/strategy/aave/IAavePool.sol";
import {IAaveProtocolDataProvider} from "../interfaces/strategy/aave/IAaveProtocolDataProvider.sol";
import {IAToken} from "../interfaces/strategy/aave/IAToken.sol";

// errors
error NotManager();
error ZeroAddress();
error AlreadyInitialized();
error NotInitialized();
error InvalidAmount();
error StrategyAssetMismatch(address aToken, address expectedAsset, address gotAsset);

contract AaveLendingStrategy is IStrategy, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bool private _initialized;
    address public override asset;
    address public override manager;
    bool public override isLiquid;

    IAavePool public immutable pool;
    IAaveProtocolDataProvider public immutable dataProvider;
    address public aToken;


    //events
    event Initialized(address indexed manager, address indexed asset, address indexed aToken);
    event Deposited(address indexed caller, uint256 assets, uint256 aTokenBalanceAfter);
    event Withdrawn(address indexed caller, address indexed receiver, uint256 requestedAssets, uint256 withdrawnAssets);

    //modifiers
    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    modifier onlyInitialized() {
        if (!_initialized) revert NotInitialized();
        _;
    }

    constructor(address pool_, address dataProvider_) {
        if (pool_ == address(0) || dataProvider_ == address(0)) revert ZeroAddress();
        pool = IAavePool(pool_);
        dataProvider = IAaveProtocolDataProvider(dataProvider_);
    }

    //view
    function totalAssets() public view override onlyInitialized returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 inAave = IERC20(aToken).balanceOf(address(this));
        return idle + inAave;
    }

    function maxDeposit() external view override onlyInitialized returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw() public view override onlyInitialized returns (uint256) {
        uint256 total = totalAssets();
        uint256 available = IERC20(asset).balanceOf(aToken);
        return total < available ? total : available;
    }

    //write
    function deposit(uint256 assets)
        external
        override
        onlyManager
        onlyInitialized
        nonReentrant
        returns (uint256 depositedAssets)
    {
        if (assets == 0) revert InvalidAmount();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);
        IERC20(asset).forceApprove(address(pool), assets);

        pool.supply(asset, assets, address(this), 0);
        emit Deposited(msg.sender, assets, IERC20(aToken).balanceOf(address(this)));
        return assets;
    }

    function withdraw(uint256 assets, address receiver)
        external
        override
        onlyManager
        onlyInitialized
        nonReentrant
        returns (uint256 withdrawnAssets)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (assets == 0) revert InvalidAmount();

        uint256 m = maxWithdraw();
        uint256 toWithdraw = assets <= m ? assets : m;

        withdrawnAssets = pool.withdraw(asset, toWithdraw, receiver);

        emit Withdrawn(msg.sender, receiver, assets, withdrawnAssets);
        return withdrawnAssets;
    }

    function maxPossibleWithdraw(address receiver)
        external
        override
        onlyManager
        onlyInitialized
        nonReentrant
        returns (uint256 freedAssets)
    {
        if (receiver == address(0)) revert ZeroAddress();

        uint256 m = maxWithdraw();
        if (m == 0) return 0;

        freedAssets = pool.withdraw(asset, m, receiver);

        emit Withdrawn(msg.sender, receiver, m, freedAssets);
        return freedAssets;
    }

    //init
    function initialize(address manager_, address asset_) external override {
        if (_initialized) revert AlreadyInitialized();
        if (manager_ == address(0) || asset_ == address(0)) revert ZeroAddress();

        manager = manager_;
        asset = asset_;
        isLiquid = true;

        (address aTokenAddr,,) = dataProvider.getReserveTokensAddresses(asset_);
        if (aTokenAddr == address(0)) revert ZeroAddress();

        address underlying = IAToken(aTokenAddr).UNDERLYING_ASSET_ADDRESS();
        if (underlying != asset_) revert StrategyAssetMismatch(aTokenAddr, asset_, underlying);

        aToken = aTokenAddr;

        _initialized = true;
        emit Initialized(manager_, asset_, aTokenAddr);
    }
}
