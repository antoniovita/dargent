// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRiskEngine} from "./interfaces/IRiskEngine.sol";
import {IStrategyRegistry} from "./interfaces/registry/IStrategyRegistry.sol";
import {IManager} from "./interfaces/IManager.sol";

// errors
error NotGovernance();
error ZeroAddress();
error InvalidThresholds();
error NotApprovedStrategy(address implementation);

contract RiskEngine is IRiskEngine {
    address public governance;
    address public strategyRegistry;
    uint32[] internal _tierThresholds;
    string public metadataURI;


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
    }

    //modifier
    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    //views
    function tierThresholds() external view returns (uint32[] memory) {
        return _tierThresholds;
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

    function setTierThresholds(uint32[] calldata newThresholds) external onlyGovernance {
        _setTierThresholds(newThresholds);
    }

    function setMetadataURI(string calldata newURI) external onlyGovernance {
        metadataURI = newURI;
        emit MetadataURISet(newURI);
    }

    function computeRisk(address manager)
        external
        view
        override
        returns (uint8 riskTier, uint32 riskScore)
    {
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
        for (uint256 i = 1; i < arr.length; i++) {
            if (arr[i] <= arr[i - 1]) revert InvalidThresholds();
        }

        delete _tierThresholds;
        for (uint256 i = 0; i < arr.length; i++) {
            _tierThresholds.push(arr[i]);
        }

        emit TierThresholdsUpdated(_tierThresholds);
    }
}
