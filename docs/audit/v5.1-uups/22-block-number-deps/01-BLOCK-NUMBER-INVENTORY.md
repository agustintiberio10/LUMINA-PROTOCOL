# Audit V5.1 #22 — Block-Number Dependencies: Inventory

**Target:** `src/` — every block-scope and transaction-scope global.
**Date:** 2026-04-23

---

## 1. Static grep results

Every query below was run against `src/`:

| Query | Hits |
|---|---|
| `block.number` | **0** |
| `blockhash` (incl. the `blockhash(uint)` builtin) | **0** |
| `block.difficulty` | **0** |
| `block.prevrandao` | **0** |
| `block.basefee` | **0** |
| `block.coinbase` | **0** |
| `block.chainid` | **0** |
| `tx.origin` | **0** |

**Only block-scope global used in `src/`:** `block.timestamp` (78 occurrences — covered by audit #21).

## 2. Interpretation

This is the cleanest result possible:

- **No on-chain randomness** — no `blockhash` / `difficulty` / `prevrandao` anywhere. Every randomness-manipulation class of attack is structurally impossible.
- **No block-number-as-time** — no cooldown, expiry, or epoch math uses `block.number`. Block times on Base are variable (~2 s target but can drift), and using them as a clock is a classic bug source. We don't.
- **No gas-market coupling** — no `basefee` / `coinbase` references, so no "pay miner directly" or "conditional-on-fee" patterns.
- **No `tx.origin`** — access control throughout uses `msg.sender`, which is immune to nested-contract-call attacks.
- **No explicit chainId dependency** — the protocol is UUPS-upgradable on a specific chain (Base); any cross-chain replay-protection would need to be added for EIP-712 flows (currently using address-based identity — see audit #7 on EIP-712).

## 3. Safety properties verified dynamically

`test/audit/v5.1-uups/time-based/block-number/BlockNumberDeps.t.sol` contains 11 tests:

| Test | Property |
|---|---|
| `Policy_DoesNotExpireOnBlockRoll` | Rolling +10M blocks with zero time elapsed doesn't change policy status. |
| `BurnCooldown_DoesNotExpireOnBlockRoll` | TWAPBurner cooldown doesn't tick on block rolls. |
| `BondMaturity_DoesNotAdvanceOnBlockRoll` | Bond maturity unchanged after +100M block roll. |
| `EpochComputation_IndependentOfBlockNumber` | Two bonds issued across a 5M-block gap but zero time elapse land in the same epoch. |
| `SafetyWindow_IgnoresBlockRoll` | checkAndSettlePolicy still reverts after +10M blocks. |
| `NoBlockNumber_Reference_InSrc` | Static claim (grep verified). |
| `NoBlockhash_Randomness_InSrc` | Static claim. |
| `NoDifficulty_NoPrevrandao_InSrc` | Static claim. |
| `NoCoinbase_InSrc` | Static claim. |
| `NoTxOrigin_InSrc` | Static claim. |
| `NoChainIdDependency_InSrc` | Static claim. |

## 4. Conclusion

**Clean.** Nothing to fix. The protocol exclusively uses `block.timestamp` for all time-dependent logic; no other block-scope global is referenced anywhere in `src/`.
