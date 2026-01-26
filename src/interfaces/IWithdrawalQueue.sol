// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IWithdrawalQueue {
    //events
    event WithdrawRequested(
        uint256 indexed requestId,
        address indexed fund,
        address indexed owner,
        address receiver,
        uint256 shares,
        uint256 assetsOwed
    );
    event WithdrawClaimable(
        uint256 indexed requestId,
        address indexed fund,
        address indexed receiver,
        uint256 assets
    );
    event WithdrawClaimed(
        uint256 indexed requestId,
        address indexed receiver,
        uint256 assets
    );


    //view
    function pending(address fund) external view returns (uint256 pendingShares, uint256 pendingAssets);

    //write
    function request(address fund, uint256 shares, address receiver, address owner) external returns (uint256 requestId);
    function process(address fund, uint256 maxToProcess) external returns (uint256 processed);
    function claim(uint256 requestId) external returns (uint256 assetsPaid);
}