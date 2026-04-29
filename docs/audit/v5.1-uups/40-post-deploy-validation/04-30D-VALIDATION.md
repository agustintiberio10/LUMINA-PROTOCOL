# 04 — 30-day validation

T+30d is the first month of real operation. By this point the protocol has either proven itself or has revealed scaling pain. This is the moment to make the **structural decisions** that audit #40 deliberately deferred.

## Decisions due at T+30d

### 1. Multisig + Timelock installation

Per the founder note (2026-04-28), governance was deferred. After 30 days of clean operation, install:

| Step | What | Approx. cost (Base) |
|---|---|---|
| 1 | Deploy Gnosis Safe (2-of-3 recommended: founder + audit lead + ops) | $4 |
| 2 | Transfer ownership of every UUPS proxy from deployer EOA → Safe | $2 (16 contracts × ~$0.13) |
| 3 | (Optional but recommended) Deploy `TimelockController` with a 24h or 48h delay | $1.50 |
| 4 | Transfer Safe ownership to the Timelock; Safe becomes a proposer-only role | $2 |
| **Total** | | **~$10 USD** |

Procedure mirrors the post-deploy ownership-transfer pattern in `script/deploy/DeployLuminaV5Sepolia.s.sol:461-477` — for each contract:

```powershell
cast send $env:CONTRACT "transferOwnership(address)" $env:NEW_SAFE `
    --rpc-url $env:BASE_RPC_URL --private-key $env:DEPLOYER_PRIVATE_KEY
```

If `transferOwnership` is two-step (OpenZeppelin's `Ownable2StepUpgradeable`), the Safe must `acceptOwnership()` from a Safe transaction.

**Decision criteria:**

- Was the EOA used for any incident response in 30 days? (PAUSE, upgrade, etc.)
- Is the deployer key still in cold storage and unrotated?
- Is there a clear roster of who holds each Safe signer key?

If "yes / yes / yes" → install. If any "no" → document why and defer to T+60d.

### 2. External audit engagement

The 40 in-house audits cover an enormous breadth, but professional firms (Trail of Bits, Zellic, OpenZeppelin, CertiK, Spearbit) bring orthogonal eyes and a name on the report that institutional users want to see.

| Tier | Provider examples | Approx. cost | Time |
|---|---|---|---|
| Spot audit (focused, ~2 weeks) | Spearbit Cantina contests, Zellic ad-hoc | $20k–$40k | 2–4 weeks |
| Full audit (4–6 weeks) | Trail of Bits, Zellic, OpenZeppelin | $80k–$150k | 6–10 weeks |
| Premium + retainer | ToB / OZ multi-year | $200k+ | ongoing |

**Decision criteria:**

- TVL at T+30d: if > $500k, full audit recommended before any further marketing push.
- Founder runway: if < 6 months, spot audit acceptable as gate to a longer one later.
- User profile: if any user is institutional / regulated, full audit is non-negotiable for them.

### 3. Bug bounty pool

Open a public bug bounty (Immunefi is the standard for DeFi) sized by TVL.

| TVL bracket | Recommended pool size |
|---|---|
| < $100k | $5k–$10k (small Immunefi tier) |
| $100k–$1M | $25k–$50k |
| $1M–$10M | $100k+ |
| > $10M | $250k+, with severity tiering |

Alternative: HackerOne / individual researcher engagements if you prefer ad-hoc.

**Decision criteria:**

- Has any responsible disclosure happened in 30 days? If yes, a bounty makes future disclosure easier.
- Are there CRITICAL surface areas not yet covered by audits 1–40 (e.g., the relayer's TLS config, the API admin endpoints)? Bounty closes those gaps cheaply.

### 4. Roadmap pivot — V5.2 / V6

By T+30d you'll know which products users actually use. Audit #37 documented the LP-GAP (the human LP flow has no contract surface). Decisions:

| Path | What it is | When |
|---|---|---|
| **(a) Ship as agent-only** | Drop "My Vaults" from the frontend permanently; restate value prop as agent-policy-driven | If LP demand stays < 5% of policy demand |
| **(b) Build LP primitives** | Add `deposit/withdraw` to a new `LiquidityVault` contract; integrate with Aave | If users repeatedly ask for yield-on-USDC |
| **(c) Cross-chain** | Deploy V5.2 to Arbitrum / Optimism in addition to Base | If users on other L2s ask for it |
| **(d) New product types** | Currently 9 shields. Add (e.g.) FX volatility shield, GAS price shield, etc. | Based on user feedback |

These are product calls, not security calls. The audit can't decide for the founder.

## Trends to evaluate (T+30d)

Same metrics as `03-7D-VALIDATION.md` but over a 30-day window. Specifically:

- **Policy retention**: of users who bought once, how many bought again? < 20% means the product isn't sticky.
- **LUMINA price** (off-chain DEX): tracked vs. burn rate. The deflationary mechanism should have visible effect by month 2 if volume is meaningful.
- **Gas drift**: any per-action gas baseline that's now > 50% above the audit-#38 reference is a red flag — file an issue and investigate.
- **Bond redemption first month**: should be 0 (bonds mature 730 days post-issuance).

## Checklist

- [ ] Installed Multisig (or documented decision to defer)
- [ ] Engaged external audit firm (or documented decision to defer)
- [ ] Opened bug bounty (or documented decision to defer)
- [ ] Decided LP roadmap (a/b/c/d above)
- [ ] Published 30-day report (template in `REPORT.md` § "Weekly report — extended monthly version")
- [ ] Updated `deployments/mainnet/V5.1-<date>.json` with any post-deploy ownership changes (Safe, Timelock)

## Acceptance gate (T+30d)

Mark **GRADUATED-V5.1** if:

- Decisions 1–4 above are documented (each as YES/NO/DEFER with reasoning).
- No CRITICAL incident in 30 days; HIGH bugs (if any) have fixes deployed via UUPS upgrade.
- API uptime > 99.5% averaged over the month.
- Solvency ratio < 70% throughout.

If GRADUATED, the protocol moves out of "early operation" mode and into "steady state" — the cadence of `MainnetHealthCheck.t.sol` (PARTE 5) drops from daily to weekly, the weekly report cadence from weekly to monthly.
