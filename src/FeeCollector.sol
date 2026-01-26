// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {IFund} from "./interfaces/IFund.sol";

//errors
error NotGovernance();
error ZeroAddress();
error InvalidBps();
error FundNotInitialized();

contract FeeCollector is IFeeCollector, ReentrancyGuard {

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    address public governance;
    ProtocolFeeConfig internal _protocolFeeConfig;
    mapping(address => FundFeeState) internal _fundFeeState;

    constructor(
        address governance_,
        address protocolFeeRecipient_,
        uint16 protocolMgmtTakeBps_,
        uint16 protocolPerfTakeBps_
    ) {
        if (governance_ == address(0) || protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        if (protocolMgmtTakeBps_ > 10_000 || protocolPerfTakeBps_ > 10_000) revert InvalidBps();

        governance = governance_;
        _protocolFeeConfig = ProtocolFeeConfig({
            protocolFeeRecipient: protocolFeeRecipient_,
            protocolMgmtTakeBps: protocolMgmtTakeBps_,
            protocolPerfTakeBps: protocolPerfTakeBps_
        });
    }

    //modifier
    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    //view
    function protocolFeeConfig() external view override returns (ProtocolFeeConfig memory) {
        return _protocolFeeConfig;
    }

    function fundFeeState(address fund) external view override returns (FundFeeState memory) {
        return _fundFeeState[fund];
    }

    function previewAccrue(address fund)
        external
        view
        override
        returns (uint256 totalFeeShares, uint256 protocolFeeShares, uint256 managerFeeShares)
    {
        return _previewAccrue(fund, block.timestamp);
    }

    //write
    function accrue(address fund)
        external
        override
        nonReentrant
        returns (uint256 totalFeeShares, uint256 protocolFeeShares, uint256 managerFeeShares)
    {
        uint256 nowTs = block.timestamp;

        (totalFeeShares, protocolFeeShares, managerFeeShares) = _previewAccrue(fund, nowTs);

        FundFeeState memory st = _fundFeeState[fund];
        uint64 last = st.lastAccrual;

        if (last == 0) {
            uint256 pps = _pricePerShareWad(fund);
            _fundFeeState[fund] = FundFeeState({
                lastAccrual: uint64(nowTs),
                highWaterMark: uint192(pps)
            });
            return (0, 0, 0);
        }

        if (totalFeeShares > 0) {
            IFund.FeeConfig memory fc = IFund(fund).feeConfig();
            address managerRecipient = fc.managerFeeRecipient;

            ProtocolFeeConfig memory pc = _protocolFeeConfig;
            address protocolRecipient = pc.protocolFeeRecipient;

            if (protocolFeeShares > 0) {
                IFund(fund).mintFeeShares(protocolRecipient, protocolFeeShares);
            }
            if (managerFeeShares > 0) {
                IFund(fund).mintFeeShares(managerRecipient, managerFeeShares);
            }
        }

        uint256 newPps = _pricePerShareWad(fund);
        _fundFeeState[fund].lastAccrual = uint64(nowTs);

        if (newPps > uint256(_fundFeeState[fund].highWaterMark)) {
            _fundFeeState[fund].highWaterMark = uint192(newPps);
        }
    }

    //governance
    function setProtocolFeeRecipient(address newRecipient) external override onlyGovernance {
        if (newRecipient == address(0)) revert ZeroAddress();
        _protocolFeeConfig.protocolFeeRecipient = newRecipient;
    }

    function setProtocolTakes(uint16 newMgmtTakeBps, uint16 newPerfTakeBps) external override onlyGovernance {
        if (newMgmtTakeBps > 10_000 || newPerfTakeBps > 10_000) revert InvalidBps();
        _protocolFeeConfig.protocolMgmtTakeBps = newMgmtTakeBps;
        _protocolFeeConfig.protocolPerfTakeBps = newPerfTakeBps;
    }

    function setHighWaterMark(address fund, uint192 newHighWaterMark) external override onlyGovernance {
        _fundFeeState[fund].highWaterMark = newHighWaterMark;
    }

    //internal
    function _previewAccrue(address fund, uint256 nowTs)
        internal
        view
        returns (uint256 totalFeeShares, uint256 protocolFeeShares, uint256 managerFeeShares)
    {
        uint256 supply = IERC20(fund).totalSupply();
        if (supply == 0) return (0, 0, 0);

        FundFeeState memory st = _fundFeeState[fund];
        uint64 last = st.lastAccrual;

        if (last == 0) return (0, 0, 0);

        IFund.FeeConfig memory fc = IFund(fund).feeConfig();
        uint16 mgmtFeeBps = fc.mgmtFeeBps;
        uint16 perfFeeBps = fc.perfFeeBps;

        //management fee
        uint256 elapsed = nowTs > uint256(last) ? (nowTs - uint256(last)) : 0;
        uint256 mgmtFeeSharesTotal = 0;
        if (elapsed > 0 && mgmtFeeBps > 0) {
            mgmtFeeSharesTotal =
                (supply * uint256(mgmtFeeBps) * elapsed) /
                (10_000 * YEAR);
        }

        //perfomance fee
        uint256 perfFeeSharesTotal = 0;
        if (perfFeeBps > 0) {
            uint256 pps = _pricePerShareWad(fund);
            uint256 hwm = uint256(st.highWaterMark);
            if (pps > hwm && hwm > 0) {
                uint256 profitPerShare = pps - hwm;
                uint256 profitAssets = (profitPerShare * supply) / WAD;
                uint256 feeAssets = (profitAssets * uint256(perfFeeBps)) / 10_000;
                if (feeAssets > 0) {
                    perfFeeSharesTotal = (feeAssets * WAD) / pps;
                }
            }
        }

        // split protocol and manager
        ProtocolFeeConfig memory pc = _protocolFeeConfig;

        uint256 protocolMgmt = (mgmtFeeSharesTotal * uint256(pc.protocolMgmtTakeBps)) / 10_000;
        uint256 managerMgmt = mgmtFeeSharesTotal - protocolMgmt;

        uint256 protocolPerf = (perfFeeSharesTotal * uint256(pc.protocolPerfTakeBps)) / 10_000;
        uint256 managerPerf = perfFeeSharesTotal - protocolPerf;

        protocolFeeShares = protocolMgmt + protocolPerf;
        managerFeeShares = managerMgmt + managerPerf;
        totalFeeShares = protocolFeeShares + managerFeeShares;
    }

    function _pricePerShareWad(address fund) internal view returns (uint256) {
        uint256 supply = IERC20(fund).totalSupply();
        if (supply == 0) return WAD;
        uint256 total = IFund(fund).totalAssets();
        return (total * WAD) / supply;
    }
}
