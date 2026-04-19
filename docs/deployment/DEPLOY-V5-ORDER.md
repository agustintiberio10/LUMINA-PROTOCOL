# LUMINA Protocol V5.0 -- Deploy Order

> Canonical deployment sequence for Base mainnet.
> Every step lists its constructor arguments and upstream dependencies.

---

## Dependency Graph (ASCII)

```
Phase 1 (Independent)
  MaintenanceReserve ─────────────────────────────────────────────────────┐
  ClaimBond ──────────────────────────────────┐                          │
                                              │                          │
Phase 2 (Pre-compute LUMINA address)          │                          │
  precompute LuminaTokenV2 addr ──┬───────────┼──────────────────────────┤
                                  │           │                          │
  CapacityOracle ─────────────────┼───┐       │                          │
  BondVault ──────────────────────┼───┼───────┤                          │
  CEXLiquidityReserve ────────────┤   │       │                          │
  FounderVesting ─────────────────┤   │       │                          │
  TreasuryVesting ────────────────┤   │       │                          │
                                  │   │       │                          │
Phase 3 (Mint)                    │   │       │                          │
  LuminaTokenV2 ──────────────────┴───┼───────┼──────────────────────────┤
    (verifies address, mints)         │       │                          │
                                      │       │                          │
Phase 4 (Oracle & Adaptive)           │       │                          │
  ClaimBond.setBondVault() ───────────┼───────┘                          │
  SolvencyOracle ─────────────────────┤                                  │
  AdaptiveFeeDistributor ─────────────┤                                  │
                                      │                                  │
Phase 5 (Core Protocol)              │                                  │
  TWAPBurner ─────────────────────────┼──────────────────────────────────┤
  PolicyManagerV2 ────────────────────┤                                  │
  BondVault.setPolicyManager() ───────┤                                  │
  CoverRouterV2 ──────────────────────┤                                  │
  PolicyManagerV2.setRouter() ────────┤                                  │
                                      │                                  │
Phase 6 (Marketplace)                │                                  │
  LuminaBondMarketplace ─────────────┤                                  │
  BuybackEngine ──────────────────────┤                                  │
                                      │                                  │
Phase 7 (Shields)                    │                                  │
  9x Shield contracts ────────────────┤                                  │
                                      │                                  │
Phase 8 (Wire Roles)                 │                                  │
  grantRole / setX calls ────────────┴──────────────────────────────────┘
                                                                         │
Phase 9 (Ownership)                                                      │
  transferOwnership -> Multisig 2-of-3 ─────────────────────────────────┘
```

---

## Phase 1 -- Independent Contracts

| Step | Contract              | Constructor Args              | Depends On |
|------|-----------------------|-------------------------------|------------|
| 1    | `MaintenanceReserve`  | `(USDC, multisig)`            | --         |
| 2    | `ClaimBond`           | `()`                          | --         |

- **MaintenanceReserve** holds USDC used for protocol operational costs.
- **ClaimBond** is an ERC-1155 bond token contract with no constructor dependencies.

---

## Phase 2 -- Pre-compute LUMINA Address & Deploy Dependents

| Step | Contract               | Constructor Args                                                            | Depends On         |
|------|------------------------|-----------------------------------------------------------------------------|--------------------|
| 3    | *(pre-compute)*        | Predict `LuminaTokenV2` address via CREATE2 or deployer nonce               | --                 |
| 4    | `CapacityOracle`       | `(pool=0x0, luminaToken=precomputed, usdcToken=USDC, emergencyPrice=0.036e18)` | Step 3          |
| 5    | `BondVault`            | `(lumina=precomputed, claimBond, capacityOracle, policyManager=0x0)`        | Steps 2, 3, 4      |
| 6    | `CEXLiquidityReserve`  | `(lumina=precomputed, admin=multisig)`                                      | Step 3             |
| 7    | `FounderVesting`       | `(chainlinkOracle, aavePool, luminaToken=precomputed, usdc, recipient)`     | Step 3             |
| 8    | `TreasuryVesting`      | `(luminaToken=precomputed)`                                                 | Step 3             |

**Key insight:** Steps 4-8 all receive the *pre-computed* LUMINA address. The actual
token does not exist yet. These contracts must tolerate a zero-balance token address
during the window between Phase 2 and Phase 3.

- `BondVault.policyManager` is set to `address(0)` here; resolved in Phase 5 (step 15).
- `CapacityOracle.pool` is set to `address(0)` if the Uniswap pool is not yet created.

---

## Phase 3 -- Deploy LUMINA Token (Mint Distribution)

| Step | Contract          | Constructor Args                                                        | Depends On         |
|------|-------------------|-------------------------------------------------------------------------|---------------------|
| 9    | `LuminaTokenV2`   | `(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting)`  | Steps 5, 6, 7, 8   |

**On deployment the constructor:**
1. Verifies that `address(this)` matches the pre-computed value from Step 3.
2. Mints the full 100M supply:
   - `70,000,000 LUMINA` -> `BondVault`
   - `14,000,000 LUMINA` -> `CEXLiquidityReserve`
   - `8,000,000 LUMINA`  -> `FounderVesting`
   - `5,000,000 LUMINA`  -> `LBP Deposit` (Fjord Foundry)
   - `3,000,000 LUMINA`  -> `TreasuryVesting`

If the address does not match, the constructor must revert.

---

## Phase 4 -- Oracle & Adaptive Layers

| Step | Contract                  | Constructor / Call                        | Depends On      |
|------|---------------------------|-------------------------------------------|-----------------|
| 10   | `ClaimBond.setBondVault`  | `setBondVault(bondVault)`                 | Steps 2, 5      |
| 11   | `SolvencyOracle`          | `(bondVault, capacityOracle, admin=multisig)` | Steps 4, 5  |
| 12   | `AdaptiveFeeDistributor`  | `(solvencyOracle)`                        | Step 11         |

- `ClaimBond.setBondVault` is a **one-shot** call: it can only be called once.
- `SolvencyOracle` reads `BondVault` state to compute protocol-wide solvency ratios.

---

## Phase 5 -- Core Protocol

| Step | Contract                          | Constructor / Call                           | Depends On        |
|------|-----------------------------------|----------------------------------------------|-------------------|
| 13   | `TWAPBurner`                      | `(usdc, lumina, uniswapRouter)`              | Step 9            |
| 14   | `PolicyManagerV2`                 | `(bondVault)`                                | Step 5            |
| 15   | `BondVault.setPolicyManager`      | `setPolicyManager(policyManager)`            | Steps 5, 14       |
| 16   | `CoverRouterV2`                   | `(usdc, policyManager, twapBurner)`          | Steps 13, 14      |
| 17   | `PolicyManagerV2.setRouter`       | `setRouter(coverRouter)`                     | Steps 14, 16      |

- `BondVault.setPolicyManager` is a **one-shot** call that resolves the circular
  dependency between `BondVault` and `PolicyManagerV2`.
- After step 17 the core buy-cover flow is functional (but shields are not registered yet).

---

## Phase 6 -- Marketplace

| Step | Contract                   | Constructor Args                                                                  | Depends On              |
|------|----------------------------|-----------------------------------------------------------------------------------|-------------------------|
| 18   | `LuminaBondMarketplace`    | `(claimBond, usdc, twapBurner, admin=multisig)`                                   | Steps 2, 13             |
| 19   | `BuybackEngine`            | `(claimBond, bondVault, solvencyOracle, capacityOracle, marketplace, usdc, multisig)` | Steps 2, 4, 5, 11, 18 |

---

## Phase 7 -- Shields

| Step | Shield                   | Constructor                                    |
|------|--------------------------|------------------------------------------------|
| 20   | `FlashBTC_1h`            | `Shield(policyManager, chainlinkBTCOracle)`    |
| 21   | `FlashBTC_4h`            | `Shield(policyManager, chainlinkBTCOracle)`    |
| 22   | `FlashBTC_24h`           | `Shield(policyManager, chainlinkBTCOracle)`    |
| 23   | `FlashBTC_48h`           | `Shield(policyManager, chainlinkBTCOracle)`    |
| 24   | `FlashETH_1h`            | `Shield(policyManager, chainlinkETHOracle)`    |
| 25   | `FlashETH_24h`           | `Shield(policyManager, chainlinkETHOracle)`    |
| 26   | `FlashETH_48h`           | `Shield(policyManager, chainlinkETHOracle)`    |
| 27   | `MicroDepeg`             | `Shield(policyManager, chainlinkUSDTOracle)`   |
| 28   | `RateShock`              | `Shield(policyManager, chainlinkOracle)`       |

After deploying each shield:
1. Register in `PolicyManagerV2`: `policyManager.registerShield(shield)`
2. Configure in `CoverRouterV2`: `coverRouter.configureShield(shield, ...)`

All 9 shields depend on Steps 14 and 16 (PolicyManagerV2 and CoverRouterV2).

---

## Phase 8 -- Wire Roles & Permissions

| Step | Call                                                                    | Depends On        |
|------|-------------------------------------------------------------------------|-------------------|
| 29   | `LuminaTokenV2.grantRole(BURNER_ROLE, twapBurner)`                     | Steps 9, 13       |
| 30   | `TWAPBurner.setFeeDistributor(adaptiveFeeDistributor)`                  | Steps 12, 13      |
| 31   | `TWAPBurner.setReserves(buybackEngine, opsWallet, maintenanceReserve)`  | Steps 1, 13, 19   |
| 32   | `TWAPBurner.setCapacityOracle(capacityOracle)`                          | Steps 4, 13       |
| 33   | `TWAPBurner.setAdaptiveMode(true)`                                      | Step 13           |
| 34   | `TWAPBurner.setAuthorizedSender(coverRouter, true)`                     | Steps 13, 16      |
| 35   | `PolicyManager.setAuthorizedCaller(buybackEngine, true)` on BondVault   | Steps 14, 19      |

---

## Phase 9 -- Transfer Ownership to Multisig (2-of-3)

| Step | Contract            |
|------|---------------------|
| 36a  | `TWAPBurner`        |
| 36b  | `CoverRouterV2`     |
| 36c  | `PolicyManagerV2`   |
| 36d  | `CapacityOracle`    |
| 36e  | `FounderVesting`    |
| 36f  | `TreasuryVesting`   |
| 36g  | `ClaimBond`         |

Each call: `contract.transferOwnership(multisig)`

> **WARNING:** After this step, the deployer EOA loses admin access. Triple-check
> all wiring before executing Phase 9. There is no undo.

---

## Quick Reference -- Contract Address Registry

After deploy, record every address in a JSON registry:

```json
{
  "network": "base-mainnet",
  "chainId": 8453,
  "deployedAt": "<block-number>",
  "contracts": {
    "MaintenanceReserve": "0x...",
    "ClaimBond": "0x...",
    "CapacityOracle": "0x...",
    "BondVault": "0x...",
    "CEXLiquidityReserve": "0x...",
    "FounderVesting": "0x...",
    "TreasuryVesting": "0x...",
    "LuminaTokenV2": "0x...",
    "SolvencyOracle": "0x...",
    "AdaptiveFeeDistributor": "0x...",
    "TWAPBurner": "0x...",
    "PolicyManagerV2": "0x...",
    "CoverRouterV2": "0x...",
    "LuminaBondMarketplace": "0x...",
    "BuybackEngine": "0x...",
    "Shields": {
      "FlashBTC_1h": "0x...",
      "FlashBTC_4h": "0x...",
      "FlashBTC_24h": "0x...",
      "FlashBTC_48h": "0x...",
      "FlashETH_1h": "0x...",
      "FlashETH_24h": "0x...",
      "FlashETH_48h": "0x...",
      "MicroDepeg": "0x...",
      "RateShock": "0x..."
    }
  }
}
```
