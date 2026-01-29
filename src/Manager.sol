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

//errors
error NotOwner();
error NotFund();
error NotInitialized();
error AlreadyInitialized();
error ZeroAddress();
error InvalidBps();
error LengthMismatch();
error InvalidWeights();
error StrategyNotActive(address implementation);
error StrategyNotSupported(address implementation, address asset);
error UnknownStrategy(address strategyInstance);
error DuplicateStrategy(address strategyInstance);
error ImplementationAlreadyUsed(address implementation);
error StrategyRemoving(address strategyInstance);
error CannotRedistribute();
error CannotRemoveLastStrategy();
error ActiveWeightZero(address strategyInstance);
error WeightBelowMin(address strategyInstance, uint16 weightBps);
error PendingChangeExists();
error NoPendingChange();
error PendingNotReady(uint256 readyAt);
error PendingExpired(uint256 expiredAt);
error DeltaTooLarge(address strategyInstance, uint16 currentBps, uint16 newBps, uint16 maxDeltaBps);

contract Manager is IManager, ReentrancyGuard {
    using Clones for address;

    //constants
    uint16 internal constant MIN_WEIGHT_BPS = 100; // 1.00%
    uint48 internal constant CHANGE_DELAY = 24 hours;
    uint48 internal constant EPOCH = 24 hours;
    uint16 internal constant MAX_DELTA_BPS_PER_EPOCH = 500; // 5.00%

    bool public initialized;
    address public fund;
    address public asset;
    address public strategyRegistry;
    address public owner;
    address public riskEngine;
    address[] internal _strategies;

    mapping(address => uint16) public strategyWeight;
    mapping(address => bool) internal _isStrategy;
    mapping(address => bool) internal _implUsed;
    mapping(address => address) public _strategyImplementationOf;
    mapping(address => bool) public isRemoving;
    mapping(address => uint16) public removingWeightBps;
    mapping(address => uint256) internal allocationCarry;
    mapping(uint256 => bool) internal _epochExecuted;

    function minWeightBps() external pure returns (uint16) { return MIN_WEIGHT_BPS; }
    function changeDelay() external pure returns (uint48) { return CHANGE_DELAY; }
    function epochLength() external pure returns (uint48) { return EPOCH; }
    function maxDeltaBpsPerEpoch() external pure returns (uint16) { return MAX_DELTA_BPS_PER_EPOCH; }

    struct PendingWeights {
        uint48 eta;
        uint48 expiresAt;
        address[] strategies;
        uint16[] weights;
        bool exists;
    }

    struct PendingAdd {
        uint48 eta;
        uint48 expiresAt;
        address implementation;
        uint16 weightBps;
        bool exists;
    }

    PendingWeights internal _pendingWeights;
    PendingAdd internal _pendingAdd;


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
        address riskEngine_,
        address asset_,
        address owner_,
        address strategyRegistry_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            fund_ == address(0) ||
            asset_ == address(0) ||
            owner_ == address(0) ||
            strategyRegistry_ == address(0) ||
            riskEngine_ == address(0)
        ) {
            revert ZeroAddress();
        }

        fund = fund_;
        asset = asset_;
        owner = owner_;
        strategyRegistry = strategyRegistry_;
        riskEngine = riskEngine_;

        initialized = true;
    }

    function setRiskEngine(address newRiskEngine) external override onlyInitialized onlyFund {
        if (newRiskEngine == address(0)) revert ZeroAddress();
        riskEngine = newRiskEngine;
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
            weightsBps[i] = isRemoving[s] ? 0 : strategyWeight[s];
        }
    }

    function pendingWeights()
        external
        view
        returns (bool exists, uint256 eta, uint256 expiresAt, address[] memory strategies, uint16[] memory weights)
    {
        PendingWeights storage p = _pendingWeights;
        return (p.exists, p.eta, p.expiresAt, p.strategies, p.weights);
    }

    function pendingAddStrategy()
        external
        view
        returns (bool exists, uint256 eta, uint256 expiresAt, address implementation, uint16 weightBps)
    {
        PendingAdd storage p = _pendingAdd;
        return (p.exists, p.eta, p.expiresAt, p.implementation, p.weightBps);
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

        IStrategyRegistry sReg = IStrategyRegistry(strategyRegistry);

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;
            address impl = _strategyImplementationOf[s];
            if (!sReg.isLiquid(impl)) continue;

            uint256 got = IStrategy(s).withdraw(remaining, fund);
            freed += got;

            if (freed >= assets_) return freed;
            remaining = assets_ - freed;
        }

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;
            address impl = _strategyImplementationOf[s];
            if (sReg.isLiquid(impl)) continue;

            uint256 got = IStrategy(s).withdraw(remaining, fund);
            freed += got;

            if (freed >= assets_) return freed;
            remaining = assets_ - freed;
        }
    }

    function drainRemoving() external override onlyInitialized onlyFund nonReentrant {
        _drainRemovingStrategies();
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
            if (w < MIN_WEIGHT_BPS || w > 10_000) revert InvalidBps();

            _validateImplementation(impl);
            if (_implUsed[impl]) revert ImplementationAlreadyUsed(impl);

            address inst = impl.clone();
            IStrategy(inst).initialize(address(this), asset);

            if (_isStrategy[inst]) revert DuplicateStrategy(inst);

            _strategies.push(inst);
            _isStrategy[inst] = true;
            strategyWeight[inst] = w;
            _implUsed[impl] = true;
            _strategyImplementationOf[inst] = impl;
            allocationCarry[inst] = 0;

            newStrategyInstances[i] = inst;
            emit StrategyAdded(impl, inst, w);
        }

        _validateWeightsSum();
        _enforceMinWeights();
        _refreshRisk();
    }

    function announceAddStrategyViaImplementation(address strategyImplementation, uint16 weightBps)
        external
        override
        onlyInitialized
        onlyOwner
        nonReentrant
    {
        if (_pendingAdd.exists) revert PendingChangeExists();

        if (strategyImplementation == address(0)) revert ZeroAddress();
        if (weightBps < MIN_WEIGHT_BPS || weightBps > 10_000) revert InvalidBps();

        _validateImplementation(strategyImplementation);
        if (_implUsed[strategyImplementation]) revert ImplementationAlreadyUsed(strategyImplementation);

        uint48 eta = uint48(block.timestamp + CHANGE_DELAY);
        uint48 expiresAt = uint48(block.timestamp + CHANGE_DELAY + 3 days);

        _pendingAdd = PendingAdd({
            eta: eta,
            expiresAt: expiresAt,
            implementation: strategyImplementation,
            weightBps: weightBps,
            exists: true
        });

        emit StrategyAddAnnounced(strategyImplementation, weightBps, eta, expiresAt);
    }

    function executeAddStrategyViaImplementation()
        external
        override
        onlyInitialized
        onlyOwner
        nonReentrant
        returns (address newStrategyInstance)
    {
        PendingAdd storage p = _pendingAdd;
        if (!p.exists) revert NoPendingChange();
        if (block.timestamp < p.eta) revert PendingNotReady(p.eta);
        if (block.timestamp > p.expiresAt) revert PendingExpired(p.expiresAt);

        address impl = p.implementation;
        uint16 w = p.weightBps;

        delete _pendingAdd;

        _validateImplementation(impl);
        if (_implUsed[impl]) revert ImplementationAlreadyUsed(impl);

        _makeRoomForNewWeight(w);

        newStrategyInstance = impl.clone();
        IStrategy(newStrategyInstance).initialize(address(this), asset);

        if (_isStrategy[newStrategyInstance]) revert DuplicateStrategy(newStrategyInstance);

        _strategies.push(newStrategyInstance);
        _isStrategy[newStrategyInstance] = true;
        strategyWeight[newStrategyInstance] = w;

        _implUsed[impl] = true;
        _strategyImplementationOf[newStrategyInstance] = impl;

        allocationCarry[newStrategyInstance] = 0;

        _validateWeightsSum();
        _enforceMinWeights();
        _refreshRisk();

        emit StrategyAdded(impl, newStrategyInstance, w);
        emit StrategyAddExecuted(impl, newStrategyInstance, w);
    }

    function announceStrategyWeights(address[] calldata strategyInstances, uint16[] calldata weightsBps)
        external
        override
        onlyInitialized
        onlyOwner
        nonReentrant
    {
        if (_pendingWeights.exists) revert PendingChangeExists();

        uint256 len = strategyInstances.length;
        if (len != weightsBps.length) revert LengthMismatch();
        if (len == 0) revert InvalidWeights();

        uint256 epoch = _currentEpoch();
        if (_epochExecuted[epoch]) revert PendingChangeExists();

        _validateWeightsProposal(strategyInstances, weightsBps);

        _pendingWeights.strategies = new address[](len);
        _pendingWeights.weights = new uint16[](len);
        for (uint256 i = 0; i < len; i++) {
            _pendingWeights.strategies[i] = strategyInstances[i];
            _pendingWeights.weights[i] = weightsBps[i];
        }

        uint48 eta = uint48(block.timestamp + CHANGE_DELAY);
        uint48 expiresAt = uint48(block.timestamp + CHANGE_DELAY + 3 days);

        _pendingWeights.eta = eta;
        _pendingWeights.expiresAt = expiresAt;
        _pendingWeights.exists = true;

        emit WeightsChangeAnnounced(epoch, eta, expiresAt);
    }

    function executeStrategyWeights() external override onlyInitialized onlyOwner nonReentrant {
        PendingWeights storage p = _pendingWeights;
        if (!p.exists) revert NoPendingChange();
        if (block.timestamp < p.eta) revert PendingNotReady(p.eta);
        if (block.timestamp > p.expiresAt) revert PendingExpired(p.expiresAt);

        uint256 epoch = _currentEpoch();
        _epochExecuted[epoch] = true;

        uint256 len = p.strategies.length;
        address[] memory ss = new address[](len);
        uint16[] memory ws = new uint16[](len);

        for (uint256 i = 0; i < len; i++) {
            address s = p.strategies[i];
            uint16 w = p.weights[i];

            if (!_isStrategy[s]) revert UnknownStrategy(s);
            if (isRemoving[s]) revert StrategyRemoving(s);
            if (w < MIN_WEIGHT_BPS || w > 10_000) revert InvalidBps();

            strategyWeight[s] = w;

            ss[i] = s;
            ws[i] = w;
        }

        _validateWeightsSum();
        _enforceMinWeights();
        _refreshRisk();

        delete _pendingWeights;

        emit WeightsChangeExecuted(epoch);
        emit WeightsUpdated(ss, ws);
    }

    function cancelPendingWeights() external override onlyInitialized onlyOwner nonReentrant {
        if (!_pendingWeights.exists) revert NoPendingChange();
        delete _pendingWeights;
    }

    function cancelPendingAddStrategy() external override onlyInitialized onlyOwner nonReentrant {
        if (!_pendingAdd.exists) revert NoPendingChange();
        delete _pendingAdd;
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
        _enforceMinWeights();
        _refreshRisk();
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

    function _enforceMinWeights() internal view {
        uint256 len = _strategies.length;
        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            if (isRemoving[s]) continue;

            uint16 w = strategyWeight[s];
            if (w == 0) revert ActiveWeightZero(s);
            if (w < MIN_WEIGHT_BPS) revert WeightBelowMin(s, w);
        }
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

        _enforceMinWeights();
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

        _enforceMinWeights();
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

    function _currentEpoch() internal view returns (uint256) {
        return block.timestamp / EPOCH;
    }

    function _validateWeightsProposal(address[] calldata strategyInstances, uint16[] calldata weightsBps) internal view {
        uint256 len = strategyInstances.length;
        uint256 sum;

        for (uint256 i = 0; i < len; i++) {
            address s = strategyInstances[i];
            uint16 nw = weightsBps[i];

            if (!_isStrategy[s]) revert UnknownStrategy(s);
            if (isRemoving[s]) revert StrategyRemoving(s);

            if (nw < MIN_WEIGHT_BPS || nw > 10_000) revert InvalidBps();

            uint16 cw = strategyWeight[s];
            uint16 diff = cw > nw ? (cw - nw) : (nw - cw);
            if (diff > MAX_DELTA_BPS_PER_EPOCH) revert DeltaTooLarge(s, cw, nw, MAX_DELTA_BPS_PER_EPOCH);

            sum += nw;
        }

        if (sum != 10_000) revert InvalidWeights();
    }

    function _refreshRisk() internal {
        address re = riskEngine;
        if (re == address(0)) return;

        (uint8 tier, uint32 score) = IRiskEngine(re).computeRisk(address(this));
        IFund(fund).setRisk(tier, score);
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

        address impl = _strategyImplementationOf[strategyInstance];
        if (impl != address(0)) {
            _implUsed[impl] = false;
            delete _strategyImplementationOf[strategyInstance];
        }

        emit StrategyRemoved(strategyInstance, impl);
    }
}
