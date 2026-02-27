// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRiskEngine} from "./interfaces/IRiskEngine.sol";
import {IStrategyRegistry} from "./interfaces/registry/IStrategyRegistry.sol";
import {IManager} from "./interfaces/IManager.sol";

// errors
error NotGovernance();
error ZeroAddress();
error InvalidThresholds();
error InvalidRiskParams();
error NotApprovedStrategy(address implementation);
error UpdateTooSoon();
error ThresholdsUpdateNotQueued(bytes32 id);
error ThresholdsUpdateNotReady(bytes32 id, uint64 eta);

contract RiskEngine is IRiskEngine {
    
    uint32 internal constant DEFAULT_MAX_SCORE_DELTA = 50;
    uint64 internal constant DEFAULT_MIN_UPDATE_DELAY = 1 days;
    uint64 internal constant DEFAULT_THRESHOLDS_TIMELOCK = 2 days;

    address public governance;
    address public strategyRegistry;
    uint32[] internal _tierThresholds;
    string public metadataURI;
    uint32 public maxScoreDelta;
    uint64 public minUpdateDelay;
    uint64 public thresholdsTimelock;

    mapping(address => uint32) internal _lastScore;
    mapping(address => uint8) internal _lastTier;
    mapping(address => uint64) internal _lastUpdatedAt;
    mapping(bytes32 => uint64) public queuedThresholdEta;

    constructor(
        address strategyRegistry_,
        address governance_,
        uint32[] memory tierThresholds_,
        string memory metadataURI_
    ) {
        if (strategyRegistry_ == address(0) || governance_ == address(0)) revert ZeroAddress();
        strategyRegistry = strategyRegistry_;
        governance = governance_;

        metadataURI = metadataURI_;
        emit MetadataURISet(metadataURI_);

        _setTierThresholds(tierThresholds_);
        _setRiskParams(DEFAULT_MAX_SCORE_DELTA, DEFAULT_MIN_UPDATE_DELAY, DEFAULT_THRESHOLDS_TIMELOCK);
    }

    //modifier
    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    //views
    function tierThresholds() external view override returns (uint32[] memory) {
        return _tierThresholds;
    }

    function lastPublishedRisk(address manager)
        external
        view
        override
        returns (uint8 riskTier, uint32 riskScore, uint64 updatedAt)
    {
        return (_lastTier[manager], _lastScore[manager], _lastUpdatedAt[manager]);
    }

    //governance
    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddress();
        address old = governance;
        governance = newGovernance;
        emit GovernanceUpdated(old, newGovernance);
    }

    function setStrategyRegistry(address newReg) external onlyGovernance {
        if (newReg == address(0)) revert ZeroAddress();
        address old = strategyRegistry;
        strategyRegistry = newReg;
        emit StrategyRegistryUpdated(old, newReg);
    }

    function queueTierThresholds(uint32[] calldata newThresholds) external override onlyGovernance {
        _validateThresholds(newThresholds);
        bytes32 id = keccak256(abi.encode(newThresholds));
        uint64 eta = uint64(block.timestamp) + thresholdsTimelock;
        queuedThresholdEta[id] = eta;
        emit ThresholdsUpdateQueued(id, eta);
    }

    function executeTierThresholds(uint32[] calldata newThresholds) external override onlyGovernance {
        bytes32 id = keccak256(abi.encode(newThresholds));
        uint64 eta = queuedThresholdEta[id];
        if (eta == 0) revert ThresholdsUpdateNotQueued(id);
        if (block.timestamp < eta) revert ThresholdsUpdateNotReady(id, eta);

        delete queuedThresholdEta[id];
        _setTierThresholds(newThresholds);
        emit ThresholdsUpdateExecuted(id);
    }

    function setRiskParams(uint32 maxScoreDelta_, uint64 minUpdateDelay_, uint64 thresholdsTimelock_)
        external
        override
        onlyGovernance
    {
        _setRiskParams(maxScoreDelta_, minUpdateDelay_, thresholdsTimelock_);
    }

    function setMetadataURI(string calldata newURI) external onlyGovernance {
        metadataURI = newURI;
        emit MetadataURISet(newURI);
    }

    function computeRiskRaw(address manager)
        external
        view
        override
        returns (uint8 riskTier, uint32 riskScore)
    {
        return _computeRiskRaw(manager);
    }

    function refreshRisk(address manager) external override returns (uint8 riskTier, uint32 riskScore) {
        if (manager == address(0)) revert ZeroAddress();

        uint64 lastAt = _lastUpdatedAt[manager];
        if (lastAt != 0 && block.timestamp < lastAt + minUpdateDelay) revert UpdateTooSoon();

        (, uint32 rawScore) = _computeRiskRaw(manager);
        uint32 boundedScore = rawScore;
        uint32 prevScore = _lastScore[manager];

        if (lastAt != 0) {
            unchecked {
                uint32 up = prevScore + maxScoreDelta;
                if (boundedScore > up) boundedScore = up;
            }

            uint32 down = prevScore > maxScoreDelta ? prevScore - maxScoreDelta : 0;
            if (boundedScore < down) boundedScore = down;
        }

        uint8 boundedTier = _tierForScore(boundedScore);

        _lastScore[manager] = boundedScore;
        _lastTier[manager] = boundedTier;
        _lastUpdatedAt[manager] = uint64(block.timestamp);

        emit RiskPublished(manager, rawScore, boundedScore, boundedTier);
        return (boundedTier, boundedScore);
    }

    function _computeRiskRaw(address manager) internal view returns (uint8 riskTier, uint32 riskScore) {
        if (manager == address(0)) revert ZeroAddress();

        IManager m = IManager(manager);
        (address[] memory instances, uint16[] memory weightsBps) = m.getAllocation();

        uint256 len = instances.length;
        if (len == 0) return (0, 0);

        IStrategyRegistry sReg = IStrategyRegistry(strategyRegistry);

        uint256 sumW;
        uint256 weighted;

        for (uint256 i = 0; i < len; i++) {
            uint16 w = weightsBps[i];
            if (w == 0) continue;

            address impl = m.strategyImplementationOf(instances[i]);

            if (impl == address(0)) revert ZeroAddress();

            if (!sReg.isApproved(impl)) revert NotApprovedStrategy(impl);

            sumW += w;

            uint32 rs = sReg.riskScore(impl);
            weighted += uint256(rs) * uint256(w);
        }

        if (sumW == 0) return (0, 0);

        uint256 avg = weighted / sumW;
        if (avg > type(uint32).max) avg = type(uint32).max;

        riskScore = uint32(avg);
        riskTier = _tierForScore(riskScore);
    }

    //internal
    function _tierForScore(uint32 score) internal view returns (uint8 t) {
        uint256 n = _tierThresholds.length;
        for (uint256 i = 0; i < n; i++) {
            if (score >= _tierThresholds[i]) t++;
            else break;
        }
        return t;
    }

    function _setTierThresholds(uint32[] memory arr) internal {
        _validateThresholds(arr);

        delete _tierThresholds;
        for (uint256 i = 0; i < arr.length; i++) {
            _tierThresholds.push(arr[i]);
        }

        emit TierThresholdsUpdated(_tierThresholds);
    }

    function _validateThresholds(uint32[] memory arr) internal pure {
        for (uint256 i = 1; i < arr.length; i++) {
            if (arr[i] <= arr[i - 1]) revert InvalidThresholds();
        }
    }

    function _setRiskParams(uint32 maxScoreDelta_, uint64 minUpdateDelay_, uint64 thresholdsTimelock_) internal {
        if (maxScoreDelta_ == 0 || minUpdateDelay_ == 0 || thresholdsTimelock_ == 0) revert InvalidRiskParams();

        maxScoreDelta = maxScoreDelta_;
        minUpdateDelay = minUpdateDelay_;
        thresholdsTimelock = thresholdsTimelock_;

        emit RiskParamsUpdated(maxScoreDelta_, minUpdateDelay_, thresholdsTimelock_);
    }
}
