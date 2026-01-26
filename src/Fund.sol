// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20}  from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IFund} from "./interfaces/IFund.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {IManager} from "./interfaces/IManager.sol";
import {IWithdrawalQueue} from "./interfaces/IWithdrawalQueue.sol";

//errors
error NotFeeCollector();
error InvalidFeeRecipient();
error NotManager();
error NotInitialized();
error AlreadyInitialized();
error ZeroAddress();
error ZeroAmount();
error InvalidBps();
error InsufficientShares();
error TransferFailed();

contract Fund is IFund, ERC20, ReentrancyGuard {
    bool public initialized;
    address public asset;
    address public manager;
    FundType public fundType;
    uint16 public bufferBps;
    FeeConfig private _feeConfig;
    address public withdrawalQueue;
    address public feeCollector;
    uint8 public riskTier;
    uint32 public riskScore;

    constructor() ERC20("Dargent Fund Share", "dFUND") {}

    //init
    function initialize(
        address asset_,
        address manager_,
        FundType fundType_,
        uint16 bufferBps_,
        FeeConfig calldata feeConfig_,
        address feeCollector_,
        address withdrawalQueue_
    ) external {
        if (initialized) revert AlreadyInitialized();

        if (
            asset_ == address(0) ||
            manager_ == address(0) ||
            feeCollector_ == address(0) ||
            withdrawalQueue_ == address(0) ||
            feeConfig_.managerFeeRecipient == address(0)
        ) revert ZeroAddress();

        if (bufferBps_ > 10_000) revert InvalidBps();
        if (feeConfig_.mgmtFeeBps > 10_000 || feeConfig_.perfFeeBps > 10_000) revert InvalidBps();

        asset = asset_;
        manager = manager_;
        fundType = fundType_;
        bufferBps = bufferBps_;

        _feeConfig = FeeConfig({
            mgmtFeeBps: feeConfig_.mgmtFeeBps,
            perfFeeBps: feeConfig_.perfFeeBps,
            managerFeeRecipient: feeConfig_.managerFeeRecipient
        });

        feeCollector = feeCollector_;
        withdrawalQueue = withdrawalQueue_;

        bool ok = IERC20(asset_).approve(withdrawalQueue_, type(uint256).max);
        if (!ok) revert TransferFailed();

        //when manager add the the strategies it will refresh the risk
        riskTier = 0;
        riskScore = 0;

        initialized = true;
    }

    //modifiers
    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    modifier onlyInitialized() {
        if (!initialized) revert NotInitialized();
        _;
    }

    modifier onlyFeeCollector() {
        if (msg.sender != feeCollector) revert NotFeeCollector();
        _;
    }

    //view
    function feeConfig() external view override returns (FeeConfig memory config) {
        return _feeConfig;
    }

    //accounting
    function totalAssets()
        public
        view
        override
        onlyInitialized
        returns (uint256)
    {
        return IManager(manager).totalAssets();
    }

    function convertToShares(uint256 assets)
        public
        view
        override
        onlyInitialized
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 total = totalAssets();
        if (supply == 0 || total == 0) return assets;
        return (assets * supply) / total;
    }

    function convertToAssets(uint256 shares)
        public
        view
        override
        onlyInitialized
        returns (uint256)
    {
        uint256 supply = totalSupply();
        if (supply == 0) return shares;
        uint256 total = totalAssets();
        return (shares * total) / supply;
    }

    function setRisk(uint8 tier, uint32 score)
        external
        override
        onlyInitialized
        onlyManager
    {
        riskTier = tier;
        riskScore = score;
    }

    //write
    function deposit(uint256 assets_, address receiver)
        external
        nonReentrant
        onlyInitialized
        returns (uint256 shares)
    {
        if (assets_ == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        IFeeCollector(feeCollector).accrue(address(this));

        uint256 totalBefore = totalAssets();
        uint256 supply = totalSupply();
        if (supply == 0 || totalBefore == 0) {
            shares = assets_;
        } else {
            shares = (assets_ * supply) / totalBefore;
        }

        if (shares == 0) revert ZeroAmount();

        bool ok = IERC20(asset).transferFrom(msg.sender, address(this), assets_);
        if (!ok) revert TransferFailed();

        _mint(receiver, shares);

        _afterDeposit(totalBefore, assets_);
    }

    function _afterDeposit(uint256 totalBefore, uint256 depositedAssets) internal {
        uint256 totalAfter = totalBefore + depositedAssets;
        uint256 desiredBuffer = (totalAfter * uint256(bufferBps)) / 10_000;
        uint256 idle = IERC20(asset).balanceOf(address(this));

        if (idle > desiredBuffer) {
            uint256 toAllocate = idle - desiredBuffer;
            IManager(manager).allocate(toAllocate);
        }
    }

    //fees
    function mintFeeShares(address to, uint256 shares)
        external
        override
        onlyInitialized
        onlyFeeCollector
        returns (uint256 minted)
    {
        if (to == address(0)) revert ZeroAddress();
        if (shares == 0) return 0;

        address protocolRecipient =
            IFeeCollector(feeCollector).protocolFeeConfig().protocolFeeRecipient;

        if (to != _feeConfig.managerFeeRecipient && to != protocolRecipient)
            revert InvalidFeeRecipient();

        _mint(to, shares);
        return shares;
    }

    //withdrawals
    function requestWithdraw(
        uint256 shares,
        address receiver,
        address owner_
    )
        external
        override
        onlyInitialized
        returns (uint256 requestId)
    {
        if (shares == 0) revert InsufficientShares();
        if (receiver == address(0) || owner_ == address(0)) revert ZeroAddress();

        IFeeCollector(feeCollector).accrue(address(this));

        if (msg.sender != owner_) {
            uint256 allowed = allowance(owner_, msg.sender);
            if (allowed < shares) revert InsufficientShares();
            _approve(owner_, msg.sender, allowed - shares);
        }

        _burn(owner_, shares);

        requestId = IWithdrawalQueue(withdrawalQueue).request(
            address(this),
            shares,
            receiver,
            owner_
        );
    }

    function processWithdrawals(uint256 maxToProcess)
        external
        override
        onlyInitialized
        nonReentrant
    {
        IFeeCollector(feeCollector).accrue(address(this));
        (, uint256 pendingAssets) = IWithdrawalQueue(withdrawalQueue).pending(address(this));

        uint256 idle = IERC20(asset).balanceOf(address(this));

        if (idle < pendingAssets) {
            uint256 need = pendingAssets - idle;
            IManager(manager).deallocate(need);
        }

        IWithdrawalQueue(withdrawalQueue).process(address(this), maxToProcess);
    }

    //governance via manager
    function setBufferBps(uint16 newBps)
        external
        override
        onlyInitialized
        onlyManager
    {
        if (newBps > 10_000) revert InvalidBps();
        bufferBps = newBps;
    }
}
