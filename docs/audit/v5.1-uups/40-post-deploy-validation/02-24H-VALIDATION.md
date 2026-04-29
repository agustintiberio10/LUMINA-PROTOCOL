# 02 — 24-hour validation

After the immediate smoke tests pass, the next milestone is T+24h. The protocol is exposed to real users; this checklist verifies the system handled real traffic without surprises.

## Metrics to monitor (continuous, T+0 → T+24h)

| Metric | Source | Healthy range | Alert threshold |
|---|---|---|---|
| Total policies sold | `PolicyManager.getTotalPolicies()` (or count `PolicyPurchased` events) | 0–unlimited | – |
| Total USDC volume | Sum of `coverageAmount` × premium ratio across `PolicyPurchased` events | 0–unlimited | – |
| Total LUMINA burned | `100_000_000 * 1e18 - LUMINA.totalSupply()` | ≥ 0 | unexpected drop > 1% in 1h |
| Failed triggers (false positives) | Off-chain: shield `_evaluate*` reverts in API logs | 0 expected | > 5 in 1h |
| API error rate | Railway logs `5xx` count / minute | < 1% of total RPS | > 5% sustained |
| API 4xx rate | Railway logs `4xx` count | depends on traffic | > 50% (likely auth issue) |
| Relayer ETH balance | `cast balance $RELAYER --rpc-url $BASE_RPC_URL` | > 0.005 ETH | < 0.001 ETH |
| Deployer ETH balance | same, on the deployer EOA | > 0.001 ETH | < 0.0005 ETH (admin actions blocked) |
| Oracle staleness (BTC, ETH, USDC) | `latestRoundData().updatedAt` vs `now()` | < 6h drift | > 24h drift = oracle dead |

### How to capture each metric

```powershell
# Policies sold + total volume
cast call $env:POLICY_MANAGER "getTotalPolicies()(uint256)" --rpc-url $env:BASE_RPC_URL

# LUMINA total supply (and therefore burns)
cast call $env:LUMINA_TOKEN "totalSupply()(uint256)" --rpc-url $env:BASE_RPC_URL

# Relayer balance
cast balance "0x<RELAYER>" --rpc-url $env:BASE_RPC_URL

# Oracle staleness (BTC example)
cast call 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F `
    "latestRoundData()(uint80,int256,uint256,uint256,uint80)" `
    --rpc-url $env:BASE_RPC_URL
```

For a continuous view, pipe these into a simple polling script that posts to Slack/Discord every 15 minutes during the first 24 hours.

## Action thresholds

### Zero policies sold by T+8h

Not a security issue, but a product/marketing signal. Action:

1. Confirm the API is reachable from the marketing copy's example curl (`/health` returns 200).
2. Confirm lumina-org.com loads cleanly in an incognito window.
3. Confirm `gh issue list` has no user reports stuck on "wallet won't connect".
4. Re-check the Twitter / Discord launch announcement reach.

### API 5xx rate > 5% sustained for 30 min

```powershell
# Railway logs
railway logs --service lumina-api -n 200
```

Common causes (ranked by post-Sepolia frequency):

- **Relayer ran out of gas** — top up.
- **RPC rate limit** (if operator chose a low tier) — upgrade Alchemy/Infura plan.
- **DB volume permission glitch** — restart the service via Railway dashboard.
- **Bug** — pause + investigate (see `05-PAUSE-TRIGGERS.md`).

### Oracle drift > 6h

Chainlink feeds on Base usually update on heartbeats well below 6h. If drift exceeds 6h:

1. Check Chainlink status page (`status.chain.link`).
2. If only one feed is stuck (e.g., USDC/USD): pause **only the shields that consume that feed** (MicroDepegShield consumes USDC/USD).
3. If multiple feeds stuck: likely Chainlink-wide issue, pause CoverRouter (no new policies) but leave existing policies' triggers active — the protocol's own staleness check (audit #18) will reject false triggers.

### Trigger event observed (legitimate or not)

A real depeg / flash crash event will fire `PolicyTriggered`. Verify:

```powershell
# How many bonds were issued?
cast call $env:CLAIM_BOND "totalBonds()(uint256)" --rpc-url $env:BASE_RPC_URL

# Is BondVault solvent?
# (manual check: BondVault balance vs total committed USD)
```

If the trigger looks legitimate (oracle data confirms the event), **do nothing — the system worked as designed**. If the trigger looks suspicious (oracle reads sane but trigger fired), pause that shield via `setPaused(true)` and investigate.

## Acceptance gate (T+24h)

Mark **STABLE-T+24H** if:

- API 5xx rate has stayed < 1% on rolling 1h windows.
- No critical user reports.
- Oracle staleness within bounds throughout.
- `BondVault` token balance hasn't dropped unexpectedly (only legitimate `redeemBond` calls reduce it, and those mature 730 days post-issuance — should be zero in the first 24h).
- LUMINA total supply has only ever decreased (burn), never increased.

If any of those flagged, **do NOT proceed** to the 7-day milestone — escalate per `05-PAUSE-TRIGGERS.md`.

## Founder weekly check-in template (first entry)

Even at T+24h the operator should publish a brief summary so stakeholders track progress. Short version of the template in `REPORT.md` § "Weekly report":

```
LUMINA V5.1 — T+24h
- Policies sold: X
- USDC volume: $Y
- LUMINA burned: Z (= W% of supply)
- Bonds issued: 0 / N
- Triggers: 0 / N
- API uptime: 99.X%
- Issues: [none] OR [bullet list of incidents]
- Next 24h: monitor + …
```
