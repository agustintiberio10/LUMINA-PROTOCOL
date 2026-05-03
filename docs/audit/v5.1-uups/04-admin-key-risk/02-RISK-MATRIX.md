# V5.1 Admin Key Risk Matrix

**Audit:** V5.1 #4 — Admin Key Risk
**Date:** 2026-04-22

Ranks each UUPS contract by **worst-case admin impact** assuming the admin
key is fully compromised (EOA theft or malicious signer).

---

## Consolidated Matrix

| # | Contract | Max Risk | $ Impact | Existing Mitigation | Priority |
|---|----------|----------|----------|---------------------|:--------:|
| 1 | **LuminaTokenV2** | Malicious upgrade mints unlimited LUMINA | $$$$ | DEFAULT_ADMIN separate; BURNER_ROLE distinct **and no longer gates `burnFrom` post [Fix H-1]** (allowance-checked default) | **CRITICAL** |
| 2 | **BondVault** | Authorize attacker caller → drain 70M LUMINA | $$$$ | 5% cap/tx, ReentrancyGuard | **CRITICAL** |
| 3 | **CEXLiquidityReserve** | Allocator drains 14M LUMINA (DAR can raise `monthlyCap` to 14M ceiling — see [Fix H-2]) | $$$ | Mutable monthly cap (default 1M, max 14M), vesting buckets, `MonthlyCapUpdated` event | **HIGH** |
| 4 | **TreasuryVesting** | Release 3M LUMINA to attacker | $$$ | Schedule-based release | **HIGH** |
| 5 | **ClaimBond** | Re-mint claim NFTs → redeem from BondVault | $$$ | `_bondVaultSet` one-shot | **HIGH** |
| 6 | **PolicyManagerV2** | Register malicious shield that forces payouts | $$$ | `productActive` flag | **HIGH** |
| 7 | **CoverRouterV2** | Point PM/burner to attacker contracts | $$$ | Event emissions | **HIGH** |
| 8 | **TWAPBurner** | `recoverToken(lumina)` drains pre-burn balance | $$$ | Slippage cap, cooldown | **HIGH** |
| 9 | **Shields (×9)** | Upgrade to shield that forces trigger condition | $$$ | Oracle-anchored, onlyRouter | **HIGH** |
| 10 | **BuybackEngine** | Overpay for bonds (capped at 95%) | $$ | `maxPct ≤ 95`, `dur ≤ 72h` | **MEDIUM** |
| 11 | **CapacityOracle** | Manipulate emergencyPrice → distort capacity calc | $$ | Window range, nonzero guard | **MEDIUM** |
| 12 | **SolvencyOracle** | Force quadrant / indefinite pause | $$ | Evaluation interval | **MEDIUM** |
| 13 | **LuminaBondMarketplace** | Redirect fees to attacker TWAPBurner | $$ | Event emission | **MEDIUM** |
| 14 | **MaintenanceReserve** | `recoverToken` drains USDC | $$ | Monthly cap, nonReentrant | **MEDIUM** |
| 15 | **AdaptiveFeeDistributor** | Upgrade to bad split logic | $ | Trivial layout | **LOW** |
| 16 | **ShieldKeeper** | Indefinite pause of automated settlement | $ | No funds held | **LOW** |

---

## Legend

- **$$$$** : Catastrophic — protocol-wide; all user funds at risk.
- **$$$**  : Major — single-contract loss of millions in LUMINA/USDC.
- **$$**   : Significant — redirectable fee streams or degraded service.
- **$**    : Low — ops friction only; no direct loss of user funds.

Priority ranking assumes a single compromised admin acting alone; a multisig
+ timelock combination (see `04-PRE-MAINNET-RECOMMENDATIONS.md`) brings every
row down by at least one priority tier.

---

## Top 5 Contracts to Monitor

1. **LuminaTokenV2** — watch `Upgraded(address)` events on the token proxy.
2. **BondVault** — watch `AuthorizedCallerSet` and `Upgraded`.
3. **CEXLiquidityReserve** — watch `RoleGranted(ALLOCATOR_ROLE, …)`,
   `AllocationExecuted`, and `MonthlyCapUpdated` events ([Fix H-2]).
4. **TreasuryVesting** — watch `Released(address, uint256)` events.
5. **Every Shield** — watch `Upgraded(address)` across all 9 shield proxies.

A simple on-chain sentinel (e.g. OpenZeppelin Defender or Tenderly) polling
these events should be live from block 0 of mainnet.
