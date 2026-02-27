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
error NotFactory();
error NotManagerOwner();
error NotPendingManagerOwner();
error NotRebalanceCaller();
error NotInitialized();
error AlreadyInitialized();
error ZeroAddress();
error InvalidBps();
error InvalidTiltParams();
error InvalidRebalanceParams();
error InvalidRebalanceBand(uint16 bandBps);
error RebalanceBandCooldownActive(uint64 nextAllowedAt);
error LengthMismatch();
error InvalidWeights();
error StrategyNotActive(address implementation);
error StrategyNotSupported(address implementation, address asset);
error DuplicateStrategy(address strategyInstance);
error ImplementationAlreadyUsed(address implementation);
error ActiveWeightZero(address strategyInstance);
error WeightBelowMin(address strategyInstance, uint16 weightBps);
error TiltCooldownActive(uint64 nextAllowedAt);
error TiltLengthMismatch();
error TiltOutOfBounds(int16 tiltBps, uint256 index);
error TiltStepTooLarge(uint16 deltaBps, uint256 index);
error InvalidTiltNet();
error EffectiveWeightOutOfBounds(uint16 effectiveWeightBps, uint256 index);

contract Manager is IManager, ReentrancyGuard {
    using Clones for address;

    uint16 internal constant MIN_WEIGHT_BPS = 100; // 1.00%

    bool public initialized;
    bool public emergencyStopped;

    address public fund;
    address public asset;
    address public factory;
    address public managerOwner;
    address public pendingManagerOwner;

    uint16 public maxTiltBps;
    uint16 public maxStepBps;
    uint64 public tiltCooldown;
    uint64 public lastTiltUpdateAt;

    uint16 public rebalanceBandBps;
    uint16 public minRebalanceBandBps;
    uint16 public maxRebalanceBandBps;
    uint64 public bandUpdateCooldown;
    uint64 public lastBandUpdateAt;

    address public strategyRegistry;
    address public riskEngine;

    address[] internal _strategies;
    uint16[] internal _coreWeightBpsByIndex;
    int16[] internal _tiltBpsByIndex;

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

    modifier onlyManagerOwner() {
        if (msg.sender != managerOwner) revert NotManagerOwner();
        _;
    }

    function minWeightBps() external pure returns (uint16) {
        return MIN_WEIGHT_BPS;
    }

    function initialize(
        address fund_,
        address factory_,
        address managerOwner_,
        address riskEngine_,
        address asset_,
        address strategyRegistry_,
        uint16 maxTiltBps_,
        uint16 maxStepBps_,
        uint64 tiltCooldown_,
        uint16 defaultRebalanceBandBps_,
        uint16 minRebalanceBandBps_,
        uint16 maxRebalanceBandBps_,
        uint64 bandUpdateCooldown_,
        address[] calldata implementations,
        uint16[] calldata weightsBps
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            fund_ == address(0) ||
            factory_ == address(0) ||
            managerOwner_ == address(0) ||
            asset_ == address(0) ||
            strategyRegistry_ == address(0) ||
            riskEngine_ == address(0)
        ) revert ZeroAddress();
        if (msg.sender != factory_) revert NotFactory();

        if (maxTiltBps_ == 0 || maxStepBps_ == 0 || tiltCooldown_ == 0 || maxStepBps_ > maxTiltBps_) {
            revert InvalidTiltParams();
        }

        if (
            minRebalanceBandBps_ == 0 ||
            minRebalanceBandBps_ > defaultRebalanceBandBps_ ||
            defaultRebalanceBandBps_ > maxRebalanceBandBps_ ||
            bandUpdateCooldown_ == 0
        ) revert InvalidRebalanceParams();

        uint256 len = implementations.length;
        if (len == 0) revert InvalidWeights();
        if (len != weightsBps.length) revert LengthMismatch();

        fund = fund_;
        factory = factory_;
        managerOwner = managerOwner_;
        asset = asset_;
        strategyRegistry = strategyRegistry_;
        riskEngine = riskEngine_;
        maxTiltBps = maxTiltBps_;
        maxStepBps = maxStepBps_;
        tiltCooldown = tiltCooldown_;
        rebalanceBandBps = defaultRebalanceBandBps_;
        minRebalanceBandBps = minRebalanceBandBps_;
        maxRebalanceBandBps = maxRebalanceBandBps_;
        bandUpdateCooldown = bandUpdateCooldown_;

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
            _strategyImplementationOf[inst] = impl;
            allocationCarry[inst] = 0;

            _coreWeightBpsByIndex.push(w);
            _tiltBpsByIndex.push(0);
            strategyWeight[inst] = w;

            sum += w;
            emit StrategyAdded(impl, inst, w);
        }

        if (sum != 10_000) revert InvalidWeights();

        _enforceMinWeights();
        _refreshRisk();

        emit TiltParamsSet(maxTiltBps_, maxStepBps_, tiltCooldown_);
        initialized = true;
    }

    function transferManagerOwner(address newOwner) external onlyInitialized onlyManagerOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingManagerOwner = newOwner;
        emit ManagerOwnerTransferStarted(managerOwner, newOwner);
    }

    function acceptManagerOwner() external onlyInitialized {
        address pending = pendingManagerOwner;
        if (msg.sender != pending) revert NotPendingManagerOwner();

        address old = managerOwner;
        managerOwner = pending;
        pendingManagerOwner = address(0);

        emit ManagerOwnerTransferred(old, pending);
    }

    function setRebalanceBandBps(uint16 newBandBps) external onlyInitialized onlyManagerOwner {
        if (newBandBps < minRebalanceBandBps || newBandBps > maxRebalanceBandBps) {
            revert InvalidRebalanceBand(newBandBps);
        }

        uint64 nextAllowedAt = lastBandUpdateAt + bandUpdateCooldown;
        if (lastBandUpdateAt != 0 && block.timestamp < nextAllowedAt) revert RebalanceBandCooldownActive(nextAllowedAt);

        uint16 old = rebalanceBandBps;
        rebalanceBandBps = newBandBps;
        lastBandUpdateAt = uint64(block.timestamp);

        emit RebalanceBandUpdated(old, newBandBps);
    }

    function getCoreWeights() external view override returns (uint16[] memory out) {
        uint256 len = _coreWeightBpsByIndex.length;
        out = new uint16[](len);
        for (uint256 i = 0; i < len; i++) out[i] = _coreWeightBpsByIndex[i];
    }

    function getTiltBps() external view override returns (int16[] memory out) {
        uint256 len = _tiltBpsByIndex.length;
        out = new int16[](len);
        for (uint256 i = 0; i < len; i++) out[i] = _tiltBpsByIndex[i];
    }

    function getEffectiveWeights() external view override returns (uint16[] memory weightsBps) {
        return _effectiveWeights();
    }

    function previewAllocationWeights() external view override returns (uint16[] memory weightsBps) {
        return _effectiveWeights();
    }

    function previewDriftBps() external view override returns (int32[] memory driftBps) {
        uint256 len = _strategies.length;
        driftBps = new int32[](len);

        (uint256[] memory assetsByStrategy, uint256 strategyTotal) = _strategyAssets();
        uint256 totalManaged = strategyTotal + IERC20(asset).balanceOf(fund);
        if (totalManaged == 0) return driftBps;

        for (uint256 i = 0; i < len; i++) {
            uint256 currentWeightBps = (assetsByStrategy[i] * 10_000) / totalManaged;
            int256 diff = int256(currentWeightBps) - int256(uint256(strategyWeight[_strategies[i]]));
            driftBps[i] = int32(diff);
        }
    }

    function setTilt(int16[] calldata newTiltBps, bytes32 rationaleHash) external onlyInitialized onlyManagerOwner {
        uint256 len = _strategies.length;
        if (newTiltBps.length != len) revert TiltLengthMismatch();

        uint64 nextAllowedAt = lastTiltUpdateAt + tiltCooldown;
        if (lastTiltUpdateAt != 0 && block.timestamp < nextAllowedAt) revert TiltCooldownActive(nextAllowedAt);

        int256 net;
        for (uint256 i = 0; i < len; i++) {
            int16 proposed = newTiltBps[i];
            int16 old = _tiltBpsByIndex[i];

            if (!_withinTiltBounds(proposed)) revert TiltOutOfBounds(proposed, i);

            uint16 delta = _absDiff(proposed, old);
            if (delta > maxStepBps) revert TiltStepTooLarge(delta, i);

            uint16 eff = _effectiveWeightFor(i, proposed);
            if (eff > 10_000) revert EffectiveWeightOutOfBounds(eff, i);

            net += int256(proposed);
        }
        if (net != 0) revert InvalidTiltNet();

        for (uint256 i = 0; i < len; i++) {
            _tiltBpsByIndex[i] = newTiltBps[i];
        }

        _applyEffectiveWeights();

        lastTiltUpdateAt = uint64(block.timestamp);
        emit TiltUpdated(address(this), newTiltBps, uint64(block.timestamp), rationaleHash);

        _refreshRisk();
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
        weightsBps = _effectiveWeights();

        for (uint256 i = 0; i < len; i++) {
            strategyInstances[i] = _strategies[i];
        }
    }

    function allocate(uint256 assets_) external override onlyInitialized onlyFund nonReentrant {
        if (emergencyStopped || assets_ == 0) return;

        uint256 len = _strategies.length;
        uint256 remaining = assets_;

        (uint256[] memory assetsByStrategy, uint256 strategyTotal) = _strategyAssets();
        uint256 totalManaged = strategyTotal + IERC20(asset).balanceOf(fund);
        uint256[] memory targets = _targetAssets(totalManaged);
        uint256[] memory bandAssets = _bandAssets(targets);

        // prioritizes underweight strategies outside the drift band
        while (remaining > 0) {
            uint256 idx = type(uint256).max;
            uint256 bestDeficit;

            for (uint256 i = 0; i < len; i++) {
                if (strategyWeight[_strategies[i]] == 0) continue;

                uint256 target = targets[i];
                uint256 current = assetsByStrategy[i];
                uint256 band = bandAssets[i];
                if (current + band >= target) continue;

                uint256 deficit = target - current;
                if (deficit > bestDeficit) {
                    bestDeficit = deficit;
                    idx = i;
                }
            }

            if (idx == type(uint256).max || bestDeficit == 0) break;

            uint256 toDeposit = bestDeficit < remaining ? bestDeficit : remaining;
            uint256 deposited = IStrategy(_strategies[idx]).deposit(toDeposit);
            if (deposited == 0) break;

            remaining -= deposited;
            assetsByStrategy[idx] += deposited;
        }

        if (remaining == 0) return;

        (uint256 activeCount, uint256 lastActiveIndex) = _activeCountAndLastIndex();
        if (activeCount == 0) return;

        address lastActive = _strategies[lastActiveIndex];

        for (uint256 i = 0; i < len; i++) {
            address s = _strategies[i];
            uint16 w = strategyWeight[s];
            if (w == 0) continue;

            uint256 raw = remaining * uint256(w) + allocationCarry[s];
            uint256 amt = raw / 10_000;
            allocationCarry[s] = raw % 10_000;

            if (s == lastActive) continue;
            if (amt == 0) continue;

            uint256 deposited = IStrategy(s).deposit(amt);
            if (deposited > remaining) deposited = remaining;
            remaining -= deposited;
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

        (uint256[] memory assetsByStrategy, uint256 strategyTotal) = _strategyAssets();
        uint256 totalManaged = strategyTotal + IERC20(asset).balanceOf(fund);
        uint256[] memory targets = _targetAssets(totalManaged);
        uint256[] memory bandAssets = _bandAssets(targets);
        uint256[] memory excesses = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 threshold = targets[i] + bandAssets[i];
            if (assetsByStrategy[i] > threshold) {
                excesses[i] = assetsByStrategy[i] - threshold;
            }
        }

        IStrategyRegistry sReg = IStrategyRegistry(strategyRegistry);

        // first pass: liquid overweight strategies
        for (uint256 i = 0; i < len && remaining > 0; i++) {
            if (excesses[i] == 0) continue;
            address s = _strategies[i];
            address impl = _strategyImplementationOf[s];
            if (!sReg.isLiquid(impl)) continue;

            uint256 ask = excesses[i] < remaining ? excesses[i] : remaining;
            uint256 got = IStrategy(s).withdraw(ask, fund);
            freed += got;
            if (got >= remaining) return freed;
            remaining -= got;
        }

        // second pass: non-liquid overweight strategies
        for (uint256 i = 0; i < len && remaining > 0; i++) {
            if (excesses[i] == 0) continue;
            address s = _strategies[i];
            address impl = _strategyImplementationOf[s];
            if (sReg.isLiquid(impl)) continue;

            uint256 ask = excesses[i] < remaining ? excesses[i] : remaining;
            uint256 got = IStrategy(s).withdraw(ask, fund);
            freed += got;
            if (got >= remaining) return freed;
            remaining -= got;
        }

        // fallback: current behavior (all liquid then all non-liquid).
        for (uint256 i = 0; i < len && remaining > 0; i++) {
            address s = _strategies[i];
            address impl = _strategyImplementationOf[s];
            if (!sReg.isLiquid(impl)) continue;

            uint256 got = IStrategy(s).withdraw(remaining, fund);
            freed += got;
            if (got >= remaining) return freed;
            remaining -= got;
        }

        for (uint256 i = 0; i < len && remaining > 0; i++) {
            address s = _strategies[i];
            address impl = _strategyImplementationOf[s];
            if (sReg.isLiquid(impl)) continue;

            uint256 got = IStrategy(s).withdraw(remaining, fund);
            freed += got;
            if (got >= remaining) return freed;
            remaining -= got;
        }
    }

    function rebalance(uint256 maxAssetsToMove, uint8 maxLegs)
        external
        override
        onlyInitialized
        onlyManagerOwner
        nonReentrant
        returns (uint256 assetsMoved)
    {
        if (maxAssetsToMove == 0 || maxLegs == 0) revert InvalidRebalanceParams();
        if (emergencyStopped) return 0;

        uint256 len = _strategies.length;
        (uint256[] memory assetsByStrategy, uint256 strategyTotal) = _strategyAssets();
        uint256 totalManaged = strategyTotal + IERC20(asset).balanceOf(fund);

        if (totalManaged == 0) return 0;

        uint256[] memory targets = _targetAssets(totalManaged);
        uint256[] memory bandAssets = _bandAssets(targets);
        uint256[] memory excesses = new uint256[](len);
        uint256[] memory deficits = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 current = assetsByStrategy[i];
            uint256 target = targets[i];
            uint256 band = bandAssets[i];

            if (current > target + band) {
                excesses[i] = current - (target + band);
            } else if (current + band < target) {
                deficits[i] = target - (current + band);
            }
        }

        uint8 legs;
        uint256 remainingBudget = maxAssetsToMove;
        IStrategyRegistry sReg = IStrategyRegistry(strategyRegistry);

        while (remainingBudget > 0 && legs < maxLegs) {
            uint256 donor = _maxIndex(excesses, true, sReg);
            if (donor == type(uint256).max) break;

            uint256 receiver = _maxIndex(deficits, false, sReg);
            if (receiver == type(uint256).max) break;

            uint256 toMove = excesses[donor];
            if (deficits[receiver] < toMove) toMove = deficits[receiver];
            if (remainingBudget < toMove) toMove = remainingBudget;
            if (toMove == 0) break;

            uint256 got = IStrategy(_strategies[donor]).withdraw(toMove, fund);
            if (got == 0) {
                excesses[donor] = 0;
                continue;
            }

            uint256 deposited = IStrategy(_strategies[receiver]).deposit(got);

            if (got >= excesses[donor]) excesses[donor] = 0;
            else excesses[donor] -= got;

            if (deposited >= deficits[receiver]) deficits[receiver] = 0;
            else deficits[receiver] -= deposited;

            if (deposited == 0) continue;

            if (deposited > remainingBudget) deposited = remainingBudget;
            remainingBudget -= deposited;
            assetsMoved += deposited;
            legs++;
        }

        if (assetsMoved > 0) {
            _refreshRisk();
        }

        emit RebalanceExecuted(msg.sender, assetsMoved, legs);
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

    function _effectiveWeights() internal view returns (uint16[] memory weightsBps) {
        uint256 len = _strategies.length;
        weightsBps = new uint16[](len);
        for (uint256 i = 0; i < len; i++) {
            weightsBps[i] = _effectiveWeightFor(i, _tiltBpsByIndex[i]);
        }
    }

    function _applyEffectiveWeights() internal {
        uint256 len = _strategies.length;
        uint256 sum;
        for (uint256 i = 0; i < len; i++) {
            uint16 eff = _effectiveWeightFor(i, _tiltBpsByIndex[i]);
            if (eff > 10_000) revert EffectiveWeightOutOfBounds(eff, i);

            strategyWeight[_strategies[i]] = eff;
            sum += eff;
        }

        if (sum != 10_000) revert InvalidWeights();
    }

    function _effectiveWeightFor(uint256 index, int16 tiltValue) internal view returns (uint16 eff) {
        uint16 core = _coreWeightBpsByIndex[index];

        if (tiltValue >= 0) {
            uint256 v = uint256(core) + uint256(uint16(tiltValue));
            if (v > type(uint16).max) revert EffectiveWeightOutOfBounds(type(uint16).max, index);
            eff = uint16(v);
        } else {
            uint16 magnitude = uint16(uint16(-tiltValue));
            if (magnitude > core) revert EffectiveWeightOutOfBounds(0, index);
            eff = core - magnitude;
        }

        return eff;
    }

    function _withinTiltBounds(int16 v) internal view returns (bool) {
        int256 lower = -int256(uint256(maxTiltBps));
        int256 upper = int256(uint256(maxTiltBps));
        int256 x = int256(v);
        return x >= lower && x <= upper;
    }

    function _absDiff(int16 a, int16 b) internal pure returns (uint16) {
        int256 d = int256(a) - int256(b);
        if (d < 0) d = -d;
        return uint16(uint256(d));
    }

    function _strategyAssets() internal view returns (uint256[] memory assetsByStrategy, uint256 total) {
        uint256 len = _strategies.length;
        assetsByStrategy = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 a = IStrategy(_strategies[i]).totalAssets();
            assetsByStrategy[i] = a;
            total += a;
        }
    }

    function _targetAssets(uint256 totalManaged) internal view returns (uint256[] memory targets) {
        uint256 len = _strategies.length;
        targets = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            targets[i] = (totalManaged * uint256(strategyWeight[_strategies[i]])) / 10_000;
        }
    }

    function _bandAssets(uint256[] memory targets) internal view returns (uint256[] memory bands) {
        uint256 len = targets.length;
        bands = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            bands[i] = (targets[i] * uint256(rebalanceBandBps)) / 10_000;
        }
    }

    function _maxIndex(uint256[] memory arr, bool preferLiquid, IStrategyRegistry sReg) internal view returns (uint256 idx) {
        uint256 len = arr.length;
        idx = type(uint256).max;
        uint256 best;

        if (preferLiquid) {
            for (uint256 i = 0; i < len; i++) {
                if (arr[i] == 0) continue;
                address impl = _strategyImplementationOf[_strategies[i]];
                if (!sReg.isLiquid(impl)) continue;
                if (arr[i] > best) {
                    best = arr[i];
                    idx = i;
                }
            }
            if (idx != type(uint256).max) return idx;
        }

        for (uint256 i = 0; i < len; i++) {
            if (arr[i] > best) {
                best = arr[i];
                idx = i;
            }
        }
    }

    function _refreshRisk() internal {
        address re = riskEngine;
        if (re == address(0)) return;

        (uint8 tier, uint32 score) = IRiskEngine(re).refreshRisk(address(this));
        IFund(fund).setRisk(tier, score);
    }
}
