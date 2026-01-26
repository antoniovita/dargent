// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFund {
    enum FundType {
        HOUSE,
        MANAGED
    }

    struct FeeConfig {
        uint16 mgmtFeeBps;
        uint16 perfFeeBps;
        address managerFeeRecipient;
    }

    //view
    function asset() external view returns (address);
    function manager() external view returns (address);
    function fundType() external view returns (FundType);
    function bufferBps() external view returns (uint16);
    function totalAssets() external view returns (uint256);
    function riskTier() external view returns (uint8);
    function riskScore() external view returns (uint32);
    function feeConfig() external view returns (FeeConfig memory config);
    function withdrawalQueue() external view returns (address);
    function feeCollector() external view returns (address);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);    
    
    //write
    function setRisk(uint8 tier, uint32 score) external;
    function mintFeeShares(address to, uint256 shares) external returns (uint256 minted);
    function requestWithdraw(uint256 shares, address receiver, address owner) external returns (uint256 requestId);
    function processWithdrawals(uint256 maxToProcess) external;
    function setBufferBps(uint16 newBps) external;
}