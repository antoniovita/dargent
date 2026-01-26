// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWithdrawalQueue} from "./interfaces/IWithdrawalQueue.sol";
import {IFund} from "./interfaces/IFund.sol";

//errors
error NotReceiver();
error ZeroAddress();
error NotFundCaller();
error ZeroShares();
error UnknownRequest(uint256 requestId);
error NotClaimable(uint256 requestId);
error AlreadyClaimed(uint256 requestId);

contract WithdrawalQueue is IWithdrawalQueue, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Request {
        address fund;
        address receiver;
        address owner;
        uint256 shares;
        uint256 assetsOwed;
        bool claimable;
        bool claimed;
    }

    uint256 public nextRequestId = 1;

    mapping(uint256 => Request) public requests;

    mapping(address => uint256[]) internal _fundQueue;
    mapping(address => uint256) internal _fundHead;

    mapping(address => uint256) internal _pendingShares;
    mapping(address => uint256) internal _pendingAssets;

    //modifiers
    modifier nonZero(address a) {
        if (a == address(0)) revert ZeroAddress();
        _;
    }

    modifier onlyFundCaller(address fund) {
        if (msg.sender != fund) revert NotFundCaller();
        _;
    }

    modifier validShares(uint256 shares) {
        if (shares == 0) revert ZeroShares();
        _;
    }

    modifier requestExists(uint256 requestId) {
        if (requests[requestId].fund == address(0)) revert UnknownRequest(requestId);
        _;
    }

    modifier claimable(uint256 requestId) {
        if (!requests[requestId].claimable) revert NotClaimable(requestId);
        _;
    }

    modifier notClaimed(uint256 requestId) {
        if (requests[requestId].claimed) revert AlreadyClaimed(requestId);
        _;
    }

    //view
    function pending(address fund)
        external
        view
        override
        returns (uint256 pendingShares, uint256 pendingAssets)
    {
        return (_pendingShares[fund], _pendingAssets[fund]);
    }

    function isClaimable(uint256 requestId)
        external
        view
        requestExists(requestId)
        returns (bool)
    {
        Request storage r = requests[requestId];
        return r.claimable && !r.claimed;
    }

    //write
    function request(
        address fund,
        uint256 shares,
        address receiver,
        address owner
    )
        external
        override
        nonReentrant
        nonZero(fund)
        nonZero(receiver)
        nonZero(owner)
        onlyFundCaller(fund)
        validShares(shares)
        returns (uint256 requestId)
    {
        uint256 assetsOwed = _assetsForSharesPreBurn(fund, shares);

        requestId = nextRequestId++;
        requests[requestId] = Request({
            fund: fund,
            receiver: receiver,
            owner: owner,
            shares: shares,
            assetsOwed: assetsOwed,
            claimable: false,
            claimed: false
        });

        _fundQueue[fund].push(requestId);

        _pendingShares[fund] += shares;
        _pendingAssets[fund] += assetsOwed;

        emit WithdrawRequested(requestId, fund, owner, receiver, shares, assetsOwed);
    }

    function process(address fund, uint256 maxToProcess)
        external
        override
        nonReentrant
        nonZero(fund)
        returns (uint256 processed)
    {
        if (maxToProcess == 0) return 0;

        address asset = IFund(fund).asset();
        IERC20 token = IERC20(asset);

        uint256 available = token.balanceOf(fund);

        uint256 head = _fundHead[fund];
        uint256 len = _fundQueue[fund].length;

        while (processed < maxToProcess && head < len) {
            uint256 id = _fundQueue[fund][head];
            Request storage r = requests[id];

            if (r.claimed || r.claimable) {
                head++;
                processed++;
                continue;
            }

            uint256 amt = r.assetsOwed;

            if (available < amt) break;

            token.safeTransferFrom(fund, address(this), amt);

            r.claimable = true;

            _pendingShares[fund] -= r.shares;
            _pendingAssets[fund] -= amt;

            available -= amt;

            emit WithdrawClaimable(id, fund, r.receiver, amt);

            head++;
            processed++;
        }

        _fundHead[fund] = head;
    }

    function claim(uint256 requestId)
        external
        override
        nonReentrant
        requestExists(requestId)
        claimable(requestId)
        notClaimed(requestId)
        returns (uint256 assetsPaid)
    {
        Request storage r = requests[requestId];

        if (msg.sender != r.receiver) revert NotReceiver();

        address asset = IFund(r.fund).asset();
        IERC20 token = IERC20(asset);

        assetsPaid = r.assetsOwed;
        r.claimed = true;

        token.safeTransfer(r.receiver, assetsPaid);

        emit WithdrawClaimed(requestId, r.receiver, assetsPaid);
    }

    //internal
    function _assetsForSharesPreBurn(address fund, uint256 shares)
        internal
        view
        returns (uint256 assetsOwed)
    {
        uint256 supplyAfter = IERC20(fund).totalSupply();
        uint256 supplyBefore = supplyAfter + shares;

        uint256 total = IFund(fund).totalAssets();

        if (supplyBefore == 0 || total == 0) return shares;
        return (shares * total) / supplyBefore;
    }
}
