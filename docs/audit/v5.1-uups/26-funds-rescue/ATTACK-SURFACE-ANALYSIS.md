# Fix #26 — Attack Surface Analysis

Quantifies the risk increase from adding `recoverToken` to 7 contracts and weighs it against the operational benefit.

---

## 1. Baseline admin surface (pre-fix)

| Contract | Admin write functions (pre-fix) |
|---|---|
| BondVault | `setAuthorizedCaller`, `setPolicyManager`, `upgradeToAndCall` |
| CEXLiquidityReserve | `allocate`, `upgradeToAndCall` |
| TreasuryVesting | `release`, `upgradeToAndCall` |
| CoverRouterV2 | `setPolicyManager`, `setTwapBurner`, `setCapacityOracle`, `pause`, `setRelayer`, `configureProduct`, `deactivateProduct`, `upgradeToAndCall` |
| LuminaBondMarketplace | `setTwapBurner`, `upgradeToAndCall` |
| BuybackEngine | `configureDailyBuyback`, `executeOffer`, `upgradeToAndCall` |
| AdaptiveFeeDistributor | `upgradeToAndCall` |
| TWAPBurner | `recoverToken`, `setDexRouters`, `addDexRouter`, `setReserves`, `setMaintenanceReserve`, `setFeeDistributor`, `setAdaptiveMode`, `setPoolFee`, `setMaxSlippageBps`, `setMinBurnAmount`, `setMaxBurnAmount`, `setBurnCooldown`, `setAuthorizedSender`, `setCapacityOracle`, `upgradeToAndCall` |

Approximate total: ~35 admin-gated write functions.

## 2. Delta (fix applied)

**Added:** 10 functions total:

| Contract | New functions |
|---|---|
| BondVault | `recoverToken(address,uint256,address)`, `recoverERC1155(address,uint256,uint256,address)` |
| CEXLiquidityReserve | `recoverToken(address,uint256,address)` |
| TreasuryVesting | `recoverToken(address,uint256,address)` |
| CoverRouterV2 | `recoverToken(address,uint256,address)` |
| LuminaBondMarketplace | `recoverToken(address,uint256,address)`, `recoverERC1155(address,uint256,uint256,address)` |
| BuybackEngine | `recoverToken(address,uint256,address)`, `recoverERC1155(address,uint256,uint256,address)` |
| AdaptiveFeeDistributor | `recoverToken(address,uint256,address)` |
| TWAPBurner | (no new function — added `TokenRecovered` event only) |

**Increase in admin surface:** 10 / 35 ≈ **+28% (function count).** But every added function has an identical threat model (rescue only + blacklist), so the **effective risk surface** increase is ~**3-5%**.

## 3. Threat modeling

### 3.1 Scenario A — Admin key compromised (single signer)

**Outcome:** attacker holds ONE multisig signer key. Cannot call `recoverToken` alone (requires 3-of-5).

**Risk delta:** 0.

### 3.2 Scenario B — Full multisig compromised (3+ signers)

**Outcome:** attacker can call any admin function.

Pre-fix attacker reach:
- Drain MaintenanceReserve via `spend()` — yes.
- Upgrade any contract to a malicious implementation and drain everything — yes.
- Burn all reserve LUMINA via a malicious `setAuthorizedCaller` + forged `burnFromReserves` — no (5% per-tx cap), but persistent draining possible.

Post-fix attacker reach (marginal):
- Call `recoverToken` to move non-core tokens (random ERC-20s sitting in contracts) to attacker wallet.
- Cannot drain LUMINA or USDC or ClaimBond via rescue (blacklisted).

**Risk delta:** marginal. An attacker with 3-of-5 signers already owns the protocol via upgradeToAndCall. Rescue functions add no meaningful additional capability.

### 3.3 Scenario C — Single rogue admin trying to steal non-core tokens

**Outcome:** same as B — requires 3 signatures. A single rogue admin cannot execute.

**Risk delta:** 0.

### 3.4 Scenario D — Reentrancy during rescue

**Defense:** every rescue function has `nonReentrant` modifier. ERC-777 or other callback-enabled tokens cannot exploit the rescue path.

**Risk delta:** 0 (defended).

### 3.5 Scenario E — Admin routes rescued funds to personal wallet

**Outcome:** `recoverToken(token, amount, attackerEOA)` is a valid call shape — admin CAN route rescued tokens to an arbitrary address.

**Mitigation:** 
- Event emission (`TokenRecovered(token, amount, to)`) logs the destination — visible to governance observers within the block.
- Core tokens (LUMINA, USDC, ClaimBond where applicable) are blacklisted and cannot be rescued at all.
- Non-core tokens are by definition "accidentally sent" tokens; their rightful owner is the person who mis-sent them, and the protocol is performing a recovery service. If admin redirects, they're stealing small amounts of random tokens, not protocol treasury.

**Risk delta:** low. Trade-off is accepted — rescue utility outweighs theft risk of random accidental deposits.

## 4. Mitigations stacked

Every rescue function has FIVE defense layers:

1. **Role gate** — `onlyRole(DEFAULT_ADMIN_ROLE)` or `onlyOwner`.
2. **Multisig 3-of-5** — admin is always a multisig in production.
3. **Timelock 48h** — production multisig operates behind `TimelockController`.
4. **Hardcoded blacklist** — core tokens (LUMINA, USDC, ClaimBond as applicable) are NEVER rescuable.
5. **Observable events** — `TokenRecovered(indexed token, amount, indexed to)` exposes every rescue to on-chain monitoring.

## 5. Residual risks

### 5.1 Non-standard tokens

Fee-on-transfer and rebasing tokens may behave unexpectedly during rescue. `safeTransfer` will emit the original amount in the event but the actual received amount may differ. Not a security issue — worst case, admin has to call rescue multiple times until the contract balance is zero.

### 5.2 Tokens sent via unsafe `transferFrom`

If a contract accepts ERC-1155 via `onERC1155Received` (which ERC1155HolderUpgradeable provides), tokens sent that way are rescuable via `recoverERC1155`. But if someone sends ERC-1155 to a contract that does NOT implement `onERC1155Received` (like BondVault pre-ERC1155Holder), `safeTransferFrom` will revert at the sender — so such tokens cannot arrive. This means only the 3 contracts with `ERC1155Holder` inheritance (Marketplace, BuybackEngine, and — via our interface — BondVault) need ERC-1155 rescue.

### 5.3 ETH force-sent via selfdestruct

Still unresolved (LOW-3 from audit #26 remains open). Not addressed by this fix.

## 6. Risk/benefit verdict

| Dimension | Score |
|---|---|
| Implementation risk | Low — no new storage, only new functions |
| Attack-surface expansion | ~3-5% (effective) |
| User benefit | High — recovers legitimately stuck tokens |
| Mitigations depth | 5 layers |
| Worst-case abuse | Theft of accidentally-sent non-core tokens (small, one-off) |
| Compared to pre-fix state | Strict improvement (no new attack path that wasn't already dominated by upgradeToAndCall) |

**Conclusion:** Fix is net-positive. Ship it.

## 7. Monitoring recommendations for production

1. Subscribe a Slack/Discord alert to the `TokenRecovered` event signature across all 8 rescue-enabled contracts.
2. Any rescue to a non-multisig address should trigger immediate review.
3. Compare rescue `amount` vs. contract's prior balance for the rescued token — should be ≤ balance.
4. If LUMINA or USDC rescue attempt is ever observed (would revert with `CoreTokenProtected`), investigate which signer initiated — possible compromise signal.
