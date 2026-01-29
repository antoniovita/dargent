// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStrategy {
    //view
    function asset() external view returns (address);
    function manager() external view returns (address);
    function totalAssets() external view returns (uint256); //always return in terms of the base asset
    function maxDeposit() external view returns (uint256);
    function maxWithdraw() external view returns (uint256);

    //write
    function deposit(uint256 assets) external returns (uint256 depositedAssets);
    function withdraw(uint256 assets, address receiver) external returns (uint256 withdrawnAssets);

    //governance and manager owner only
    function maxPossibleWithdraw(address receiver) external returns (uint256 freedAssets);

    //initialize
    function initialize(
        address manager_,
        address asset_
    ) external;

}
