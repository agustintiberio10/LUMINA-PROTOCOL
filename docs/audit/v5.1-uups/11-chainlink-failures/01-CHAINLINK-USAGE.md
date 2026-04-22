# V5.1 Chainlink Usage Inventory

**Audit:** V5.1 #11 — Chainlink Failure Modes
**Branch:** `audit/v5.1-11-chainlink-failures`
**Date:** 2026-04-22

---

## 1. Where Chainlink is consumed

LUMINA V5.1 uses **one** external oracle interface (`IOracle`) which is
implemented in the protocol's deployed oracle contract. That
implementation is expected to wrap Chainlink feeds and add a sequencer-
uptime check (per `IOracle.getSequencerDowntime`).

### 1.1 Entry points that call `IOracle.getLatestPrice(asset)`
- `FlashBTCShield1h / 4h / 24h / 48h._doCreatePolicy` — reads `BTC` price.
- `FlashETHShield1h / 24h / 48h._doCreatePolicy` — reads `ETH` price.
- `MicroDepegShield._checkTriggerCondition` — reads stablecoin price.
- `FlashBTCShield*._checkTriggerCondition` — reads current `BTC` price.
- `FlashETHShield*._checkTriggerCondition` — reads current `ETH` price.

### 1.2 Entry points that call `IOracle.verifySignature` + `IOracle.oracleKey`
- `BaseShield._verifyPriceProofEIP712` — validates the off-chain-signed
  price proof used at settlement time. The proof contains
  `(price, asset, verifiedAt, signature)` signed by the oracle key.

### 1.3 Entry points that call `IOracle.getSequencerDowntime`
- `BaseShield._validateStatusForTrigger` — extends the cleanup window by
  the sequencer downtime since the policy's `expiresAt`.

### 1.4 Non-shields
- `CapacityOracle.getLuminaPrice` — reads Uniswap V3 pool directly (NOT
  Chainlink). Falls back to `emergencyPrice` if the pool reverts or
  returns zero. Out of scope for this audit.
- `RateShockShield` — reads Aave V3 variable borrow rate (NOT Chainlink).
  Out of scope.

---

## 2. In-protocol validation of oracle return values

### `getLatestPrice` consumers

| Callsite | Revert condition | Graceful fallback |
|----------|------------------|-------------------|
| `*Shield._doCreatePolicy` | `price <= 0` → revert `InvalidOracleProof()` | — |
| `MicroDepegShield._checkTriggerCondition` | — (returns false if `price <= 0`) | ✅ view-safe |
| Flash*BTCShield `_checkTriggerCondition` | — (returns false if `price <= 0`) | ✅ view-safe |
| Flash*ETHShield `_checkTriggerCondition` | — (returns false if `price <= 0`) | ✅ view-safe |

### `verifySignature` + EIP-712 proof consumers

| Callsite | Revert condition |
|----------|------------------|
| `*Shield._doVerifyAndCalculate` | `!_verifyPriceProofEIP712` → `InvalidOracleProof()` |
| `*Shield._doVerifyAndCalculate` | `block.timestamp > verifiedAt + MAX_PROOF_AGE` → `ProofTooOld` |
| `*Shield._doVerifyAndCalculate` | `verifiedPrice <= 0` → `InvalidOracleProof()` |
| `*Shield._doVerifyAndCalculate` | `verifiedAt < waitingEndsAt OR > expiresAt` → `EventAfterExpiry` |
| `*Shield._doVerifyAndCalculate` | `proofAsset != data.asset` → `AssetMismatch` |

**MAX_PROOF_AGE** — 900 s (15 minutes) — hard-coded in every shield.

### `getSequencerDowntime` consumer

| Callsite | Behaviour |
|----------|-----------|
| `BaseShield._validateStatusForTrigger` | `adjustedCleanupAt = cleanupAt + downtime`. Settlement blocked only after `block.timestamp >= adjustedCleanupAt`. If `downtime = 0` (normal), policy behaves standardly. |

---

## 3. Chainlink failure modes and how the protocol responds

| # | Failure mode | Current behaviour | Mitigation present |
|---|--------------|-------------------|--------------------|
| 1 | Feed returns `0` | `_doCreatePolicy` reverts; `_checkTriggerCondition` returns false | ✅ |
| 2 | Feed returns negative `int256` | Same as #1 | ✅ |
| 3 | Feed stale (past staleness threshold) | Depends on oracle wrapper's internal check (NOT handled in Shield itself) | ⚠️ External responsibility |
| 4 | Feed paused / round deprecated | Wrapper must revert; Shield handles revert via graceful path (view) or reverts (createPolicy) | ⚠️ Partial |
| 5 | Feed extreme outlier price | **NO sanity bounds in Shield** — protocol accepts the price | ❌ Documented INFO |
| 6 | Sequencer down (Base L2) | `getSequencerDowntime` extends cleanup window; policies remain valid during downtime | ✅ |
| 7 | EIP-712 proof too old | `ProofTooOld(verifiedAt, now)` revert; `MAX_PROOF_AGE = 900s` | ✅ |
| 8 | EIP-712 proof with 0 price | Revert `InvalidOracleProof()` | ✅ |
| 9 | Proof asset mismatch | Revert `AssetMismatch(policyAsset, proofAsset)` | ✅ |
| 10 | Proof verifiedAt outside policy window | Revert `EventAfterExpiry(policyId, verifiedAt, expiresAt)` | ✅ |
| 11 | Oracle reverts | Shield `_doCreatePolicy` bubbles revert; `_checkTriggerCondition` bubbles revert | ⚠️ No try/catch wrapper |

---

## 4. Recommendations (also in `REPORT.md`)

1. **Staleness check in getLatestPrice wrapper.** The oracle implementation
   MUST check `updatedAt >= block.timestamp - STALENESS_THRESHOLD`. Wrap
   Chainlink's `latestRoundData` and enforce this inside the oracle, not
   the Shield.
2. **Sanity bounds.** Each asset should have `MIN_PRICE` and `MAX_PRICE`
   bounds. A spot read outside bounds should revert inside the oracle.
3. **Sequencer uptime.** `IOracle.getSequencerDowntime` exists and is
   consumed by `BaseShield._validateStatusForTrigger`. The wrapper must
   implement this using Chainlink L2 Sequencer Uptime Feed.
4. **Circuit breaker.** Consider adding a `CapacityOracle.setEmergencyPrice`
   style fallback for shield prices — if Chainlink fails, use an admin-
   provided emergency price to allow graceful degradation rather than
   full lockout.
5. **Multi-oracle.** Future versions could read from multiple sources
   (Chainlink + Pyth + RedStone) and use median — protects against any
   single source failure.

---

See `REPORT.md` for tests and verdict.
