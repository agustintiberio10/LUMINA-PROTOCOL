# Audit V5.1 #37 — E2E INTEGRATION — REPORT

## Scope

End-to-end validation of the V5.1 stack across the AI-agent path (API + on-chain) and the human bond-trader path (web + on-chain), closing audit Block 10. The audit cross-references each user journey with the V5.1 contracts that actually exist on Sepolia, flags gaps where the journey assumed primitives the protocol does not implement, and exercises the journeys end-to-end with Foundry tests against the real protocol contracts (only USDC / oracle / DEX / shield are mocks).

Companion documents:

- `01-FLOWS.md` — four user journeys vs. V5.1 reality
- `02-WEB-MANUAL-CHECKLIST.md` — manual browser checklist for the human surface

## Findings

### CRITICAL — none

### HIGH

| # | Title | Location | Status |
|---|---|---|---|
| **LP-GAP** | The "Human LP: deposit USDC → earn yield → withdraw" journey assumed by both the audit-#37 spec and the v0-lumina-landing-page frontend has **no contract surface in V5.1**. `BondVault` exposes only `issueBond` (called by `PolicyManager` on a triggered policy) and `redeemBond` (called by claim-bond holders post-maturity). There is no `deposit`/`initiateWithdrawal`/`completeWithdrawal`. There is also no Aave integration (`AAVE.pool` was a Mainnet V1/V2 address; the audit-35 fix points it at the zero address sentinel). | `src/bonds/BondVault.sol` — function set | OPEN — protocol-roadmap decision required |

This is HIGH severity for **product**, not security: an end user who follows the documented LP flow on the live website cannot complete it. There is no exploitable bug, no funds at risk; the UX is just blocked. Two paths forward:

- **(a)** The V5.1 economic model is intentionally agent-policy-driven (no LP yield). The frontend's "My Vaults" tab should be removed or restated as "My Bonds" and pivot the value-prop messaging.
- **(b)** A future contract release (V5.2 or V6) adds the deposit/withdraw primitives; until then, ship the audit-35 fix with the legacy keys aliased to `BondVault` (which the fix already does) and flag "LP coming soon" in the UI copy.

### MEDIUM — none

### LOW — none

### INFO

| # | Note |
|---|---|
| **WEB-AUTOMATION** | The frontend has no test infrastructure (Playwright / Cypress / Jest). The audit therefore cannot assert browser-side behaviour automatically. Captured as a manual checklist (`02-WEB-MANUAL-CHECKLIST.md`). Recommend adding Playwright + a funded Sepolia wallet on Vercel preview environments in a follow-up PR. |
| **LIVE-API-OPT-IN** | The new `tests/e2e/full-lifecycle.test.ts` in `lumina-api` runs in mock mode by default. The live-Sepolia probes (`/health`, `/products`, `/policies/...`, IDOR check via real key issuance) only run with `RUN_LIVE_TESTS=1` + `LIVE_ADMIN_TOKEN=…`. This matches the existing pattern (`tests/security/e2e-sepolia.test.ts`) and avoids accidental writes from CI. |

## Tests added

### `org-lumina/LUMINA-PROTOCOL` — `test/audit/v5.1-uups/integration/e2e/E2EIntegration.t.sol`

**4 Foundry tests, all passing**, against real V5.1 protocol contracts (LuminaTokenV2, ClaimBond, BondVault, PolicyManagerV2, CoverRouterV2, TWAPBurner, LuminaBondMarketplace) with USDC / oracle / DEX / shield mocked:

| # | Test | Journey covered |
|---|---|---|
| 1 | `test_E2E_AIAgent_FullLifecycle` | Relayer-mediated `purchasePolicyFor` → `settlePolicy` → `BondVault.issueBond` → `BondVault.redeemBond` at maturity. End-to-end from API call to LUMINA in the agent's wallet. |
| 2 | `test_E2E_BondTrader_BuyHoldRedeem` | Seller lists 100 bonds on `Marketplace`, buyer pays USDC + receives bond NFT, buyer holds to maturity, redeems. |
| 3 | `test_E2E_CrossComponent_AgentSellsBonds` | Agent gets bond from triggered policy, lists on marketplace, third party buys it, third party redeems at maturity. Covers the agent → human bond flow end to end. |
| 4 | `test_E2E_GlobalInvariants_HoldAfterFullLifecycle` | After a complete agent-buys + sells lifecycle: total LUMINA supply unchanged (INV-1), policy buyer recorded correctly (INV-3), ClaimBond escrow conservation across `Marketplace.list` and `executeBuy` (INV-5). |

The setUp `vm.warp(1_770_000_000)` (= 2026-02-02) bumps the Foundry default timestamp into a range where the protocol's epoch math (rooted at Jan-2026) operates. Without this warp the bond helpers revert with `Before base`; documented inline in the test fixture.

### `org-lumina/lumina-api` — `tests/e2e/full-lifecycle.test.ts`

**3 mock-mode + 4 live-mode (skipped by default) tests**:

Mock mode (always runs):

- `GET /products` returns 9 active shields (route + service wired)
- admin issues a key, agent uses it to list policies
- INV-1: cross-owner read returns 403

Live mode (`RUN_LIVE_TESTS=1` + `LIVE_ADMIN_TOKEN=…`):

- admin generates a key, key lists empty policies for caller
- public read path is consistent — `/products` has 9 shields
- public read path — known policy id 3 is owned by the founder
- authenticated `GET /api/v1/policies?owner=<other>` returns 403 (post INV-1)

## Verification

```
$ forge test --no-match-contract "Fork"
Suite result: ok. 7 passed; 0 failed; 0 skipped; finished in 26.07s (83.05s CPU time)
Ran 129 test suites in 26.33s (77.54s CPU time): 2122 tests passed, 0 failed, 0 skipped (2122 total tests)
```

```
$ npx jest --forceExit
Test Suites: 1 skipped, 12 passed, 12 of 13 total
Tests:       8 skipped, 96 passed, 104 total
Time:        6.82 s
```

LUMINA-PROTOCOL: **2 122 / 2 122 pass, 0 fail, 0 skip** (2 118 baseline + 4 new E2E).
lumina-api: **96 / 96 pass, 0 fail, 8 skipped** (8 skipped = 4 audit-33 live + 4 audit-37 live, all RUN_LIVE_TESTS-gated).

## Reverse audit

- **Total tests post-#37**: 2 122 contracts + 96 API standard + 8 live (opt-in) = **2 226**.
- **Flujos cubiertos**: 3 of the 4 spec'd flows (Agent, Bond Trader, Cross-Component) are E2E-tested; Flow 2 (Human LP) is documented as protocol-side gap with action item.
- **Quality**: tests touch real protocol contracts at every hop, balances are asserted before/after on every transition, no MockPolicyManager shortcuts where on-chain state matters.
- **−0.5 quality** for the LP-GAP being documented but not resolved (out of audit scope, but it's the dominant operator risk).

## Quality

**9 / 10**

## Verdict

**E2E-VALIDATED for the AI-agent and bond-trader journeys.** The protocol's intended primary flow (API → relayer → on-chain → bond → marketplace → redeem) works end-to-end; the bond-trader resale path works end-to-end; cross-component agent-sells-bond also works.

**The Human LP journey is a documented protocol-roadmap gap (LP-GAP)**, not a security bug. The frontend audit-35 fix already mitigated the immediate symptom (unable to read V5.1 contracts) by aliasing the legacy 5-vault keys to BondVault, but the deposit/withdraw buttons themselves cannot succeed against V5.1 today. This needs a product decision before pre-mainnet (#38–40).

### Action items for the founder before pre-mainnet audits

1. **LP-GAP** — pick path (a) or (b) above. If (a), commit a frontend PR that removes / restates the "My Vaults" tab and updates `lumina-org.com` copy. If (b), set a contract roadmap item.
2. Run the manual web checklist (`02-WEB-MANUAL-CHECKLIST.md`) once the audit-35 fix PR is merged on Vercel.
3. Optionally execute `RUN_LIVE_TESTS=1 LIVE_ADMIN_TOKEN=… npm test -- full-lifecycle` against the live API to exercise the full-fat E2E.
