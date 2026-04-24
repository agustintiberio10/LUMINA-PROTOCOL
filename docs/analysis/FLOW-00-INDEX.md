# Flow Analysis — Index

Purpose: answer the founder's question "where does the money go" with code-level precision. No code changes. No tests. Only reading and documentation.

## Documents

1. [FLOW-01-INCOMING.md](./FLOW-01-INCOMING.md) — every source of USDC/LUMINA entering the protocol
2. [FLOW-02-OUTGOING.md](./FLOW-02-OUTGOING.md) — every destination USDC/LUMINA leaves toward
3. [FLOW-03-USDC-ROUTING.md](./FLOW-03-USDC-ROUTING.md) — end-to-end route of each incoming USDC
4. [FLOW-04-BONDVAULT.md](./FLOW-04-BONDVAULT.md) — BondVault content + deposit/withdraw surface
5. [FLOW-05-ADAPTIVE-DISTRIBUTION.md](./FLOW-05-ADAPTIVE-DISTRIBUTION.md) — the 4×4 matrix (16 cells)
6. [FLOW-06-TWAPBURNER.md](./FLOW-06-TWAPBURNER.md) — TWAPBurner post-swap destination
7. [FLOW-07-MAINTENANCE-RESERVE.md](./FLOW-07-MAINTENANCE-RESERVE.md) — current use + rescue-function gap
8. [FLOW-08-NUMERICAL-SIMULATION.md](./FLOW-08-NUMERICAL-SIMULATION.md) — 5 events traced numerically
9. [FLOW-09-FOUNDER-ANSWER.md](./FLOW-09-FOUNDER-ANSWER.md) — direct answers to your 4 questions

## Top-line findings

- **Premium USDC:** 100% → `TWAPBurner.receivePremium` → executeBurn splits via adaptive distribution (16 cells).
- **Marketplace fees:** buyer (1.5%) + seller (1.5%) → `Marketplace.executeBuy` pushes **both** fees to `twapBurner` address directly (not via `receiveMarketplaceFee` — see §3).
- **BondVault:** receives 70M LUMINA **once at token deploy**. No automatic refill path. No swap-in. No USDC storage.
- **16 cells:** allocate incoming USDC to burn / buyback / ops / maintenance. None allocate to BondVault.
- **MaintenanceReserve:** accumulates USDC; can `spend()` to arbitrary recipient with monthly cap; cannot send USDC to BondVault or swap USDC→LUMINA.

## Direct answer summary (full version in FLOW-09)

1. **"Do the 16 cells fund BondVault when LUMINA drops?"** → **NO.** The 16 cells allocate USDC among burn / buyback / ops / maintenance. None of these moves value INTO BondVault.
2. **"Is there an automatic BondVault-replenishment mechanism?"** → **NO.** BondVault receives LUMINA once at deploy (70M) and is drained by `redeemBond`/`burnFromReserves`. No refill function exists.
3. **"What to add?"** → A rescue function on MaintenanceReserve that swaps accumulated USDC → LUMINA and deposits to BondVault, restricted to DEFAULT_ADMIN_ROLE behind multisig + timelock.
4. **"Guardian role value over multisig+timelock?"** → Marginal. Multisig+timelock cover 90% of the need. Guardian is useful only for "fast pause in crisis" scenarios where 3-of-5 sig can't be gathered in time — worth the complexity if you want <5min response capability.
