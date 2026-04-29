# 03 — 7-day validation

T+7 days is the window where the system has seen enough traffic for trends to emerge. Where the 24h check is "did anything explode", the 7-day check is "does the protocol behave the way we modelled it".

## Trends to compute

Pull these from the on-chain event history (BaseScan API or `cast logs`) and from the Railway log archive:

| Trend | Window | Healthy shape | Anomaly |
|---|---|---|---|
| Policies / day | rolling 7d | growth or plateau | sudden drop > 80% in one day |
| USDC volume / day | rolling 7d | tracks policies | spike that does not match policy count |
| LUMINA burn / day | per day | matches USDC volume × ratio | far below expected = TWAPBurner stuck |
| Trigger count / day | per day | shield-dependent | > 1 spurious trigger / day on any shield |
| API p95 latency | rolling 7d | < 500ms | > 1500ms sustained |
| API p99 latency | rolling 7d | < 1500ms | > 5000ms sustained |
| Relayer txs / day | per day | matches API policy purchases | mismatch = relayer dropping txs |
| Gas used / tx (avg) | per day | within ±10% of audit-#38 baseline | > 30% above baseline |

### Computing burn / day

```powershell
# Total supply daily snapshot
cast call $env:LUMINA_TOKEN "totalSupply()(uint256)" `
    --rpc-url $env:BASE_RPC_URL --block latest

# Subtract the snapshot from yesterday's value (operator should keep a daily log)
```

Expected math: USDC volume × (1 − burner-fees-percent) ≈ daily burn measured in LUMINA after the swap. If burns are an order of magnitude below volume, the TWAPBurner is either stuck on `minOut` or hasn't executed because the buffer hasn't filled. Check:

```powershell
cast call $env:TWAP_BURNER "lastSwapTimestamp()(uint256)" --rpc-url $env:BASE_RPC_URL
cast call $env:TWAP_BURNER "buffered()(uint256)"             --rpc-url $env:BASE_RPC_URL
```

If `buffered` is high but `lastSwapTimestamp` is hours stale, the swap conditions are not being met (Uniswap pool depth issue, oracle deviation guard tripping, etc.). Investigate before considering manual `forceSwap()` from owner.

### Gas trends

Audit-#38 measured the deploy at 65 696 108 gas. Per-action gas baselines (from audit-#37 E2E):

| Action | Expected gas | Source |
|---|---|---|
| `purchasePolicyFor` (FlashBTC1h) | ~280 000 | E2EIntegration.t.sol |
| `redeemBond` | ~80 000 | E2EIntegration.t.sol |
| `Marketplace.list` | ~120 000 | E2EIntegration.t.sol |
| `Marketplace.executeBuy` | ~180 000 | E2EIntegration.t.sol |
| `BondVault.issueBond` (callback from PolicyManager on trigger) | ~150 000 | audit-#16 stress |

If the live mainnet readings are consistently > 30% over those baselines, the most likely cause is a hot-path storage write that wasn't anticipated (e.g., a mapping whose first-time write costs 20 000 gas more than subsequent writes). Not a bug, but worth noting in the weekly report.

## Anomaly detection — triggers

The biggest correctness signal in the first week is **trigger count vs. expected market behaviour**.

For each shield, plot triggers fired per day vs. the underlying market move (Chainlink price change). Expected:

- **FlashBTC1h** — fires on >2.5% BTC drop in 1h. Should fire ~once per quarter under historical conditions; in a flat week, expect 0.
- **FlashBTC4h** / **FlashBTC24h** / **FlashBTC48h** — wider windows, threshold scales. Expect 0–1 per week each in calm market.
- **FlashETH1h** / **24h** / **48h** — same shape as BTC.
- **MicroDepegShield** — fires on USDC < $0.99. Should fire 0 times in a normal week.
- **RateShockShield** — fires on Aave variable-borrow-rate spikes. Sensitivity tuned in audit-#12.

If a shield fires when the market did NOT do the threshold move, the oracle data the shield read disagrees with the off-chain market — most likely a stale `latestRoundData` or a manipulated round. Pause that shield; investigate.

If a shield does NOT fire when the market clearly did the threshold move, the shield's evaluator is broken — pause CoverRouter (no new policies) and investigate before the market reverses.

## Solvency check (manual)

The protocol is solvent iff:

```
sum(BondVault.issueBond commitments) <= reserves * SAFETY_FACTOR
```

V5.1 doesn't expose a single `totalCommittedUSD()` getter on BondVault directly; you can derive it from `ClaimBond.totalBonds()` × the configured per-bond face value ($1 each). Reserves are LUMINA in BondVault.

```powershell
cast call $env:CLAIM_BOND "totalBonds()(uint256)" --rpc-url $env:BASE_RPC_URL
# Each bond = $1 USD obligation, redeemable in LUMINA at $0.10/LUMINA target

cast call $env:LUMINA_TOKEN "balanceOf(address)(uint256)" $env:BOND_VAULT `
    --rpc-url $env:BASE_RPC_URL
# If totalBonds * 10 LUMINA > BondVault balance, vault is technically under-reserved
```

Audit-#16 stress tests showed the 70M LUMINA in BondVault covers up to 7M bonds at the $0.10 target price, which is comfortable for the first weeks. If `totalBonds` ever crosses 5M (70% of capacity), trigger an alert — at 6M (85%) the founder should consider topping up reserves or pausing high-risk products.

## User feedback aggregation

Pull from:

- Twitter mentions of `@lumina` and `lumina.org`
- Discord #help and #bugs channels
- API logs filtered for repeated 4xx from same IP (signals UX confusion)
- GitHub Issues opened against `lumina-api` and `LUMINA-PROTOCOL`

Themes to track:

| Theme | Example | Action |
|---|---|---|
| "Wallet won't connect" | RainbowKit silent failure | check WC project ID hasn't been rate-limited |
| "Tx pending forever" | relayer dropped a tx | check relayer logs; resubmit if needed |
| "I can't redeem" | `BondVault.redeemBond` reverts (bond not yet matured?) | reply with maturity date |
| "Refund?" | user bought wrong policy | not supported — clarify in docs |

## Acceptance gate (T+7d)

Mark **STABLE-T+7D** if:

- API uptime > 99.5% over the week.
- No CRITICAL or HIGH severity bugs reported.
- Trigger anomalies = 0 (no false positives, no missed events).
- Solvency ratio `totalBonds / reserve_capacity` < 50%.
- No PAUSE was triggered (or, if it was, the cause was identified and the unpause is documented).

If a PAUSE happened mid-week and was never resolved, the system is NOT stable — escalate.

## Decisions to make at T+7d

| Decision | Question | Default if no answer |
|---|---|---|
| Increase user limits | Should the per-user policy cap be raised? | Keep current |
| Raise marketing budget | Did acquisition meet target? | Keep current |
| Bug bounty | Open Immunefi / HackerOne program? | Defer to T+30d |
| External audit pre-public-launch | Engage Trail of Bits / Zellic / CertiK? | **Strong recommend**: yes, even if 8 weeks out |
