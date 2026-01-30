# Dargent

## Overview
Dargent is a set of smart contracts to create on-chain funds with strategy allocation, withdrawal queues, fee accrual, and a risk engine. The core idea is separation of concerns: the Fund handles shares and buffer, the Manager allocates to strategies, registries govern what can be used, and the WithdrawalQueue manages asynchronous withdrawals.

## How it works (high level)
1) Governance approves assets and strategies in registries.  
2) ProductFactory creates a new Fund + Manager and instantiates strategies via clones.  
3) Users deposit into the Fund and receive shares.  
4) The Fund allocates capital to the Manager, which distributes it by weights.  
5) Withdrawals are asynchronous: request -> process -> claim.  
6) The RiskEngine computes product risk based on the strategy composition.

## Core components

### Fund
- ERC20 share token of the fund.
- Keeps a buffer (idle) and delegates allocation to the Manager.
- Withdrawals are async: `requestWithdraw` creates a queue entry, `processWithdrawals` tries to pay using buffer or by deallocating from strategies.
- Uses `FeeCollector` for fee accrual.

File: `src/Fund.sol`

### Manager
- Controls strategies and weights.
- Allocates and deallocates capital from the Fund.
- Instantiates strategies via clones.
- Validates strategies and assets via `StrategyRegistry`.

File: `src/Manager.sol`

### StrategyRegistry / AssetRegistry / ProductRegistry
- Governance registries for approving assets and strategies.
- `StrategyRegistry` stores `riskTier`, `riskScore`, and `isLiquid` per implementation.
- `AssetRegistry` stores decimals, status, and metadata.
- `ProductRegistry` registers Fund/Manager created by the factory.

Files: `src/registry/*.sol`

### ProductFactory
- Orchestrates Fund + Manager creation.
- Validates assets and strategies.
- Registers the product and returns addresses.

File: `src/ProductFactory.sol`

### WithdrawalQueue
- Asynchronous withdrawal queue.
- `request` creates a request with `assetsOwed`.
- `process` tries to pay from the Fund’s current balance.
- `claim` lets the user pull funds once claimable.

File: `src/WithdrawalQueue.sol`

### FeeCollector
- Calculates and mints fee shares (manager + protocol).
- Uses per-fund fee configuration.

File: `src/FeeCollector.sol`

### RiskEngine
- Computes risk for a Manager based on approved strategies.
- Uses weights and strategy `riskScore` from the `StrategyRegistry`.

File: `src/RiskEngine.sol`

## Deposit and withdrawal flow

### Deposit
1) User calls `Fund.deposit`.
2) Fund mints shares.
3) Fund allocates excess buffer to the Manager.
4) Manager distributes into strategies by weight.

### Withdrawal
1) User calls `Fund.requestWithdraw`.
2) WithdrawalQueue creates a request and shares are burned.
3) `Fund.processWithdrawals` tries to pay:
   - uses idle balance in the Fund;
   - if insufficient, calls `Manager.deallocate`.
4) Request becomes claimable and user calls `claim`.

## Strategy liquidity
The Manager can prioritize liquid strategies before non-liquid ones during `deallocate`.
Liquidity status is governed in the `StrategyRegistry` per strategy implementation.

## Test structure
Tests are split by focus:
- `test/BaseTest.t.sol`: shared setup (mocks, registries, factory).
- `test/E2E.t.sol`: end-to-end flows (deposit, allocation, withdrawal, claim).

## Development

### Requirements
- Foundry

### Commands
```bash
forge test -vv
```

## Design notes
- Clear separation between Fund (shares/fees), Manager (allocation), and registries (governance).
- Strategies are cloned to reuse implementations.
- Async withdrawals avoid failures when strategies are illiquid.

## Security considerations
- Always validate approvals and status in registries before creating products.
- `bufferBps` controls immediate liquidity; high values reduce allocation.
- `riskScore` and `riskTier` are governance-controlled and must reflect real strategy risk.
