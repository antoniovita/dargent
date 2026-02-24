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
- forge script script/DeployAnvil.s.sol:DeployAnvil --rpc-url http://127.0.0.1:8545 --broadcast -vv


Quero implementar no meu Manager.sol um “ETF imutável com gestão ativa programada – NÍVEL 2 (rebalance por fluxo)”.

OBJETIVO
- Strategies e parâmetros definidos somente no initialize (imutável).
- Sem owner e sem possibilidade de adicionar/remover strategies depois.
- O Manager pode ajustar “targets” (pesos-alvo) periodicamente com base em riskScore (0..100), mas NÃO deve forçar movimentação de capital apenas para rebalancear.
- A correção do portfólio deve acontecer usando apenas o fluxo natural:
  - depósitos novos (allocate)
  - saques (deallocate)
Ou seja, “rebalance por fluxo”: direcionar entradas para underweight e retirar de overweight.

CONFIGURAÇÃO NO INITIALIZE (IMUTÁVEL)
- Lista de strategies (implementations -> clones) e pesos base (baseWeightBps) somando 10_000.
- Para cada strategy, armazenar também:
  - minWeightBps
  - maxWeightBps
  - aggressiveness (0..10_000)
- Parâmetros globais imutáveis:
  - cooldownRebalance (ex: 24h)
  - maxDeltaBpsPerRebalance (ex: 500 bps)
  - driftThresholdBps (ex: 200 bps) (só rebalanceia se desvio relevante)
- riskEngine é fixo após deploy (não pode trocar depois).

CONCEITO NÍVEL 2 (IMPORTANTE)
- Não mover capital “só para rebalancear”.
- A função rebalance apenas atualiza os PESOS-ALVO (targetWeightBps) dentro das bandas.
- allocate() deve distribuir depósitos priorizando strategies ABAIXO do target (underweight).
- deallocate() deve retirar priorizando strategies ACIMA do target (overweight), respeitando liquidez/ordem.

ESTRUTURA DE PESOS
- Manter dois pesos:
  1) baseWeightBps (imutável)
  2) targetWeightBps (mutável, calculado pelo rebalance)
- Inicialmente: targetWeightBps = baseWeightBps.

CÁLCULO DO NOVO TARGET (REBAlANCE)
Implementar:
    function rebalance() external

Regras:
- Pode ser permissionless (qualquer um chama) ou onlyFund (preferir permissionless).
- Respeitar cooldown: só 1x a cada cooldownRebalance.
- Consultar riskScore do riskEngine (0..100).
- Calcular tilt:
    tiltBps = (100 - riskScore) * 100  // mapeia 0..100 -> 0..10_000
- Para cada strategy:
    raw = baseWeightBps * (10_000 + (aggressiveness * tiltBps / 10_000)) / 10_000
- Normalizar raws para somar 10_000.
- Aplicar clamp para [minWeightBps, maxWeightBps].
- Aplicar maxDelta por rebalance:
    |newTarget - currentTarget| <= maxDeltaBpsPerRebalance
- Garantir soma final = 10_000.
- Atualizar targetWeightBps[strategy].
- Emitir evento Rebalanced(riskScore, timestamp, newTargets).

REBAlANCE POR FLUXO: ALLOCATE (DEPÓSITOS)
Modificar allocate(assets) para:
- Calcular totalAssets do conjunto (fund + strategies).
- Para cada strategy ativa:
    currentWeight = strategyAssets / totalAssets (em bps)
    deficitBps = max(targetWeightBps - currentWeight, 0)
- Distribuir o depósito proporcionalmente aos deficits (priorizar underweight).
- Se nenhuma deficit (todas >= target), distribuir por targetWeight normal.
- Manter carry de arredondamento como hoje.

REBAlANCE POR FLUXO: DEALLOCATE (SAQUES)
Modificar deallocate(assets) para:
- Priorizar retirar de strategies overweight:
    surplusBps = max(currentWeight - targetWeightBps, 0)
- Primeiro retirar de strategies líquidas (registry.isLiquid(impl)), em ordem de maior surplus.
- Se ainda faltar, retirar de não líquidas.
- Respeitar limites de withdraw de cada strategy (como hoje).
- Objetivo: ao sacar, “puxar para perto do target” sem swaps.

EMERGENCY STOP
- bool emergencyStopped
- emergencyStop() onlyFund irreversível.
- allocate() retorna imediatamente se emergencyStopped == true.
- deallocate() continua funcionando sempre.

RESTRIÇÕES DE IMUTABILIDADE
- Remover qualquer função externa para add/remove/reweight manual.
- Não existir owner.
- Strategies e bandas não mudam após initialize.
- Apenas targetWeightBps muda via rebalance, seguindo regras.

RESULTADO ESPERADO
- ETF com composição fixa, mas targets dinâmicos por risco.
- Ajuste do portfólio acontece naturalmente via entradas/saídas (Nível 2).
- Gas baixo: rebalance só altera targets e allocate/deallocate usam lógica simples.