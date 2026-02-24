// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IManager} from "./interfaces/IManager.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IStrategyRegistry} from "./interfaces/registry/IStrategyRegistry.sol";

import {IRiskEngine} from "./interfaces/IRiskEngine.sol";
import {IFund} from "./interfaces/IFund.sol";

error NotFund();
error NotInitialized();
error AlreadyInitialized();
error ZeroAddress();
error InvalidBps();
error LengthMismatch();
error InvalidWeights();
error StrategyNotActive(address implementation);
error StrategyNotSupported(address implementation, address asset);
error DuplicateStrategy(address strategyInstance);
error ImplementationAlreadyUsed(address implementation);
error ActiveWeightZero(address strategyInstance);
error WeightBelowMin(address strategyInstance, uint16 weightBps);

contract Manager is IManager, ReentrancyGuard {
    using Clones for address;

    uint16 internal constant MIN_WEIGHT_BPS = 100; // 1.00%

    bool public initialized;
    bool public emergencyStopped;

    address public fund;
    address public asset;
    address public strategyRegistry;
    address public riskEngine;

    address[] internal _strategies;

    mapping(address => uint16) public strategyWeight;
    mapping(address => bool) internal _isStrategy;
    mapping(address => bool) internal _implUsed;
    mapping(address => address) public _strategyImplementationOf;
    mapping(address => uint256) internal allocationCarry;

    modifier onlyInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    modifier onlyFund() {
        if (msg.sender != fund) revert NotFund();
        _;
    }

    function minWeightBps() external pure returns (uint16) {
        return MIN_WEIGHT_BPS;
    }

    function initialize(
        address fund_,
        address riskEngine_,
        address asset_,
        address strategyRegistry_,
        address[] calldata implementations,
        uint16[] calldata weightsBps
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            fund_ == address(0) ||
            asset_ == address(0) ||
            strategyRegistry_ == address(0) ||
            riskEngine_ == address(0)
        ) revert ZeroAddress();

        uint256 len = implementations.length;
        if (len == 0) revert InvalidWeights();
        if (len != weightsBps.length) revert LengthMismatch();

        fund = fund_;
        asset = asset_;
        strategyRegistry = strategyRegistry_;
        riskEngine = riskEngine_;

        uint256 sum;

        for (uint256 i = 0; i < len; i++) {
            address impl = implementations[i];
            uint16 w = weightsBps[i];

            if (impl == address(0)) revert ZeroAddress();
            if (w < MIN_WEIGHT_BPS || w > 10_000) revert InvalidBps();

            _validateImplementation(impl);
            if (_implUsed[impl]) revert ImplementationAlreadyUsed(impl);

            _implUsed[impl] = true;

            address inst = impl.clone();
            IStrategy(inst).initialize(address(this), asset_);

            if (_isStrategy[inst]) revert DuplicateStrategy(inst);

            _strategies.push(inst);
            _isStrategy[inst] = true;
            strategyWeight[inst] = w;
            _strategyImplementationOf[inst] = impl;
            allocationCarry[inst] = 0;

            sum += w;
            emit StrategyAdded(impl, inst, w);
        }

        if (sum != 10_000) revert InvalidWeights();

        _enforceMinWeights();
        _refreshRisk();

        initialized = true;
    }

    function totalAssets() external view override onlyInitialized returns (uint256) {
        uint256 total = IERC20(asset).balanceOf(fund);

        uint256 len = _strategies.length;
        for (uint256 i = 0; i < len; i++) {
            total += IStrategy(_strategies[i]).totalAssets();
        }

        return total;
    }

    function strategyImplementationOf(address instance) external view override returns (address) {
        return _strategyImplementationOf[instance];
    }

    function strategyCount() external view override returns (uint256) {
        return _strategies.length;
    }

    function strategyAt(uint256 index) external view override returns (address) {
        return _strategies[index];
    }

    function getAllocation()
        external
        view
        override
        returns (address[] memory strategyInstances, uint16[] memory weightsBps)
    {
        uint256 len = _strategies.length;
        strategyInstances = new address[](len);
        weightsBps = new uint16[](len);

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            strategyInstances[i] = s;
            weightsBps[i] = strategyWeight[s];
        }
    }

    function allocate(uint256 assets_) external override onlyInitialized onlyFund nonReentrant {
        if (emergencyStopped || assets_ == 0) return;

        (uint256 activeCount, uint256 lastActiveIndex) = _activeCountAndLastIndex();
        if (activeCount == 0) return;

        address lastActive = _strategies[lastActiveIndex];
        uint256 remaining = assets_;
        uint256 len = _strategies.length;

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            uint16 w = strategyWeight[s];
            if (w == 0) continue;

            uint256 raw = assets_ * uint256(w) + allocationCarry[s];
            uint256 amt = raw / 10_000;
            allocationCarry[s] = raw % 10_000;

            if (s == lastActive) continue;
            if (amt == 0) continue;

            IStrategy(s).deposit(amt);
            remaining -= amt;
        }

        if (remaining > 0) {
            IStrategy(lastActive).deposit(remaining);
        }
    }

    function deallocate(uint256 assets_)
        external
        override
        onlyInitialized
        onlyFund
        nonReentrant
        returns (uint256 freed)
    {
        if (assets_ == 0) return 0;

        uint256 remaining = assets_;
        uint256 len = _strategies.length;

        IStrategyRegistry sReg = IStrategyRegistry(strategyRegistry);

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            address impl = _strategyImplementationOf[s];
            if (!sReg.isLiquid(impl)) continue;

            uint256 got = IStrategy(s).withdraw(remaining, fund);
            freed += got;

            if (freed >= assets_) return freed;
            remaining = assets_ - freed;
        }

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            address impl = _strategyImplementationOf[s];
            if (sReg.isLiquid(impl)) continue;

            uint256 got = IStrategy(s).withdraw(remaining, fund);
            freed += got;

            if (freed >= assets_) return freed;
            remaining = assets_ - freed;
        }
    }

    function emergencyStop() external override onlyInitialized onlyFund {
        if (emergencyStopped) return;
        emergencyStopped = true;
        emit EmergencyStopped();
    }

    function _validateImplementation(address impl) internal view {
        IStrategyRegistry sReg = IStrategyRegistry(strategyRegistry);
        if (!sReg.isActive(impl)) revert StrategyNotActive(impl);
        if (!sReg.supportsAsset(impl, asset)) revert StrategyNotSupported(impl, asset);
    }

    function _enforceMinWeights() internal view {
        uint256 len = _strategies.length;
        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            uint16 w = strategyWeight[s];
            if (w == 0) revert ActiveWeightZero(s);
            if (w < MIN_WEIGHT_BPS) revert WeightBelowMin(s, w);
        }
    }

    function _activeCountAndLastIndex() internal view returns (uint256 count, uint256 lastIndex) {
        uint256 len = _strategies.length;
        bool found;
        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (strategyWeight[s] == 0) continue;
            count++;
            lastIndex = i;
            found = true;
        }
        if (!found) lastIndex = 0;
    }

    function _refreshRisk() internal {
        address re = riskEngine;
        if (re == address(0)) return;

        (uint8 tier, uint32 score) = IRiskEngine(re).computeRisk(address(this));
        IFund(fund).setRisk(tier, score);
    }
}
