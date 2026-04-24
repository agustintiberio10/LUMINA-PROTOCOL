# FLOW-09 — Direct answers to the founder's 4 questions

All claims below cite the Solidity source by file + line. No speculation.

---

## Question 1

> **"Does the 16-cell system make the protocol buy USDC into BondVault when price drops?"**

### Answer: NO.

### Evidence

The 16-cell matrix is defined at `src/core/AdaptiveFeeDistributor.sol:50-80` (`_lookupDistribution`). It returns a tuple `(burnBps, buybackBps, opsBps, maintenanceBps)`. These 4 buckets are consumed by `TWAPBurner._executeAdaptive` at `src/core/TWAPBurner.sol:148-171`:

```solidity
if (toBuyback > 0 && buybackReserve != address(0))   usdc.safeTransfer(buybackReserve, toBuyback);
if (toOps > 0 && opsReserve != address(0))           usdc.safeTransfer(opsReserve, toOps);
if (toMaint > 0 && maintenanceReserve != address(0)) usdc.safeTransfer(maintenanceReserve, toMaint);
if (toBurn > 0)                                      _swapAndBurn(toBurn);
```

The four destinations are:
1. **BuybackEngine** (via `buybackReserve`).
2. **Ops EOA** (via `opsReserve`).
3. **MaintenanceReserve** (via `maintenanceReserve`).
4. **DEX + burn** (via `_swapAndBurn`).

`bondVault` is NOT among them. There is no branch anywhere in `TWAPBurner` that transfers to BondVault. See FLOW-05 §5.6 and FLOW-06 §6.4.

When price drops and quadrant shifts toward CRISIS, the matrix reallocates AWAY from burn TOWARD buyback (see the 16-cell table in FLOW-05 §5.3). Buyback USDC goes to BuybackEngine, which uses it to purchase discounted bonds on the marketplace and then calls `bondVault.burnFromReserves(...)` — which **removes** LUMINA from the vault (destroying it), never deposits. See `src/marketplace/BuybackEngine.sol:151-168`.

**Net:** when price drops, the matrix does indirect damage-control by reducing obligations faster — it does not route value into BondVault.

---

## Question 2

> **"Is there an automatic mechanism to replenish BondVault if it runs short?"**

### Answer: NO.

### Evidence

Exhaustively verified in FLOW-04:

- `BondVault` has no `deposit`, `fund`, or `refill` function — see `src/bonds/BondVault.sol` in full.
- The only inflow event for BondVault LUMINA is the one-shot mint in `LuminaTokenV2.initialize()` (70M LUMINA, cited in FLOW-01 §7).
- Outflows are `redeemBond` (LUMINA → holder) and `burnFromReserves` (LUMINA destroyed). Both are drains.
- No contract in `src/` calls `lumina.transfer(bondVault, ...)`. Confirmed by exhaustive search over the repo.
- MaintenanceReserve — the only stash of accumulating USDC — has no function to swap USDC → LUMINA nor to transfer value to BondVault. See FLOW-07 §7.5.
- TWAPBurner's `_swapAndBurn` performs `burn(luminaReceived)` at line 240 — never transfer. See FLOW-06 §6.4.
- `recoverToken` on TWAPBurner explicitly blocks both USDC and LUMINA recovery (`src/core/TWAPBurner.sol:383-384`), so admin cannot redirect the channel.

The only "mitigations" available today are:
1. Admin transfers LUMINA directly from an EOA that holds it (3-tx manual process).
2. Wait for organic burns to reduce supply and raise price → reduce LUMINA-per-dollar needed per redemption.

Both require off-chain / governance action. See FLOW-08 §8.6 for worked examples.

---

## Question 3

> **"If it does not exist, what should we add?"**

### Answer: a single admin-gated rescue function, behind timelock + multisig, with router whitelist and hard slippage floor.

### Recommended design

**Location:** Add a new function to `MaintenanceReserve` (cheaper, no new proxy), OR create a dedicated `BondVaultReplenisher` UUPS proxy (cleaner separation). Both are viable; see FLOW-07 §7.7 for trade-offs. My preference for production: dedicated proxy, because single-responsibility contracts are easier to audit and pause.

**Signature:**
```solidity
function swapAndReplenishBondVault(
    uint256 usdcAmount,
    uint256 minLuminaOut,
    address dexRouter
) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant;
```

**Key guardrails:**
1. `onlyRole(DEFAULT_ADMIN_ROLE)` — held by Gnosis Safe 3-of-5.
2. Wrapped in a 48-hour Timelock on the admin role — gives Guardian (if adopted) a veto window.
3. `dexRouter` must be in a whitelist (`isAllowedRouter[router] == true`).
4. `minLuminaOut > 0` enforced (mirrors TWAPBurner's fix M-02 policy).
5. Destination is **hardcoded** to `address(bondVault)` — admin cannot redirect elsewhere.
6. Emits event `BondVaultReplenished(usdcSpent, luminaReceived, router, timestamp)` for observability.
7. Counter `totalLuminaSentToVault` for cumulative tracking.
8. No monthly cap — rescues are crisis actions, not operating expenses.

**UUPS storage:** both MaintenanceReserve and a new contract must respect the existing `__gap[50]`. New mapping (`isAllowedRouter`) uses 1 slot; counter uses 1 slot; well within headroom.

**Deployment:** if going with the dedicated proxy pattern, grant `DEFAULT_ADMIN_ROLE` on the new proxy to the same Safe. Fund the proxy from MaintenanceReserve via `spend(replenisher, X, Other, "rescue funding")` when needed — or grant the replenisher permission to pull from MaintenanceReserve via a `fundReplenisher` helper.

**Estimated effort:** ~50 LoC Solidity, ~200 LoC test, 1 integration test with a mock DEX, 1 upgrade migration. Should fit within one audit-cycle.

**What NOT to build:**
- No automatic keeper-based trigger. Timing of rescue depends on judgment (is this the bottom? can we afford to spend USDC reserves now?). Keep it manual.
- No admin-chooses-recipient path. Hardcode destination.
- No cap on a single rescue — during a crisis you want to move the whole reserve in one tx.

See FLOW-07 §7.7 for fuller design rationale.

---

## Question 4

> **"The Guardian role — does it really add value given we already plan a 3-of-5 multisig + 48h timelock?"**

### Answer: Marginal. The multisig + timelock covers ~90% of the need. A Guardian role adds value ONLY in a specific narrow scenario: emergency pause where you cannot gather 3 signatures in <48h.

### Honest pros/cons

**What multisig + timelock already buys you:**
- Admin-key compromise of 1-2 signers → does not unlock anything (need 3 sigs).
- A malicious signer proposes a malicious tx → other signers or observers have 48h to cancel.
- Regulatory / subpoena → 48h notice to act.
- Social-engineering attack → other signers have time to verify and refuse.

**What a Guardian role additionally buys you:**
- If a live attack is in progress (e.g., a quadrant manipulation, a DEX manipulation causing TWAPBurner to trade against bad prices, a reentrancy being executed), Guardian can `pause()` **without** needing 3 signatures. Single-sig fast-pause.
- Practical response time: Guardian is typically one human with direct wallet access → can react in minutes instead of the ~hours-to-days that even a well-organized 3-of-5 takes.
- A Guardian can be empowered to CANCEL queued timelock tx (a defensive action, not an offensive one) without gathering the full multisig.

**Costs of adding a Guardian role:**
- **Asymmetric power:** Guardian can pause and/or cancel unilaterally. If the key is compromised, a single attacker can halt the protocol and harm the protocol via inaction (e.g., halt redemptions indefinitely until revoked). This is the inverse of the multisig — it trades "attacker cannot act" for "attacker can freeze".
- **Trust assumption:** a Guardian is one human. Adds a weak link to the overall system even if narrow.
- **Role complexity:** two admin pathways (Guardian pause, multisig action) must be reasoned about separately in every contract. More audit surface.
- **Off-boarding cost:** rotating the Guardian is itself a governance action and takes real operational discipline.

**Where a Guardian is most justified:**
- Protocols with frequent trading paths that can be attacked at sub-hour speeds (oracle manipulation, MEV sandwich loops, re-entrancy).
- LUMINA V5.1 *does* have such surfaces: TWAPBurner swaps, BuybackEngine swaps, DEX price feeds through CapacityOracle.

**Where multisig + timelock alone suffices:**
- Low-frequency admin actions (upgrades, parameter tuning, reserve transfers).
- Operational spend (`spend()` on MaintenanceReserve is already SPENDER_ROLE-gated).
- Bond issuance/redemption (already permissionless — Guardian cannot protect these without adding a `whenNotPaused` check across the whole protocol, which is a design cost).

### Recommendation

1. **If** the protocol adopts a `whenNotPaused` pattern on TWAPBurner and BuybackEngine only (the two swap-heavy surfaces), Guardian-held pause there is **worth it** — net benefit for a small blast-radius.
2. **Do NOT** give Guardian any role wider than "pause the swap contracts" and "cancel a queued timelock tx". Never grant Guardian the power to sign as an admin (upgrades, role grants, parameter changes).
3. **Prefer** a time-bounded Guardian (e.g., Guardian's pause auto-expires after 72h unless the multisig extends) — limits the blast radius of a compromised Guardian key.
4. **Rotate** Guardian key on a cadence (quarterly) as a basic op-sec rule.

If you were to score (1=no value, 10=critical): Guardian without auto-expiry = 4/10; Guardian with 72h auto-expire + scoped to swap-pause = 7/10; multisig + timelock alone (no Guardian) = 8/10. In short: Guardian is a tactical emergency lever, not a strategic requirement. Add it if you can keep the scope narrow, skip it if scope tends to creep.

---

## Quick recap (for sharing)

1. **16 cells funding BondVault?** NO — 4 buckets (burn/buyback/ops/maint), none goes to BondVault.
2. **Auto-replenishment?** NO — BondVault is a one-shot-funded (70M LUMINA at deploy), drain-only contract.
3. **What to add?** A single admin-gated `swapAndReplenishBondVault(usdc, minLumina, whitelistedRouter)` behind 48h timelock + 3-of-5 multisig + router whitelist. ~50 LoC + tests.
4. **Guardian value-add?** Marginal. Net positive only if (a) scoped to pausing the 2 swap surfaces, (b) auto-expiring, (c) cannot sign as admin. Otherwise skip and keep the design simpler.
