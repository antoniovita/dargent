// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStrategyRegistry {
    enum Status {
        NONE,
        ACTIVE,
        INACTIVE,
        DEPRECATED
    }

    struct StrategyInfo {
        Status status;
        uint8 riskTier;
        uint32 riskScore;
        bool isLiquid;
        string metadataURI;
        uint64 approvedAt;
    }

    // events
    event StrategyApproved(address indexed implementation, uint64 approvedAt);
    event StrategyStatusSet(address indexed implementation, Status oldStatus, Status newStatus);
    event StrategyRiskSet(address indexed implementation, uint8 riskTier, uint32 riskScore, bool isLiquid);
    event StrategyMetadataURISet(address indexed implementation, string newURI);
    event StrategyAssetSupportSet(address indexed implementation, address indexed asset, bool supported);

    //views
    function getStrategyInfo(address implementation) external view returns (StrategyInfo memory);
    function status(address implementation) external view returns (Status);
    function riskTier(address implementation) external view returns (uint8);
    function riskScore(address implementation) external view returns (uint32);
    function isLiquid(address implementation) external view returns (bool);
    function metadataURI(address implementation) external view returns (string memory);
    function approvedAt(address implementation) external view returns (uint64);
    function isActive(address implementation) external view returns (bool);
    function supportsAsset(address implementation, address asset) external view returns (bool);
    function isApproved(address implementation) external view returns (bool);

    //governance
    function approveStrategy(address implementation, StrategyInfo calldata info) external;
    function setStatus(address implementation, Status newStatus) external;
    function setRisk( address implementation, uint8 newRiskTier, uint32 newRiskScore, bool newIsLiquid) external;
    function setMetadataURI(address implementation, string calldata newURI) external;
    function setAssetSupport(address implementation, address asset, bool supported) external;
}
