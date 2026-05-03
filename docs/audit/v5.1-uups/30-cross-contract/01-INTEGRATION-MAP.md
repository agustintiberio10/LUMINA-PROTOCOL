# Audit V5.1 #30 — Cross-Contract Integration Map

Complete map of every inter-contract call in V5.1 + initialization order + trust assumptions.

---

## 1. Main flows (who-calls-whom)

### 1.1 Policy purchase

```
User (or Relayer on behalf of User)
  CoverRouterV2.purchasePolicy(productId, coverage, asset)
    USDC.transferFrom(payer, CoverRouterV2)
    CapacityOracle.getLuminaPrice()   [read — auto-pause check]
    USDC.forceApprove(TWAPBurner)
    TWAPBurner.receivePremium(premium)
      USDC.transferFrom(CoverRouterV2, TWAPBurner)
    PolicyManagerV2.recordPolicy(productId, buyer, coverage, premium, duration, asset)
      BondVault.availableCapacityUSD()   [read — capacity check]
      BondVault.reserveCapacity(reservedAmount)
      Shield.createPolicy(...)            [external — mock/real per-product]
      [stores PolicyRecord + policyReservedUSD[productId][policyId]]
```

**Events emitted (in order):**
1. `TWAPBurner.PremiumReceived`
2. `BondVault.CapacityReserved`
3. `Shield.*` (per shield)
4. `PolicyManagerV2.PolicyCreated`
5. `CoverRouterV2.PolicyPurchased`

### 1.2 Policy settlement (trigger or expire)

```
Shield (called by keeper/user)
  PolicyManagerV2.settlePolicy(productId, policyId, triggered)
    require(msg.sender == shield)
    if triggered:
      BondVault.commitReservation(reserved)   [moves USD from reserved → committed]
      Shield.verifyAndCalculate(...)           [oracle proof validation]
      BondVault.issueBond(buyer, payoutUSD)
        CapacityOracle.getLuminaPrice()        [read — capacity check]
        ClaimBond.mint(buyer, epoch, usdAmount)
    else:  // expired / not triggered
      BondVault.releaseReservation(reserved)
```

**Events emitted:**
- Triggered: `ReservationCommitted`, `BondIssued`, `PolicyTriggered`.
- Expired: `ReservationReleased`, `PolicyExpired`.

### 1.3 Bond redemption (at maturity)

```
Holder
  BondVault.redeemBond(epochId, usdAmount)
    ClaimBond.isMatured(epoch)   [read]
    ClaimBond.balanceOf(holder, epoch)   [read]
    CapacityOracle.getLuminaPrice()   [via _getSafePrice]
    ClaimBond.burn(holder, epoch, usdAmount)
    LUMINA.transfer(holder, luminaAmount)
```

**Events:** `ClaimBond.TransferSingle` (ERC-1155), `BondVault.BondRedeemed`, `LUMINA.Transfer`.

### 1.4 Marketplace list + buy

```
Seller
  ClaimBond.setApprovalForAll(Marketplace, true)
  LuminaBondMarketplace.list(epoch, amount, priceUSDC)
    ClaimBond.balanceOf(seller, epoch)   [read]
    ClaimBond.maturityDate(epoch)   [read]
    ClaimBond.safeTransferFrom(seller, Marketplace, epoch, amount, "")

Buyer
  USDC.approve(Marketplace)
  LuminaBondMarketplace.executeBuy(listingId)
    USDC.transferFrom(buyer, Marketplace, priceUSDC + buyerFee)
    USDC.transfer(seller, priceUSDC - sellerFee)
    USDC.transfer(twapBurner, sellerFee + buyerFee)   [3% total]
    ClaimBond.safeTransferFrom(Marketplace, buyer, epoch, amount, "")
```

**Events:** `Listed`, `Bought`, ERC-1155 `TransferSingle`, ERC-20 `Transfer` ×3.

### 1.5 Buyback full cycle

```
BUYBACK_OPERATOR_ROLE (admin or keeper)
  BuybackEngine.executeOffer(listingId)
    Marketplace.getListing(listingId)   [read]
    USDC.forceApprove(Marketplace, priceUSDC + buyerFee)
    Marketplace.executeBuy(listingId)   [BuybackEngine is the buyer]
      → see 1.4
    USDC.forceApprove(Marketplace, 0)
    _executeDoubleBurn(epoch, amount):
      ClaimBond.burnByHolder(BuybackEngine, epoch, amount)
      BondVault.decreaseObligations(faceValueUSD)
      BondVault.burnFromReserves(luminaToBurn)   // up to 5% of vault
        LUMINA.burn(luminaToBurn)
```

**Events:** `OfferExecuted`, `DoubleBurnExecuted`, `ObligationsDecreased`, `ReservesBurned`.

### 1.6 TWAPBurner distribution (after cooldown)

```
Anyone (permissionless)
  TWAPBurner.executeBurn()
    AdaptiveFeeDistributor.getDistribution() [if adaptiveModeEnabled]
      SolvencyOracle.getCurrentQuadrant()   [read — sLevel+mLevel]
      [returns (burnBps, buybackBps, opsBps, maintBps)]
    _executeAdaptive(amount):
      USDC.transfer(buybackReserve, toBuyback) [→ BuybackEngine]
      USDC.transfer(opsReserve, toOps)
      USDC.transfer(maintenanceReserve, toMaint) [→ MaintenanceReserve]
      _swapAndBurn(toBurn):
        CapacityOracle.getLuminaPrice()   [read — slippage floor]
        DexRouter.swap(USDC → LUMINA)
        LUMINA.burn(luminaReceived)
```

**Events:** `PremiumReceived`, `AdaptiveDistributionExecuted`, `BurnExecuted`.

### 1.7 Solvency evaluation

```
Anyone (permissionless, but cooldown-gated)
  SolvencyOracle.evaluate()
    BondVault.totalCommittedUSD()   [read]
    LUMINA.balanceOf(BondVault)   [read]
    CapacityOracle.getLuminaPrice()   [read]
    [updates solvencyHistory + momentumHistory]
    [if cooldown passed and classification differs]:
      [updates currentSolvencyLevel + currentMomentumLevel]
```

**Events:** `EvaluationExecuted`, `QuadrantChanged`.

### 1.8 Auto-pause circuit breaker (fix #28)

```
Anyone (permissionless)
  CoverRouterV2.syncCircuitBreaker()
    CapacityOracle.getLuminaPrice()   [read]
    [if price crosses MIN/RESET thresholds]:
      autoPausedOnce = true/false
```

**Events:** `AutoPauseActivated`, `AutoPauseDeactivated`.

---

## 2. Initialization dependency graph

The following contracts must be deployed in this order to avoid uninitialized references:

```
LuminaTokenV2         (depends on: BondVault address PREDICTED pre-deploy)
    ↓ (token distributed at mint)
TWAPBurner            (USDC, LUMINA, initial DEX)
    ↓
ClaimBond             (no deps — self-init)
    ↓
PolicyManagerV2       (BondVault address PREDICTED; wired later via setRouter)
    ↓
BondVault             (LUMINA, ClaimBond, CapacityOracle, PolicyManager address)
    ↓ (2-step: setPolicyManager can be called post-deploy if init was address(0))
ClaimBond.setBondVault()
CoverRouterV2         (USDC, PolicyManager, TWAPBurner)
    ↓
PolicyManagerV2.setRouter(CoverRouterV2)
Shields               (CoverRouter address at init)
    ↓
PolicyManagerV2.registerProduct(Shield)
CoverRouterV2.configureProduct(...)
CapacityOracle        (pool, LUMINA, USDC, emergency price)
CoverRouterV2.setCapacityOracle(CapacityOracle)
SolvencyOracle        (BondVault, CapacityOracle, admin)
AdaptiveFeeDistributor (SolvencyOracle)
TWAPBurner.setFeeDistributor(AdaptiveFeeDistributor)
LuminaBondMarketplace (ClaimBond, USDC, TWAPBurner, admin)
ClaimBond.setAuthorizedOperator(Marketplace, true) [Fix #18]
BuybackEngine         (ClaimBond, BondVault, SolvencyOracle, CapacityOracle, Marketplace, USDC, admin)
BondVault.setAuthorizedCaller(BuybackEngine, true)
MaintenanceReserve    (USDC, admin)
TWAPBurner.setReserves(BuybackEngine, opsEOA, MaintenanceReserve)
TWAPBurner.setAdaptiveMode(true)
CEXLiquidityReserve   (LUMINA, multisig)
TreasuryVesting       (LUMINA)
ShieldKeeper          (PolicyManager)
FounderVesting        (IMMUTABLE — constructor-only, no upgrade)
```

### Circular dependency: BondVault ↔ PolicyManagerV2

- BondVault needs `policyManager` address to reject untrusted callers.
- PolicyManagerV2 needs `bondVault` address for capacity/reserve calls.

**Resolution:** BondVault's `initialize(...)` accepts `_policyManager = address(0)` for a 2-step pattern:
1. Deploy BondVault with `address(0)`.
2. Deploy PolicyManagerV2 referencing BondVault.
3. Call `BondVault.setPolicyManager(address)` — one-shot, only-deployer-can-call.

Verified by `test_CrossContract_InitOrder_TwoStepBondVault_DeployerIsSetter`.

### Token distribution circular prediction

LuminaTokenV2's `initialize` mints 70M LUMINA directly to BondVault's address. Since BondVault doesn't exist yet, the deploy script uses `vm.computeCreateAddress` (or real `CREATE2` addresses in production) to compute the BondVault proxy address before deployment, then passes it to LuminaTokenV2.

Verified by `_deployFullStack`.

---

## 3. Trust assumptions

### Between protocol contracts

| Caller → Callee | Trust assumed | Enforced by |
|---|---|---|
| CoverRouterV2 → PolicyManagerV2 | PM validates capacity correctly | `recordPolicy` checks `bondVault.availableCapacityUSD()` |
| PolicyManagerV2 → BondVault | Only PM can reserve/commit | `require(msg.sender == policyManager)` in `reserveCapacity`/`commitReservation`/`releaseReservation` |
| PolicyManagerV2 → BondVault.issueBond | Only PM can mint bonds | `require(msg.sender == policyManager)` in `issueBond` |
| CoverRouterV2 → TWAPBurner | Burner accepts premium | `receivePremium` accepts any caller (no auth check — acceptable, pull-only via transferFrom) |
| BuybackEngine → Marketplace | Marketplace honors listing | `executeBuy` checks listing is active |
| BuybackEngine → BondVault | Vault allows obligation decrease + burnFromReserves | `onlyAuthorized` (set via `setAuthorizedCaller`) |
| Marketplace → ClaimBond | ClaimBond transfers after authorizedOperator whitelist [Fix #18] | `safeTransferFrom` checks whitelist |
| TWAPBurner → DexRouter | Best quote + minOut guard [Fix M-02] | `_swapAndBurn` enforces non-zero minOut |
| TWAPBurner → LUMINA.burn | TWAPBurner burns its OWN swap-acquired balance via `burn(uint256)` (no role gate, no allowance needed). The `BURNER_ROLE` grant at deploy is a legacy reserved hook — **not consulted by this path post [Fix H-1]**. | `ERC20Burnable.burn(amount)` (self-burn) |
| SolvencyOracle → BondVault | Read-only view of totalCommittedUSD + LUMINA balance | View-only; no mutations |
| CapacityOracle → Uniswap Pool | Pool returns a valid TWAP price | fallback to emergency price on oracle failure |
| AdaptiveFeeDistributor → SolvencyOracle | Quadrant returned is valid | `getCurrentQuadrant` enforces sLevel < 4 && mLevel < 4 |

### Between protocol and external

| External | Trust | Mitigation |
|---|---|---|
| USDC | Standard ERC-20 behavior | SafeERC20 used throughout |
| DexRouter (Uniswap V3, Aerodrome) | Quote accuracy within slippage bounds | maxSlippageBps (50-1000) + dual quote+oracle minOut |
| Uniswap V3 Pool | Valid `slot0()` TWAP | Emergency price fallback on CapacityOracle |
| Users (AI agents, humans) | Valid input only | Per-product config min coverage + zero checks |

---

## 4. Invariants observed across flows

1. **Total reserved USD = sum of per-policy `policyReservedUSD`** (for non-triggered, non-expired policies).
2. **Total committed USD = sum of all outstanding bond face values × 1e18**.
3. **LUMINA conservation on redemption**: vault's delta == holder's delta (no third-party gain/loss).
4. **Bond ERC-1155 supply = sum of outstanding bond face values** for a given epoch.
5. **Premium USDC lands 100% in TWAPBurner** — no skim.
6. **Marketplace fees**: buyer pays `price + 1.5%`; seller receives `price - 1.5%`; TWAPBurner gets exactly 3%.
7. **Double-burn**: ClaimBond supply decreases AND BondVault LUMINA balance decreases simultaneously.

All verified via tests in `CrossContractIntegration.t.sol`.

---

## 5. Decimal conventions (verified)

| Context | Unit | Example |
|---|---|---|
| USDC balances, fees, premiums | 6 decimals | 1000e6 = $1000 |
| LUMINA balances, swaps | 18 decimals | 70_000_000e18 = 70M LUMINA |
| LUMINA price (oracle) | 18 decimals | 36e15 = $0.036 |
| BondVault.totalCommittedUSD | 18-dec USD-wei | 800e18 = $800 of obligation |
| BondVault.totalReservedUSD | 18-dec USD-wei | same |
| ClaimBond balances | integer dollars | 800 = $800 face value |
| `recordPolicy.premiumAmount` | 6-dec (USDC native) | 12e6 = $12 |
| `issueBond.usdPayout` | integer dollars | 800 (then ×1e18 internally) |
| `redeemBond.usdAmount` | integer dollars | 800 |
| `redeemBond` payout LUMINA | 18 decimals | `usdAmount * 1e36 / price` |

Unit conversions between these types are the most common source of cross-contract bugs. Verified via `test_CrossContract_BondFaceValue_IntegerDollars_Matches18DecUsdWei` and `test_CrossContract_Decimals_USDC6_LUMINA18_Consistent`.

---

## 6. Integrations NOT yet wired (expected external config)

- **Chainlink keeper / Gelato**: `ShieldKeeper.performUpkeep` needs an external keeper subscription.
- **Real DEX pools**: on mainnet, TWAPBurner's router list should include both Uniswap V3 and Aerodrome adapters.
- **Timelock controller**: for production, admin roles should be granted to a 48h Timelock.

All of these are deployment-config items, not integration gaps in the code.
