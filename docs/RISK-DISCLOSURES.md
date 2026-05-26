# Risk Disclosures

> **Status: TESTNET.** LUMINA is currently live only on Base Sepolia (chainId
> 84532) using **mock USDC** with no real economic value. Nothing in this
> document is investment, financial, or legal advice. Mainnet launch is gated on
> external audit, multisig custody, and a live bug-bounty program (see
> [`audit-pack/audits/2026-05-26-tier1-assessment.md`](../audit-pack/audits/2026-05-26-tier1-assessment.md)).

This document summarizes the material risks of using the LUMINA protocol. It is
deliberately blunt. Read it before interacting with any LUMINA contract or API.

## 1. Smart-contract risk
The contracts are upgradeable (UUPS proxies). They have been reviewed
**internally and with AI-assisted tooling only** (Slither, Echidna, Halmos,
Mythril, manual review) — there is **no completed third-party audit** as of this
writing. Bugs, including in upgrade logic, may cause partial or total loss.
Owner/admin keys are currently a single EOA, not a multisig; key compromise
would compromise the protocol.

## 2. Oracle risk
Triggers and redemption pricing depend on Chainlink price feeds and the
LUMINA price oracle. A stale, manipulated, or unavailable feed can prevent a
legitimate trigger, delay settlement, or block redemption. The shields enforce
staleness windows, sequencer-uptime checks, and a multi-block confirmation
gate, but these mitigations are not infallible.

## 3. Liquidity & solvency risk
Payouts are issued as ClaimBonds (ERC-1155, USD-denominated) redeemable for
$LUMINA at maturity (~730 days). The BondVault enforces a solvency floor and a
per-epoch redemption throttle. If many bonds are redeemed at once, redemptions
are **queued** (FIFO) and paid as capacity allows — you may not be able to
redeem the full face value immediately.

## 4. Token-price risk
ClaimBonds pay out a fixed **USD** face value converted to $LUMINA **at the
redemption price**. If the $LUMINA price falls between trigger and redemption,
you receive more tokens for the same USD value, but the realizable value of
those tokens depends on $LUMINA market liquidity, which may be thin. A hard
price floor (`MIN_REDEEM_PRICE`) applies; below it, redemption is paused.

## 5. Parametric / basis risk
LUMINA is **parametric** insurance: it pays out when a predefined on-chain
condition is met (e.g. "BTC drops ≥2.5% within 1h"), **not** when you
subjectively suffer a loss. The payout may not match your actual loss, and a
real loss may not trigger a payout if the parameter is not breached. A 20%
deductible applies (payout = 80% of coverage).

## 6. Regulatory risk
Parametric insurance / risk-transfer products may be regulated differently
across jurisdictions. LUMINA may not be available to, or appropriate for, you.
You are responsible for your own legal/tax compliance.

## 7. Operational risk
The API, relayer (gas sponsorship), faucet, and indexer are operated services
that can be paused, rate-limited, or go offline. The relayer holds testnet ETH
for gas sponsorship; if it runs dry, gas-sponsored purchases fail until refunded.

## 8. Testnet-specific
- Mock USDC and a permissionless faucet are testnet-only and **will not** exist
  on mainnet.
- Testnet contract addresses, parameters, and product sets may change without
  notice. Always resolve addresses at runtime from `GET /health`.

---

For the protocol's own honest self-assessment of maturity, see the
[Tier-1 Readiness Assessment](../audit-pack/audits/2026-05-26-tier1-assessment.md)
and [`audit-pack/what-is-pending.md`](../audit-pack/what-is-pending.md).
