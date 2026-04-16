# Lumina Vault Guide for Liquidity Providers

## Overview

Lumina Protocol offers four USDC vaults. By depositing USDC, you provide the capital that backs insurance policies. In return, you earn yield from two sources: insurance premiums paid by policyholders and Aave v3 lending interest on idle capital.

Each vault corresponds to a different risk/reward profile based on which insurance products it underwrites.

---

## The Four Vaults Compared

| | Vault Short (VS) | Vault Long (VL) | Shield Short (SS) | Shield Long (SL) |
|---|---|---|---|---|
| **Proxy Address** | 0xbd44... | 0xFee5... | 0x429b... | 0x1778... |
| **Cooldown Period** | 37 days | 97 days | 97 days | 372 days |
| **Products Underwritten** | Short-term covers (BSS, Depeg) | Long-term covers (BSS, Depeg) | Short-term shields (Exploit, IL) | Long-term shields (Exploit, IL) |
| **Expected Yield** | Lower | Moderate | Moderate | Higher |
| **Claim Risk** | Lower severity, higher frequency | Higher severity, lower frequency | Moderate | Highest severity, lowest frequency |
| **Best For** | LPs wanting flexibility | LPs seeking balanced exposure | LPs comfortable with exploit/IL risk | Long-term LPs maximizing yield |

### Understanding Cooldown Periods

The cooldown is the mandatory waiting period between requesting a withdrawal and being able to execute it. Once you initiate a cooldown, it is **irrevocable** -- you cannot cancel it or re-stake during the cooldown.

- **37 days (VS):** Most flexible. Suitable if you may need the capital back within a few months.
- **97 days (VL, SS):** ~3 months. A meaningful commitment. Choose this if you are comfortable locking capital for a quarter.
- **372 days (SL):** Just over a year. This vault offers the highest yield precisely because LPs are committing the longest. Only deposit capital you genuinely will not need for 12+ months.

**Why cooldowns exist:** They prevent LPs from withdrawing when they see a claim coming, which would leave the vault unable to pay policyholders. The cooldown ensures capital stability for the insurance function.

---

## Yield Sources

### 1. Insurance Premiums

When an agent purchases a policy through CoverRouter, the premium (in USDC) is distributed to the vault(s) backing that product. Your share of premiums is proportional to your share of the vault's total deposits.

Premium yield varies based on:
- Volume of policies sold
- Premium rates (set by protocol pricing models)
- Claim payouts (which reduce vault capital and thus your balance)

### 2. Aave v3 Lending Interest

Idle USDC in the vault is deposited into Aave v3 on Base to earn lending interest. This provides a baseline yield even during periods of low policy demand.

Current Aave USDC supply rates on Base vary but typically range from 2-6% APY depending on market utilization.

---

## Risks

### 1. Insurance Claims

This is the primary risk. When a valid claim is paid, the funds come out of the vault. A large claim (e.g., a black swan event triggering many BSS policies) can significantly reduce the vault's total value, and therefore your deposit value.

- **Worst case:** A catastrophic event triggers the maximum payout capacity of the vault, substantially reducing all LP balances.
- **Mitigation:** The protocol limits total exposure per product, and premiums are priced to be actuarially sound over time.

### 2. Irrevocable Cooldown

Once you start a cooldown, you are committed. If market conditions change (e.g., Aave rates spike, or a competing protocol offers better yield), you cannot cancel the cooldown and re-stake.

- **Worst case:** You start a 372-day cooldown on SL, and a week later the vault yield doubles. You must wait the full period.
- **Mitigation:** Only deposit into longer-cooldown vaults with capital you are certain you will not need.

### 3. USDC Depeg Risk

All vaults are denominated in USDC. If USDC loses its peg, the real value of your deposits decreases. This is partially ironic because DepegShield covers this exact risk for policyholders, but vault LPs are exposed to it.

- **Worst case:** A sustained USDC depeg reduces the purchasing power of all vault capital.
- **Mitigation:** This is a systemic stablecoin risk that cannot be hedged within the protocol. Consider your overall portfolio exposure to USDC.

### 4. Aave Risk

Capital deposited into Aave is subject to Aave smart contract risk and governance risk.

- **Worst case:** An Aave vulnerability leads to loss of deposited funds.
- **Mitigation:** Aave v3 is one of the most audited and battle-tested protocols in DeFi. See the [Aave Pause Guide](./AAVE-PAUSE-GUIDE.md) for information on temporary pauses (which are safe).

---

## Step-by-Step: Depositing

### Prerequisites
- USDC on Base network in your wallet
- Enough ETH on Base for gas fees
- Connected to Base mainnet (chain ID 8453)

### Steps

1. **Approve USDC spending.** Call `approve()` on the USDC contract (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) with the vault's proxy address as the spender and your deposit amount.

2. **Call `deposit()` on the vault.**
   - `deposit(uint256 assets, address receiver)`
   - `assets`: The amount of USDC to deposit (6 decimals, so 1000 USDC = 1000000000)
   - `receiver`: Your address (to receive the vault shares)

3. **Receive vault shares.** The vault mints ERC-4626 shares to your address proportional to your deposit relative to the vault's total assets. These shares represent your claim on the vault's capital plus future yield.

4. **Verify.** Check your vault share balance by calling `balanceOf(yourAddress)` on the vault contract.

---

## Step-by-Step: Withdrawing

Withdrawing is a two-step process due to the cooldown mechanism.

### Step 1: Initiate Cooldown

1. **Call `initiateCooldown()`** on the vault contract.
2. Your cooldown timer starts. It is irrevocable.
3. Note the timestamp -- you can call `cooldownEndTime(yourAddress)` to check when it expires.

### Step 2: Execute Withdrawal (After Cooldown)

1. **Wait for the cooldown to complete.** (37 / 97 / 97 / 372 days depending on the vault.)
2. **Call `withdraw()` or `redeem()`** on the vault contract.
   - `withdraw(uint256 assets, address receiver, address owner)` -- specify USDC amount
   - `redeem(uint256 shares, address receiver, address owner)` -- specify share amount
3. **Receive USDC.** The vault burns your shares and sends you the corresponding USDC.
4. If the vault needs to pull USDC from Aave and Aave is paused, your withdrawal will queue and process automatically when Aave resumes.

### Important Notes
- If you do not withdraw promptly after cooldown completes, check whether there is a withdrawal window. Some vault configurations require you to withdraw within a set period after cooldown ends, or you must re-initiate.
- You cannot do a partial cooldown. It applies to your entire position.

---

## Frequently Asked Questions

**Q: Can I deposit more while a cooldown is active?**
A: No. The cooldown locks your position. You cannot add to it or modify it until the cooldown completes and you either withdraw or re-stake.

**Q: What if a huge claim wipes out most of the vault while I am in cooldown?**
A: Your shares entitle you to a proportional share of whatever remains in the vault. If a claim reduces the vault by 40%, your withdrawal will be ~40% less than expected. This is the core risk of being an LP.

**Q: Is the yield guaranteed?**
A: No. Yield depends on premium volume and Aave rates, minus any claim payouts. There can be periods of negative net yield if claims exceed premiums.

**Q: Can I transfer my vault shares to another wallet?**
A: Vault shares are standard ERC-20 tokens and can be transferred. However, any active cooldown is tied to the original address, not the shares themselves.

**Q: Which vault should I choose?**
A: Consider:
- **How long can you lock capital?** If less than 3 months, only VS (37d) is practical.
- **What risk are you comfortable with?** BSS/Depeg claims (VS/VL) tend to be correlated with broad market events. Exploit/IL claims (SS/SL) are more idiosyncratic.
- **Do you want maximum yield?** SL offers the highest expected return because it has the longest lockup and underwrites the highest-severity products.

**Q: What is the minimum deposit?**
A: There is no protocol-enforced minimum, but gas costs on Base make deposits under ~100 USDC impractical from a yield perspective.

**Q: How do I track my earnings?**
A: Your vault shares increase in value over time as premiums accrue. Call `convertToAssets(yourShareBalance)` on the vault contract to see the current USDC value of your position. Compare this to your original deposit to see your net return.
