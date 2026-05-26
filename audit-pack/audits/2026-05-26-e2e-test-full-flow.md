# E2E Complete Test — Shield Mock + Full Flow Validation

**Date:** 2026-05-26
**Network:** Base Sepolia (chainId 84532)
**Scope:** End-to-end on-chain validation of the full parametric-insurance
lifecycle — purchase → trigger → settle → bond mint → maturity → redeem → LUMINA
payout — exercised against a *parallel* FLASHBTC1H shield wired to a
**controllable mock Chainlink oracle**, so a real flash-crash trigger can be
forced on testnet (live shields read real Chainlink feeds and cannot be faked).
**Methodology:** Founder-driven autonomous sprint; cast/forge against live V5.4
proxies; every state change captured on-chain. **Verdict: PASS — full flow
validated, 6/6 invariants hold.**

> ⚠️ **MAINNET BLOCKER.** `MockChainlinkOracle` and the mock shield/adapter/
> product (`FLASHBTC1H-MOCK-001`) are **testnet-only test infrastructure**. They
> MUST NOT be deployed to mainnet and the product MUST NOT be registered there.
> `src/test-helpers/MockChainlinkOracle.sol` is self-flagged as a mainnet blocker.

---

## 1. Mock infrastructure deployed (Phases B–C)

| Component | Address | Notes |
|---|---|---|
| MockChainlinkOracle | `0xC1A7A51FD3c932c37Ead53EF45F05C99C8686183` | Owner-settable; 8-dec; init $60 000; `setPrice` bumps round + `updatedAt` |
| MockShield (FlashBTCShield1h proxy) | `0x7f3D1dD0f618189A75230B0b0c4B717676328ae7` | router=adapter, priceFeed=mock, sequencer=address(0) |
| MockAdapter (FlashShieldAdapter proxy) | `0x0561183BfC5e46B234771A090c6EAa0EA542acbF` | keeper=relayer=founder |
| MOCK_PRODUCT_ID | `0x9e5eef0246141001c5c5fd5b26e0e535feba813bf6dda8e0ea316e39c4042a1a` | keccak256("FLASHBTC1H-MOCK-001") |

Registered in PolicyManagerV2 (`registerProduct`) and configured in CoverRouterV2
(`configureProduct`: payoutRatioBps=8000, triggerProbBps=18, marginBps=20000,
durationSeconds=3600, active=true). Deploy script: `script/deploy/E2EMockSetup.s.sol`.

The flow touches the **live canonical V5.4** contracts unchanged: PolicyManagerV2
`0x546C…cDd8`, CoverRouterV2 `0xcdB7…F566`, BondVault `0x193a…B6EC`, ClaimBond
`0xaa57…1FB4`, TWAPBurner `0x242d…1bC0`, AdaptiveFeeDistributor `0xeC78…9D54`,
CapacityOracle (LUMINA price) `0xd52a…6545`, LUMINA `0x62C0…6680`, mUSDC `0xD944…6AE`.

---

## 2. Two test cycles

The flash-shield bond's maturity **epoch is fixed at mint time** from
`bondMaturitySeconds` (ClaimBond `maturityDate[epochId]` has no setter). Therefore
`setBondMaturitySeconds(60)` only makes a bond redeemable if set **before**
issuance. Two cycles were run to cover both ends:

### Cycle 1 — policy 1, DEFAULT maturity (730 days)
Demonstrates the real mainnet maturity path. Bond minted into a 2-year-out epoch,
correctly **not** redeemable today.

| Step | Value |
|---|---|
| Coverage / strike | $100 / $60 000 |
| Premium / payout | $0.288 / $80 (80% — 20% deductible) |
| Trigger | price → $57 000 (5% drop > 2.5% barrier); 3 spaced confirmations |
| Bond | epoch **202805**, 80 tokens, `maturityDate`=2028-05, `matured=false` (locked ✓) |
| conf #1 tx | `0x62c2a5c528d2a70be304d75acd2b33f3102024f19a58949cbef9aa1088750797` |

### Cycle 2 — policy 2, 60s maturity (redeem path)
`setBondMaturitySeconds(60)` set **first**; oracle reset to $60 000 so the new
policy strikes at par.

| Step | Value | Tx |
|---|---|---|
| `setBondMaturitySeconds(60)` | bondMaturitySeconds 730d → 60s | — |
| Reset oracle $60k | round 10, $60 000 | `0x382201e20e28cd52b9583bcd0bb39fa56ca132781b1e5e8c34499225a0ae9d04` |
| Purchase $100 | strike $60k, premium $0.288, payout $80 | `0x17e8f4325f8e5213b52fa560878910b95fcfb00426c5fbf3e53ca75c710ca569` |
| Dwell | 300s (`MIN_DWELL_PERIOD`) waited out | — |
| Trigger | price $57 000; 3 spaced confirmations → `finalized=true` | — |
| Bond | epoch **202605**, 80 tokens, `maturityDate`=2026-05-01, **`matured=true`** | — |
| **Redeem** `redeemBond(202605, 80)` | 80 bonds → **2222.2222 LUMINA** @ $0.036 | `0xddea41428e3b1f2083cc2e2088aa049d2326636ccb0a90e934cf2e695cdaf9cf` |

---

## 3. Trigger mechanics validated (F-01)

- **Multi-block confirmation:** 3 sub-barrier observations, each in a distinct
  block, ≥60s apart (`CONFIRMATION_INTERVAL`), each requiring a newer oracle round
  (`updatedAt > lastUpdatedAt`). Accrual persists across calls; only the 3rd
  observation returns `triggered=true`.
- **Dwell gate:** `DWELL_NOT_ELAPSED` enforced for the first 300s after policy
  start (verified on policy 2).
- **Deductible:** payout = coverage × (10000 − 2000)/10000 = **80%**.
- **Adapter remapping:** oracle-read reverts → `ORACLE_UNAVAILABLE`; spacing/dwell
  rejections → `NOT_SETTLEABLE_YET` (never a blind `finalized=false`).

---

## 4. Per-contract impact

| Contract | Effect observed |
|---|---|
| MockChainlinkOracle | price driver; `setPrice` round/`updatedAt` bumps drove barrier breach |
| MockShield | policy lifecycle, F-01 confirmation accrual, `_finalizeTriggered` |
| MockAdapter | keeper-driven `checkAndSettlePolicy` → `settlePolicy`; revert remap |
| PolicyManagerV2 | `recordPolicy`; `settlePolicy(true)` → `issueBond`; `totalTriggers++`, `activePolicies--` |
| CoverRouterV2 | premium = coverage×8000×18×20000/1e12 = $0.288; 100% routed to TWAPBurner |
| TWAPBurner | `receivePremium` ×2 → mUSDC balance +$0.576 (7 568 000 → 8 144 000) |
| BondVault | `issueBond` (epoch from `bondMaturitySeconds`); `redeemBond` immediate path; committed accounting; `setBondMaturitySeconds` |
| ClaimBond | ERC-1155 mint (epoch 202805 + 202605) / burn on redeem |
| CapacityOracle | `getLuminaPrice` = $0.036 used for redeem |
| LUMINA token | reserve transfer vault → founder (2222.22) — **not minted** |
| AdaptiveFeeDistributor | split config validated (not exercised by this flow) |

---

## 5. Invariants (Phase L) — 6/6 PASS

| # | Invariant | Result |
|---|---|---|
| 1 | LUMINA totalSupply unchanged (redeem = transfer, not mint) | 100 000 000 → **100 000 000** ✓ |
| 2 | Fee split sums to 100% | `getDistribution` mLevel-1 = (8500,800,200,500) = **85/8/2/5 = 10000** ✓ |
| 3 | Bond burned on redeem | epoch 202605: 80 → **0** ✓ |
| 4 | Correct payout | $80 face → 80×1e36/3.6e16 = **2222.2222 LUMINA** ✓ |
| 5 | Obligation released at pay time | `totalCommittedUSD` $160 → **$80** (policy-2 $80 freed; policy-1 still committed) ✓ |
| 6 | Premium routing 100% → TWAPBurner | 2 × $0.288 = **+$0.576** ✓ |

Balances: founder LUMINA 5 000 000 → **5 002 222.2222** (Δ +2222.2222); vault
reserve 70 000 000 → 69 997 777.7778 (Δ −2222.2222). LUMINA price $0.036 > floor
$0.005; $80 well under epoch + per-user redemption caps → immediate (un-throttled).

---

## 6. Findings

- **F-1 (Info, test-harness):** `BaseFlashShield._currentPrice2` computes
  `block.timestamp - updatedAt`. When a `setPrice` is immediately followed by
  `checkAndSettlePolicy`, a lagging public-RPC node can evaluate the call against
  a block whose `block.timestamp` is *earlier* than the just-set `updatedAt`,
  underflowing → revert → remapped to `ORACLE_UNAVAILABLE`. **Not a contract bug**
  (real Chainlink `updatedAt` is always in the past); a mock-only timing artifact.
  Mitigation: ~25–28s propagation delay between `setPrice` and settle.
- **F-2 (Process):** `setBondMaturitySeconds` must be set **before** bond issuance
  to influence the maturity epoch (epoch fixed at mint). Sprint Phase-I ordering
  (after mint) does not retro-apply — hence the two-cycle design.
- **Gas:** negligible (< 0.001 ETH total across ~30 txs on Base Sepolia).

## 7. Standing items (carried, founder action)

- **Rotate the 2 exposed founder private keys** (used as deployer/keeper here).
- **Faucet relayer `0x168dC7…7E4a` is out of ETH** (needs ~0.05 ETH/claim).
- **Remove mock infra before mainnet** (see top blocker).

**Verdict: PASS.** The complete purchase→trigger→settle→bond→mature→redeem flow
executed end-to-end on Base Sepolia with all economic and accounting invariants
intact.
