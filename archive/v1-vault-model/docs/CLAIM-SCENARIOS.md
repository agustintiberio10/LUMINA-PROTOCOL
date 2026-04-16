# Claim Scenarios: When an Insured Agent CANNOT Collect

This document covers every scenario in which a valid-looking insurance policy will **not** pay out. Understanding these edge cases is critical for agents purchasing coverage through Lumina Protocol.

---

## 1. Policy Expired + Grace Period Passed

**What happens:** Every policy has a fixed expiry timestamp. After expiry, a grace period allows claims for events that occurred during coverage but were reported late. Once the grace period elapses, no claim can be filed regardless of when the event occurred.

| Product | Grace Period |
|---------|-------------|
| BlackSwanShield | 24 hours |
| DepegShield | 24 hours |
| ExploitShield | 24 hours |
| ILIndexCover | 48 hours |

If the L2 sequencer was down during part of the grace period, the grace window extends by the duration of the sequencer outage. Once that extension also elapses, the claim window is permanently closed.

**Is it fair?** Yes. Grace periods are generous relative to typical DeFi claim windows. The sequencer extension ensures agents are not penalized for Base network outages. Policies are timestamped on-chain so there is no ambiguity about expiry.

**What the agent can do:**
- Monitor policy expiry dates and set alerts well in advance.
- File claims immediately when an event occurs -- do not wait.
- If the sequencer was down, verify the extension was correctly applied before assuming the window is closed.

---

## 2. Event Occurred During the Waiting Period

**What happens:** Each product has a waiting period after policy purchase during which events are not covered. This prevents agents from buying insurance after they already know an event is happening.

| Product | Waiting Period |
|---------|---------------|
| BlackSwanShield | 1 hour |
| DepegShield | 24 hours |
| ExploitShield | 14 days |
| ILIndexCover | None |

If the covered event begins (or is detected) within the waiting period, the policy will not pay out even if the event continues past the waiting period.

**Is it fair?** Yes. Waiting periods are standard in insurance to prevent adverse selection. The varying durations reflect how predictable each risk type is -- exploit insurance has the longest waiting period because exploits can sometimes be anticipated by insiders.

**What the agent can do:**
- Purchase coverage well before you need it -- do not wait until a risk is imminent.
- For ExploitShield, the 14-day waiting period means coverage should be treated as a long-term hedge, not a reactive purchase.
- ILIndexCover has no waiting period, making it suitable for just-in-time hedging of LP positions.

---

## 3. Event Did Not Reach the Trigger Threshold

**What happens:** Each product requires the insured event to reach a minimum severity before a payout is triggered. Minor fluctuations do not qualify.

| Product | Trigger Threshold |
|---------|-------------------|
| BlackSwanShield | Covered asset must drop **30% or more** from the oracle reference price. A 29% crash pays nothing. |
| DepegShield | USDC must trade **at or below $0.95** (5% depeg). If USDC stays above $0.95, no claim is valid. |
| ExploitShield | A qualifying exploit event must be confirmed by the oracle. Partial losses or soft rug-pulls may not meet the criteria. |
| ILIndexCover | Impermanent loss must exceed the **2% deductible**. IL of 1.9% pays zero. IL of 5% pays on the 3% above the deductible. |

**Is it fair?** Mostly yes. Thresholds keep premiums affordable by filtering out noise. The BSS 30% threshold is aggressive -- a 25% crash is devastating but uncovered. Agents should understand that these products cover tail risk, not everyday volatility.

**What the agent can do:**
- Read the exact trigger parameters before purchasing. They are encoded in the policy NFT metadata and in the shield contract.
- For ILIndexCover, remember the 2% deductible reduces your effective payout. Factor this into your hedge sizing.
- For DepegShield, monitor the 30-minute TWAP (see scenario 6) -- a brief spike below $0.95 that recovers may not trigger.

---

## 4. Payout Vetoed During the Delay Window (Option E)

**What happens:** After a claim is approved by the oracle, there is a mandatory delay before funds are disbursed. During this delay window, the protocol's emergency multisig can invoke **Option E** to veto the payout if it is deemed fraudulent or based on manipulated oracle data.

**Constraints on Option E:**
- Maximum **3 vetoes per week** across all products.
- Can **only** be exercised during the payout delay window -- once the delay expires and funds are released, the payout is final.
- Requires multisig consensus (not a single admin key).

**Is it fair?** This is the most controversial mechanism. It exists as a last-resort defense against oracle manipulation attacks, which could otherwise drain vaults. The 3/week cap and time-bound nature prevent abuse. However, it introduces a trust assumption in the multisig signers.

**What the agent can do:**
- Check the veto history on-chain -- if the multisig has never used Option E, that is a good sign.
- Understand that legitimate claims are extremely unlikely to be vetoed. Option E targets oracle manipulation, not normal market events.
- If your claim is vetoed, the protocol's governance process allows appeals.

---

## 5. IL Below the 2% Deductible at Settlement

**What happens:** ILIndexCover uses a deductible model. The first 2% of impermanent loss is borne by the policyholder. Only IL exceeding 2% is compensated.

**Example:**
- You hold an ETH/USDC LP position and purchase IL coverage for 10,000 USDC notional.
- At settlement, IL is calculated at 1.8%.
- Payout: **$0**. The 1.8% is entirely within the deductible.

If IL were 5%, the payout would cover 3% (5% minus 2% deductible) of the notional value.

**Is it fair?** Yes. The deductible keeps premiums significantly lower. Most LP positions experience small IL fluctuations that are offset by trading fees. The coverage is designed for the scenario where IL becomes genuinely painful (large directional moves).

**What the agent can do:**
- Factor the 2% deductible into your cost-benefit analysis. If you expect IL to stay under 2%, the coverage may not be worth the premium.
- Consider that the deductible is measured at settlement time. IL can fluctuate -- it might exceed 2% mid-period but be below 2% at settlement.
- If possible, time your settlement to coincide with maximum divergence, not a temporary recovery.

---

## 6. Depeg Recovers Before the 30-Minute TWAP Confirms

**What happens:** DepegShield does not trigger on instantaneous price. It requires USDC to remain at or below $0.95 for long enough that the **30-minute time-weighted average price (TWAP)** confirms the depeg. If USDC briefly dips to $0.94 but recovers to $0.96 within minutes, the TWAP may never breach $0.95 and no payout occurs.

**Why TWAP?** Instantaneous prices on DEXs can be manipulated with flash loans or large swaps. The 30-minute TWAP is far more expensive to manipulate and ensures only genuine, sustained depegs trigger payouts.

**Is it fair?** Yes. A momentary dip that self-corrects in minutes is not a real depeg -- LPs and holders suffer no lasting damage. The TWAP protects vault LPs from paying out on manipulated or transient price data.

**What the agent can do:**
- Understand that DepegShield protects against sustained depegs, not flash crashes.
- Monitor the TWAP feed (available from LuminaOracle at `0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87`) to see when it is approaching the threshold.
- If a genuine depeg is occurring, the 30-minute window will confirm it -- there is no action needed from the policyholder other than filing the claim within the grace period.

---

## Summary Table

| # | Scenario | Products Affected | Agent Action |
|---|----------|-------------------|--------------|
| 1 | Expired + grace period passed | All | Set expiry alerts, claim immediately |
| 2 | Event during waiting period | BSS, Depeg, Exploit | Buy coverage early |
| 3 | Below trigger threshold | All | Read trigger params before buying |
| 4 | Option E veto | All | Check veto history, trust the process |
| 5 | IL below 2% deductible | ILIndexCover only | Factor deductible into sizing |
| 6 | TWAP recovery | DepegShield only | Understand TWAP vs. spot distinction |
