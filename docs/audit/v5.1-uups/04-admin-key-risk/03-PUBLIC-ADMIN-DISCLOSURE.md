# LUMINA Protocol — Admin Powers Disclosure

**For:** End users, liquidity providers, insurance policyholders
**Date:** 2026-04-22
**Scope:** V5.1 (24 UUPS upgradeable contracts)

> **Short version:** LUMINA Protocol V5.1 is upgradeable. This means the
> protocol admin has technical power to modify contract code. Before mainnet,
> that power is guarded by a 3-of-5 multisig and a 48-hour on-chain timelock,
> so any admin action is publicly visible for two days before it can take
> effect — giving users time to respond. Below is an honest breakdown of
> what the admin can and cannot do.

---

## 1. What does "UUPS upgradeable" actually mean?

UUPS (Universal Upgradeable Proxy Standard) is a pattern where each contract
has two parts:

- A **proxy**, which holds your data (balances, policies, bonds) and the
  contract's public address.
- An **implementation**, which holds the logic (code). The implementation
  can be replaced by the admin.

Upgrading means pointing the proxy at a new implementation. Your data stays
put; only the logic changes. This is how most serious DeFi protocols ship
fixes after launch.

## 2. What can the admin do?

In the worst case (compromised admin key), the admin can:

| Action | Affected contracts |
|--------|--------------------|
| Install new code in any UUPS contract | All 24 |
| Grant / revoke privileged roles | LuminaTokenV2, BondVault, BuybackEngine, LuminaBondMarketplace, SolvencyOracle, CEXLiquidityReserve, MaintenanceReserve |
| Pause automated policy settlement | ShieldKeeper |
| Configure DEX routers / oracle pool | TWAPBurner, CapacityOracle |
| Release vested treasury | TreasuryVesting |
| Recover tokens | TWAPBurner, MaintenanceReserve |

In concrete worst-case scenarios:
- Install a malicious `LuminaTokenV2` impl that mints new LUMINA.
- Authorize an attacker address as a `BondVault` caller, which lets the
  attacker reduce obligations or trigger reserve burns.
- Release all unvested treasury tokens to the admin's own address.

## 3. What can the admin NOT do without a code change?

- Directly take your USDC — no contract has an "admin withdraw all funds"
  function.
- Mint LUMINA without replacing the token implementation. (LuminaTokenV2
  has no public `mint` function.)
- Steal policies from your wallet. Policies are ERC-1155 / ERC-20-like
  balances that only you control directly.
- Bypass the 5% per-transaction burn cap in BondVault without upgrading
  the impl.
- Reinitialize any contract — initializers are single-shot.

The emphasis is important: every truly catastrophic action requires a **code
upgrade**, and every code upgrade will be timelocked (see §5).

## 4. Who is "the admin"?

At launch the admin is a deployer EOA. **Immediately after mainnet launch,
admin rights will be transferred to:**

- **3-of-5 multisig** held on hardware wallets (details published in
  governance repo).
- **TimelockController** with a 48-hour delay on every admin action.

After this transfer, the **admin EOA is renounced** — it stops existing.

## 5. What mitigations are in place / planned?

**Already live in code (audited in #1–#3):**

- `_disableInitializers()` in every implementation constructor — prevents
  an attacker from hijacking an abandoned implementation contract.
- Separation of `DEFAULT_ADMIN_ROLE` and function-specific roles (BURNER,
  FEE_MANAGER, ALLOCATOR, etc.) so compromising one doesn't grant the others.
- Ranges and caps on parametric setters (slippage ≤ 10%, burn cooldown 1min–24h,
  capacity oracle window 5min–2h, buyback maxPrice ≤ 95%, etc.).
- On-chain events for every admin action (role grants, upgrades, config
  changes), so a public sentinel can flag suspicious activity instantly.

**Planned pre-mainnet (tracked in `04-PRE-MAINNET-RECOMMENDATIONS.md`):**

- Transfer every admin role to a **3-of-5 multisig on hardware wallets**.
- Install `TimelockController` with **48h** delay for all UUPS upgrades and
  admin-only setters.
- Publish a **public upgrade queue** in the governance frontend — any
  pending upgrade is visible for the full timelock period.
- **Bug bounty** on Immunefi with an admin-risk-weighted scope.
- External audit focused on admin-risk minimization.

## 6. What can YOU do as a user?

- **Monitor the multisig address** — if you see interactions outside
  scheduled upgrades, raise concerns in governance channels.
- **Watch the upgrade queue** — anything queued gives you 48h to exit
  positions if you disagree.
- **Use OpenZeppelin Defender / Tenderly** personal alerts on the following
  event signatures: `Upgraded(address)`, `RoleGranted(bytes32, address, address)`,
  `Released(address, uint256)`, `AuthorizedCallerSet(address, bool)`.
- **Prefer short-duration policies initially** while the governance model
  decentralizes.

## 7. Roadmap toward permissionlessness

| Phase | Timeline | State |
|-------|----------|-------|
| Deployer EOA | T-0 (testnet) | Current |
| 3-of-5 multisig + 48h timelock | T0 (mainnet launch) | Required |
| Upgrade queue + public monitoring | T+3 months | Planned |
| Governance token → DAO | T+12 months | Roadmap |
| Renounce admin entirely / migrate to immutable set | T+18–24 months | Long-term goal |

**Nothing about the codebase forces this roadmap, but the multisig keys
will be held by individuals publicly committed to it.**

---

This document will be updated as mitigations ship. For technical detail see
`01-ADMIN-POWERS-INVENTORY.md` and `02-RISK-MATRIX.md` in this same folder.
