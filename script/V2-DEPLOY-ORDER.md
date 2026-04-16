# V2 Deploy Order

## CRITICAL: Shield constructor takes `router_` parameter.
## In V2, `router_` MUST be the PolicyManagerV2 address.
## BaseShield.onlyRouter gates createPolicy() to this address.

1. Deploy LuminaTokenV2(bondVault, lbp, founderVesting, treasuryVesting)
2. Deploy ClaimBond()
3. Deploy CapacityOracle(pool, lumina, usdc, emergencyPrice)
4. Deploy BondVault(lumina, claimBond, capacityOracle, policyManager)
   → Need PolicyManager address first... see step 6
5. Deploy TWAPBurner(usdc, lumina, swapRouter)
6. Deploy PolicyManagerV2(bondVault)
7. Deploy CoverRouterV2(usdc, policyManager, twapBurner)
8. Call claimBond.setBondVault(bondVault)
9. Call policyManager.setRouter(coverRouterV2)
10. Deploy all shields with router_ = policyManager (NOT coverRouterV2)
11. Call policyManager.registerProduct() for each shield
12. Call coverRouterV2.configureProduct() for each product
13. Grant BURNER_ROLE on LuminaTokenV2 to TWAPBurner
14. Call twapBurner.setCapacityOracle(capacityOracle)  // [H-2] slippage protection

## Circular dependency resolution:
## BondVault needs PolicyManager address → deploy PolicyManager first
## But PolicyManager needs BondVault address → deploy BondVault first
## SOLUTION: Deploy PolicyManager with a temp bondVault, then update
## OR: Use CREATE2 to predict addresses
## OR: Make bondVault settable once in PolicyManager (like ClaimBond pattern)

## Current state (commit post-audit fixes):
## - `PolicyManagerV2.bondVault` is `immutable` (set in constructor)
## - `BondVault.policyManager` is `immutable` (set in constructor)
## → MUST use CREATE2 address prediction, OR deploy a temporary
##   zero-impact shim as one of the two sides and migrate.
##
## Recommended: CREATE2 predict PolicyManagerV2 address first,
## deploy BondVault with the predicted address,
## then deploy PolicyManagerV2 via CREATE2 at the predicted address
## with the actual BondVault address as constructor arg.
