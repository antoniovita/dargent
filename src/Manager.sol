// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IManager} from "./interfaces/IManager.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IStrategyRegistry} from "./interfaces/registry/IStrategyRegistry.sol";

// errors
error NotOwner();
error NotFund();
error NotInitialized();
error AlreadyInitialized();
error ZeroAddress();
error InvalidBps();
error LengthMismatch();
error InvalidWeights();
error ZeroWeight(uint256 index);
error StrategyNotActive(address implementation);
error StrategyNotSupported(address implementation, address asset);
error UnknownStrategy(address strategyInstance);
error DuplicateStrategy(address strategyInstance);
error ImplementationAlreadyUsed(address implementation);
error StrategyRemoving(address strategyInstance);
error CannotRedistribute();
error CannotRemoveLastStrategy();
error ActiveWeightZero(address strategyInstance);

contract Manager is IManager, ReentrancyGuard {
    using Clones for address;

    bool public initialized;
    address public fund;
    address public asset;
    address public strategyRegistry;
    address public owner;
    address[] internal _strategies;

    mapping(address => uint16) public strategyWeight;
    mapping(address => bool) internal _isStrategy;
    mapping(address => bool) internal _implUsed;
    mapping(address => address) public strategyImplementationOf;
    mapping(address => bool) public isRemoving;
    mapping(address => uint16) public removingWeightBps;
    mapping(address => uint256) internal allocationCarry;

    //modifiers
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    modifier onlyFund() {
        if (msg.sender != fund) revert NotFund();
        _;
    }

    //init
    function initialize(
        address fund_,
        address asset_,
        address owner_,
        address strategyRegistry_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (fund_ == address(0) || asset_ == address(0) || owner_ == address(0) || strategyRegistry_ == address(0)) {
            revert ZeroAddress();
        }

        fund = fund_;
        asset = asset_;
        owner = owner_;
        strategyRegistry = strategyRegistry_;

        initialized = true;
    }

    //view
    function totalAssets() external view override onlyInitialized returns (uint256) {
        uint256 total = IERC20(asset).balanceOf(fund);

        uint256 len = _strategies.length;
        for (uint256 i = 0; i < len; i++) {
            total += IStrategy(_strategies[i]).totalAssets();
        }

        return total;
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
            weightsBps[i] = isRemoving[s] ? 0 : strategyWeight[s];
        }
    }

    //write - only fund
    function allocate(uint256 assets_) external override onlyInitialized onlyFund nonReentrant {
        _drainRemovingStrategies();

        if (assets_ == 0) return;

        (uint256 activeCount, uint256 lastActiveIndex) = _activeCountAndLastIndex();
        if (activeCount == 0) return;

        address lastActive = _strategies[lastActiveIndex];

        uint256 remaining = assets_;
        uint256 len = _strategies.length;

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;

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
        _drainRemovingStrategies();

        if (assets_ == 0) return 0;

        uint256 remaining = assets_;
        uint256 len = _strategies.length;

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;
            if (!IStrategy(s).isLiquid()) continue;

            uint256 got = IStrategy(s).withdraw(remaining, fund);
            freed += got;

            if (freed >= assets_) return freed;
            remaining = assets_ - freed;
        }

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;
            if (IStrategy(s).isLiquid()) continue;

            uint256 got = IStrategy(s).withdraw(remaining, fund);
            freed += got;

            if (freed >= assets_) return freed;
            remaining = assets_ - freed;
        }
    }

    function addStrategyViaImplementations(address[] calldata implementations, uint16[] calldata weightsBps)
        external
        override
        onlyInitialized
        onlyOwner
        nonReentrant
        returns (address[] memory newStrategyInstances)
    {
        uint256 len = implementations.length;
        if (len != weightsBps.length) revert LengthMismatch();
        if (len == 0) revert InvalidWeights();

        newStrategyInstances = new address[](len);

        for (uint256 i = 0; i < len; i++) {
            address impl = implementations[i];
            uint16 w = weightsBps[i];

            if (impl == address(0)) revert ZeroAddress();
            if (w == 0 || w > 10_000) revert InvalidBps();

            _validateImplementation(impl);

            if (_implUsed[impl]) revert ImplementationAlreadyUsed(impl);

            address inst = impl.clone();
            IStrategy(inst).initialize(address(this), asset);

            if (_isStrategy[inst]) revert DuplicateStrategy(inst);

            _strategies.push(inst);
            _isStrategy[inst] = true;
            strategyWeight[inst] = w;

            _implUsed[impl] = true;
            strategyImplementationOf[inst] = impl;

            allocationCarry[inst] = 0;

            newStrategyInstances[i] = inst;

            emit StrategyAdded(impl, inst, w);
        }

        _validateWeightsSum();
    }

    function drainRemoving() external onlyInitialized onlyFund nonReentrant {
    _drainRemovingStrategies();
    }   

    //manager owner only
    function addStrategyViaImplementation(address strategyImplementation, uint16 weightBps)
        external
        override
        onlyInitialized
        onlyOwner
        nonReentrant
        returns (address newStrategyInstance)
    {
        if (strategyImplementation == address(0)) revert ZeroAddress();
        if (weightBps == 0 || weightBps > 10_000) revert InvalidBps();

        _validateImplementation(strategyImplementation);

        if (_implUsed[strategyImplementation]) revert ImplementationAlreadyUsed(strategyImplementation);

        _makeRoomForNewWeight(weightBps);

        newStrategyInstance = strategyImplementation.clone();
        IStrategy(newStrategyInstance).initialize(address(this), asset);

        if (_isStrategy[newStrategyInstance]) revert DuplicateStrategy(newStrategyInstance);

        _strategies.push(newStrategyInstance);
        _isStrategy[newStrategyInstance] = true;
        strategyWeight[newStrategyInstance] = weightBps;

        _implUsed[strategyImplementation] = true;
        strategyImplementationOf[newStrategyInstance] = strategyImplementation;

        allocationCarry[newStrategyInstance] = 0;

        _validateWeightsSum();

        emit StrategyAdded(strategyImplementation, newStrategyInstance, weightBps);
    }


    function removeStrategyInstance(address strategyInstance)
        external
        override
        onlyInitialized
        onlyOwner
        nonReentrant
        returns (uint256 freedAssets)
    {
        if (!_isStrategy[strategyInstance]) revert UnknownStrategy(strategyInstance);
        if (isRemoving[strategyInstance]) revert StrategyRemoving(strategyInstance);

        if (_activeStrategyCount() <= 1) revert CannotRemoveLastStrategy();

        uint16 removedW = strategyWeight[strategyInstance];

        isRemoving[strategyInstance] = true;
        removingWeightBps[strategyInstance] = removedW;
        strategyWeight[strategyInstance] = 0;

        emit StrategyRemovingStarted(strategyInstance, removedW);

        freedAssets = IStrategy(strategyInstance).maxPossibleWithdraw(fund);

        _redistributeRemovedWeight(strategyInstance, removedW);

        if (IStrategy(strategyInstance).totalAssets() == 0) {
            _finalizeRemoval(strategyInstance);
        }

        _validateWeightsSum();
    }

    function updateStrategyWeights(address[] calldata strategyInstances, uint16[] calldata weightsBps)
        external
        override
        onlyInitialized
        onlyOwner
        nonReentrant
    {
        uint256 len = strategyInstances.length;
        if (len != weightsBps.length) revert LengthMismatch();
        if (len == 0) revert InvalidWeights();

        for (uint256 i = 0; i < len; i++) {
            address s = strategyInstances[i];
            uint16 w = weightsBps[i];

            if (!_isStrategy[s]) revert UnknownStrategy(s);
            if (w == 0 || w > 10_000) revert InvalidBps();
            if (isRemoving[s]) revert StrategyRemoving(s);

            strategyWeight[s] = w;
        }

        _validateWeightsSum();

        emit WeightsUpdated(strategyInstances, weightsBps);
    }

    //internal
    function _validateImplementation(address impl) internal view {
        IStrategyRegistry sReg = IStrategyRegistry(strategyRegistry);

        if (!sReg.isActive(impl)) revert StrategyNotActive(impl);
        if (!sReg.supportsAsset(impl, asset)) revert StrategyNotSupported(impl, asset);
    }

    function _validateWeightsSum() internal view {
        uint256 len = _strategies.length;
        uint256 sum;

        for (uint256 i = 0; i < len; i++) {
            if (isRemoving[_strategies[i]]) continue;
            sum += strategyWeight[_strategies[i]];
        }

        if (sum != 10_000) revert InvalidWeights();
    }

    function _drainRemovingStrategies() internal {
        uint256 len = _strategies.length;
        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (!isRemoving[s]) continue;

            IStrategy(s).maxPossibleWithdraw(fund);

            if (IStrategy(s).totalAssets() == 0) {
                _finalizeRemoval(s);
                len = _strategies.length;
                if (i > 0) i--;
            }
        }
    }

    function _redistributeRemovedWeight(address removingStrategy, uint16 removedW) internal {
        if (removedW == 0) return;

        uint256 len = _strategies.length;

        uint256 activeSum;
        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (s == removingStrategy) continue;
            if (isRemoving[s]) continue;
            activeSum += strategyWeight[s];
        }

        if (activeSum == 0) revert CannotRedistribute();

        uint256 distributed;
        address lastActive;

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (s == removingStrategy) continue;
            if (isRemoving[s]) continue;

            lastActive = s;

            uint256 addW = (uint256(removedW) * uint256(strategyWeight[s])) / activeSum;
            if (addW > 0) {
                uint256 nw = uint256(strategyWeight[s]) + addW;
                if (nw > 10_000) revert InvalidWeights();
                strategyWeight[s] = uint16(nw);
                distributed += addW;
            }
        }

        uint256 dust = uint256(removedW) - distributed;
        if (dust > 0) {
            uint256 nw2 = uint256(strategyWeight[lastActive]) + dust;
            if (nw2 > 10_000) revert InvalidWeights();
            strategyWeight[lastActive] = uint16(nw2);
        }

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;
            if (strategyWeight[s] == 0) revert ActiveWeightZero(s);
        }
    }

    function _makeRoomForNewWeight(uint16 newW) internal {
        uint256 len = _strategies.length;

        uint256 activeSum;
        uint256 activeCount;

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;
            uint256 w = strategyWeight[s];
            if (w == 0) continue;
            activeSum += w;
            activeCount++;
        }

        if (activeCount == 0) {
            if (newW != 10_000) revert InvalidWeights();
            return;
        }

        if (activeSum != 10_000) revert InvalidWeights();
        if (newW >= 10_000) revert InvalidWeights();

        uint256 toReduce = newW;

        uint256 reduced;
        address lastActive;

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;

            uint256 w = strategyWeight[s];
            if (w == 0) continue;

            lastActive = s;

            uint256 subW = (toReduce * w) / activeSum;
            if (subW > 0) {
                uint256 nw = w - subW;
                if (nw > 10_000) revert InvalidWeights();
                strategyWeight[s] = uint16(nw);
                reduced += subW;
            }
        }

        uint256 dust = toReduce - reduced;
        if (dust > 0) {
            uint256 wLast = strategyWeight[lastActive];
            if (wLast < dust) revert InvalidWeights();
            uint256 nwLast = wLast - dust;
            if (nwLast > 10_000) revert InvalidWeights();
            strategyWeight[lastActive] = uint16(nwLast);
        }

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;
            if (_isStrategy[s] && strategyWeight[s] == 0) revert ActiveWeightZero(s);
        }
    }

    function _activeStrategyCount() internal view returns (uint256 count) {
        uint256 len = _strategies.length;
        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;
            if (strategyWeight[s] == 0) continue;
            count++;
        }
    }

    //remainder allocation
    function _activeCountAndLastIndex() internal view returns (uint256 count, uint256 lastIndex) {
        uint256 len = _strategies.length;
        bool found;
        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;
            if (strategyWeight[s] == 0) continue;
            count++;
            lastIndex = i;
            found = true;
        }
        if (!found) lastIndex = 0;
    }

    function _finalizeRemoval(address strategyInstance) internal {
        uint256 len = _strategies.length;
        for (uint256 i = 0; i < len; i++) {
            if (_strategies[i] == strategyInstance) {
                _strategies[i] = _strategies[len - 1];
                _strategies.pop();
                break;
            }
        }

        _isStrategy[strategyInstance] = false;
        delete isRemoving[strategyInstance];
        delete removingWeightBps[strategyInstance];
        strategyWeight[strategyInstance] = 0;

        delete allocationCarry[strategyInstance];

        address impl = strategyImplementationOf[strategyInstance];
        if (impl != address(0)) {
            _implUsed[impl] = false;
            delete strategyImplementationOf[strategyInstance];
        }

        emit StrategyRemoved(strategyInstance, impl);
    }
}
