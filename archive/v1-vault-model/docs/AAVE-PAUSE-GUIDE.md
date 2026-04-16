# Aave Pause Guide for Lumina LPs

## What This Is About

Lumina Protocol vaults deposit idle USDC into Aave v3 on Base to earn supplemental yield for LPs. Aave has the ability to pause its lending markets in response to emergencies (oracle failures, exploits, governance actions). This guide explains what happens to your vault position if Aave pauses, and what you should do.

**Short answer: your capital is safe. Do nothing and wait.**

---

## What Happens When Aave Pauses

### Deposits Fail

When Aave is paused, the vault cannot supply new USDC to Aave. This means:

- New LP deposits into Lumina vaults will still work, but the deposited USDC stays in the vault contract instead of being forwarded to Aave.
- The vault continues to function normally for all other purposes.
- You earn no Aave yield on the idle portion during the pause, but you still earn your share of insurance premiums.

### Withdrawals Queue

If the vault needs to pull USDC from Aave to fulfill a withdrawal (because the vault's liquid USDC buffer is insufficient), the withdrawal enters a queue:

- Your withdrawal request is recorded on-chain.
- It will be processed automatically once Aave unpauses and the funds can be retrieved.
- You do **not** lose your place in line. The queue is first-in-first-out.
- Your vault shares continue to accrue premium yield while queued.

### Payouts Queue

If a valid insurance claim is approved but the vault cannot retrieve enough USDC from Aave to cover the payout:

- The payout enters the same queue mechanism.
- Policyholders will receive their funds once Aave unpauses.
- The payout delay timer is extended accordingly -- no policyholder loses their claim due to an Aave pause.

### Your Capital Is Safe

This is the most important point. Aave pausing does **not** mean funds are lost. Pausing is a safety mechanism that **prevents** withdrawals temporarily to protect against a broader issue. Historically, every Aave pause has been resolved within hours to days, and all deposited funds have been fully recoverable.

Lumina vaults only deposit into Aave's USDC pool on Base, which is one of the most liquid and battle-tested pools in DeFi.

---

## Historical Context

Aave has paused markets on several occasions across its deployments:

- **November 2022:** Aave v2 on Ethereum paused several markets in response to a potential oracle manipulation vector. All markets resumed within 24 hours. No funds were lost.
- **March 2023:** Aave governance paused the CRV market following concerns about bad debt from a large position. The pause lasted several days while governance deliberated. All funds were safe.
- **Various L2 pauses:** Aave on Optimism and Arbitrum has experienced brief pauses related to sequencer downtime. These resolved automatically when the sequencer resumed.

In every historical case:
1. The pause was a precautionary measure, not a response to lost funds.
2. All depositor capital was fully accessible once the pause lifted.
3. The longest pause lasted approximately one week (governance-related).

---

## What You Should Do

### During an Aave Pause

1. **Do nothing.** Your capital is safe. The vault is designed to handle this scenario.
2. **Do not panic-sell vault shares** on secondary markets (if any exist) at a discount. The underlying value is unchanged.
3. **Check the Aave governance forum** (governance.aave.com) for updates on when the pause will be lifted, if you want to stay informed.
4. **Withdrawals you already requested** will process automatically once the pause ends. You do not need to resubmit.

### After Aave Unpauses

1. Everything resumes automatically. Queued withdrawals process. Queued payouts disburse. New deposits flow to Aave.
2. You do not need to take any manual action.
3. Aave yield resumes accruing immediately.

---

## Frequently Asked Questions

**Q: Can I still deposit into the vault during an Aave pause?**
A: Yes. Your USDC enters the vault and is accounted for correctly. It simply sits as liquid USDC in the vault until Aave resumes, at which point it is automatically deployed.

**Q: Does the cooldown timer pause if Aave is paused?**
A: No. Your cooldown continues to tick regardless of Aave's status. However, if your cooldown completes and you request a withdrawal that requires pulling from Aave, the withdrawal will queue until Aave unpauses.

**Q: Could an Aave pause cause the vault to become insolvent?**
A: No. The funds in Aave are not lost -- they are temporarily inaccessible. The vault's accounting remains accurate. Insolvency would require Aave itself to lose the funds permanently, which is a separate (and far more severe) risk covered in the vault risk disclosures.

**Q: What if a large insurance claim comes in during an Aave pause?**
A: The claim is approved normally. The payout queues. The claimant receives their funds once Aave unpauses. The protocol does not reject valid claims due to temporary illiquidity.

**Q: Has Lumina ever been affected by an Aave pause?**
A: Refer to the protocol's incident log for the most current information. The vault architecture was designed with Aave pauses as an expected (not exceptional) scenario.
