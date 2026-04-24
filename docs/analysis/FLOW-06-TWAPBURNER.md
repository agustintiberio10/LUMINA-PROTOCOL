# FLOW-06 — TWAPBurner post-swap destination

---

## 6.1 TWAPBurner responsibilities

1. Receive USDC (from CoverRouter premium or direct transfer from Marketplace fees).
2. Cool-down-gate the burn cadence (`burnCooldown`, default 900s).
3. Cap per-tx burn to `maxBurnAmount` (default 10,000 USDC = $10k).
4. Read distribution from AdaptiveFeeDistributor (4-bucket tuple).
5. Split the USDC across 4 destinations: burn / buyback / ops / maintenance.
6. For the burn bucket: swap USDC → LUMINA via best DEX quote, then `burn` the LUMINA.

## 6.2 The `executeBurn` flow

`src/core/TWAPBurner.sol:130-144`:

```solidity
function executeBurn() external nonReentrant {
    require(block.timestamp >= lastBurnTimestamp + burnCooldown, "Cooldown active");
    uint256 usdcBalance = usdc.balanceOf(address(this));
    require(usdcBalance >= minBurnAmount, "Below minimum");
    uint256 amount = usdcBalance > maxBurnAmount ? maxBurnAmount : usdcBalance;
    lastBurnTimestamp = block.timestamp;
    if (adaptiveModeEnabled) {
        _executeAdaptive(amount);
    } else {
        _executeLegacyBurn(amount);
    }
}
```

- Permissionless — anyone can trigger. Keepers or users may.
- `amount` is the smaller of {current balance, 10k cap}.
- Branches on `adaptiveModeEnabled`.

## 6.3 `_executeAdaptive` — the critical split

`src/core/TWAPBurner.sol:148-171`:

```solidity
function _executeAdaptive(uint256 amount) internal {
    (uint256 burnBps, uint256 buybackBps, uint256 opsBps, uint256 maintBps) = _getDistribution();
    require(burnBps + buybackBps + opsBps + maintBps <= 10000, "Invalid distribution");

    uint256 toBurn = (amount * burnBps) / 10000;
    uint256 toBuyback = (amount * buybackBps) / 10000;
    uint256 toOps = (amount * opsBps) / 10000;
    uint256 toMaint = (amount * maintBps) / 10000;

    if (toBuyback > 0 && buybackReserve != address(0)) {
        usdc.safeTransfer(buybackReserve, toBuyback);
    }
    if (toOps > 0 && opsReserve != address(0)) {
        usdc.safeTransfer(opsReserve, toOps);
    }
    if (toMaint > 0 && maintenanceReserve != address(0)) {
        usdc.safeTransfer(maintenanceReserve, toMaint);
    }
    if (toBurn > 0) {
        _swapAndBurn(toBurn);
    }

    emit AdaptiveDistributionExecuted(amount, toBurn, toBuyback, toOps, toMaint);
}
```

Observations:

- The sum of bps may be < 10000 (rounding "dust" stays in TWAPBurner). Sum ≤ 10000 is enforced (hard max); the 16-cell table always sums to exactly 10000.
- Three of four destinations are transfers TO a configured address. Only `toBurn` goes through `_swapAndBurn`.

## 6.4 `_swapAndBurn` — where LUMINA is destroyed

`src/core/TWAPBurner.sol:199-247`:

```solidity
function _swapAndBurn(uint256 usdcAmount) internal {
    require(dexRouters.length > 0, "No DEX routers configured");

    IDexRouter bestRouter = dexRouters[0];
    uint256 bestQuote = 0;

    for (uint256 i = 0; i < dexRouters.length; i++) {
        try dexRouters[i].getQuote(address(usdc), address(lumina), usdcAmount) returns (uint256 quote) {
            if (quote > bestQuote) {
                bestQuote = quote;
                bestRouter = dexRouters[i];
            }
        } catch {}
    }

    uint256 minOut = 0;
    if (bestQuote > 0) {
        minOut = (bestQuote * (10_000 - maxSlippageBps)) / 10_000;
    }
    if (capacityOracle != address(0)) {
        try IPriceOracle(capacityOracle).getLuminaPrice() returns (uint256 oraclePrice) {
            if (oraclePrice > 0) {
                uint256 expectedOut = (usdcAmount * 1e12 * 1e18) / oraclePrice;
                uint256 oracleMin = (expectedOut * (10_000 - maxSlippageBps)) / 10_000;
                if (oracleMin > minOut) {
                    minOut = oracleMin;
                }
            }
        } catch {}
    }

    require(minOut > 0, "TWAPBurner: minOut must be > 0");

    usdc.forceApprove(address(bestRouter), usdcAmount);
    uint256 luminaReceived = bestRouter.swap(address(usdc), address(lumina), usdcAmount, minOut);

    require(luminaReceived > 0, "Swap returned 0");

    IBurnable(address(lumina)).burn(luminaReceived);   // <-- LUMINA IS DESTROYED HERE

    totalUSDCBurned += usdcAmount;
    totalLUMINABurned += luminaReceived;

    uint256 effectivePrice = (usdcAmount * 1e18) / luminaReceived;
    emit BurnExecuted(usdcAmount, luminaReceived, effectivePrice, block.timestamp);
}
```

### 6.4.1 THE CRITICAL OBSERVATION

**Line 240:** `IBurnable(address(lumina)).burn(luminaReceived);`

After the swap, TWAPBurner holds `luminaReceived` LUMINA. It **burns it**. It does NOT:

- Transfer it to BondVault.
- Transfer it anywhere.
- Stake, wrap, or deposit it.

The LUMINA that exits the DEX → enters TWAPBurner (transiently) → is immediately destroyed via `burn(amount)` which calls `ERC20Burnable._burn(msg.sender, amount)` on LuminaTokenV2, reducing `totalSupply`.

### 6.4.2 Design intent

The "T" in TWAPBurner is "Time-Weighted Average Price" — the idea is to drip-burn LUMINA over time via cooldown-spaced executions so the swap cost does not spike the price and so any single burn cannot be sandwich-attacked. The protocol exchanges USDC for permanent LUMINA supply reduction — effectively redistributing value from the protocol's USDC income back to all LUMINA holders via scarcity.

### 6.4.3 Why the swap ≠ a BondVault refill

A replenishment path would look like:

```
  (hypothetical)  usdc.approve(DEX, X)
                  dex.swap(USDC → LUMINA)
                  lumina.transfer(bondVault, luminaReceived)
```

That is NOT what happens. Line 240 replaces the `transfer(bondVault, ...)` with `burn(...)`. The design commits to deflation — never accumulation in the vault.

Consequently, **no USDC that TWAPBurner receives ever becomes LUMINA in BondVault**.

## 6.5 Accounting hole: `totalUSDCReceived` is blind to marketplace fees

`receivePremium` (line 114) and `receiveMarketplaceFee` (line 121) both increment `totalUSDCReceived`. But `LuminaBondMarketplace.executeBuy` (line 140) uses `safeTransfer` to push fees to `address(twapBurner)` directly — it does NOT call `receiveMarketplaceFee`. Consequence:

- Marketplace-fee USDC lands in TWAPBurner balance → splits normally on next `executeBurn`.
- But `totalUSDCReceived` counter is NOT incremented for the marketplace leg.
- `MarketplaceFeeReceived` event is never emitted from real on-chain flow.

This is an accounting inconsistency (not a loss of funds), worth filing as a low-severity finding. See FLOW-01 §3.

## 6.6 `recoverToken` guardrails

`src/core/TWAPBurner.sol:382-386`:

```solidity
function recoverToken(address token, uint256 amount) external onlyOwner {
    require(token != address(usdc), "Cannot recover USDC");
    require(token != address(lumina), "Cannot recover LUMINA");
    IERC20(token).safeTransfer(owner(), amount);
}
```

Owner cannot drain USDC (the money channel) nor LUMINA. Owner CAN rescue any accidentally-sent third token. This is a sensible guardrail but means **TWAPBurner itself is also NOT a candidate for a rescue-swap path** — admin cannot redirect the burner's accumulated USDC to BondVault.

## 6.7 Summary

TWAPBurner is the **deflation engine**, not a routing hub to BondVault.

- USDC in → split four ways → three ways exit the protocol, one way swaps-then-burns.
- LUMINA "in" (from swap) never stays — it is burned the same transaction.
- Owner cannot repurpose the USDC for a vault refill.

The question "where does the USDC end up" has FOUR answers after TWAPBurner: DEX pool (paired with destroyed LUMINA), ops wallet, MaintenanceReserve balance, or BuybackEngine (which then pushes to marketplace seller + TWAPBurner fees). BondVault is in none of them.
