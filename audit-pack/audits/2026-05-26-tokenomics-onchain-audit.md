# Tokenomics On-Chain Audit V5.4

**Date:** 2026-05-26
**Methodology:** direct on-chain reads + full mint-event analysis (Base Sepolia).
**Scope:** LUMINA token `0x62C0…6680` + every touching contract/wallet.
**READ-ONLY — no tokens moved, no contracts modified.**

## Executive Summary

- **Total supply verified: ✅ 100,000,000 LUMINA (1e26 wei).**
- **Conservation: ✅ EXACT.** Sum of all holders = **100,000,000.00** — **0.0000% discrepancy**. No duplicate mint, no missing wei.
- All 100M were minted in **one transaction** at genesis: block **41,680,297**, tx `0x794ff5ba49b4282b98690b542ab90c38c11996724b662dd2fa5c3ef385df7c45` — **5 mints** matching the canonical 70/14/8/5/3 split exactly.
- **The ~5M in the founder wallet is the LBP allocation, minted DIRECTLY to the founder EOA at genesis** (+2,222.22 from the E2E-test bond redeem). It is a legitimate allocation, but **parked in the founder's operational EOA** rather than a dedicated LBP contract.
- **The "22M not deployed" is NOT missing** — CEX (14M), LBP (5M), Treasury (3M) were each minted to an **address** at genesis; the *contracts* (CEXLiquidityReserve / TreasuryVesting / a dedicated LBP vault) were simply never deployed, so those allocations sit in **EOAs**.
- **Anomalies: 3** (all MEDIUM/LOW — custody/segregation, not supply integrity).

## Mint history (genesis)

Single tx `0x794ff5ba…df7c45`, block **41,680,297**, 5 `Transfer(0x0 → …)` events:

| # | Mint → | Amount | Intended allocation |
|---|---|--:|---|
| 1 | `0x193acBc1…B6EC` | 70,000,000 | BondVault |
| 2 | `0x584681a8909ce3c3acbc3f57216796b86f641be6` | 14,000,000 | CEX/DEX liquidity |
| 3 | `0xfF4Db529…2832` | 8,000,000 | FounderVesting |
| 4 | `0xe585e76A…BfDa8` | 5,000,000 | **LBP — minted to FOUNDER WALLET** |
| 5 | `0xaf598c517a6b672d105f3257eb112d132ccb7261` | 3,000,000 | Treasury |
| | **Total** | **100,000,000** | = canonical 70/14/8/5/3 ✅ |

## Master distribution table (current on-chain)

| Address | Label | Official allocation | Balance now | Match | Notes |
|---|---|--:|--:|:--:|---|
| `0x193acBc1…B6EC` | BondVault | 70,000,000 | **69,997,777.78** | ✅ | −2,222.22 paid out in the E2E bond redeem (→ founder) |
| `0x584681a8…1be6` | CEX allocation (EOA) | 14,000,000 | **14,000,000.00** | ✅ | held in an **EOA**; CEXLiquidityReserve contract = 0x0 (not deployed) |
| `0xfF4Db529…2832` | FounderVesting | 8,000,000 | **8,000,000.00** | ✅ | contract; locked per AltSeason/3-yr paths |
| `0xe585e76A…BfDa8` | **Founder wallet** | 5,000,000 (LBP) | **5,002,222.22** | ⚠️ | LBP minted to founder EOA + 2,222.22 from E2E redeem |
| `0xaf598c51…7261` | Treasury allocation (EOA) | 3,000,000 | **3,000,000.00** | ✅ | held in an **EOA**; TreasuryVesting contract not the holder |
| Relayer `0x168dC7…7E4a` | gas relayer | 0 | 0 | ✅ | holds only ETH |
| TWAPBurner / BuybackEngine / AdaptiveFeeDistributor / MaintenanceReserve / PolicyManager / CoverRouter / ClaimBond / Marketplace / CapacityOracle / token-self / 0xdead | — | 0 | 0 | ✅ | no LUMINA held (no burns yet) |
| **TOTAL** | | **100,000,000** | **100,000,000.00** | ✅ | exact |

## Analysis: the ~5M in the founder wallet

- **Origin:** mint #4 at genesis (tx `0x794ff5ba…`, block 41,680,297) — the **LBP allocation (5M) was minted directly to the founder wallet** `0xe585…`. Plus **+2,222.22** received on 2026-05-26 from the E2E-test `redeemBond` (BondVault → founder; tx `0xddea4142…`).
- **Outbound from founder: 0 transfers** — the founder wallet has never sent LUMINA out.
- **Is it an official allocation? YES** — it is the LBP 5M, not a stray residual. **But** it was placed in the founder's **operational EOA** (the same address used as owner/keeper/relayer-admin), not a dedicated LBP/Fjord deposit contract.
- **Recommendation:** before mainnet, mint/transfer the LBP allocation to a dedicated, purpose-controlled address (LBP/Fjord deposit), and keep it segregated from the operational wallet. The 2,222.22 is harmless testnet test residue.

## The "22M not deployed" — where it physically is

Not missing. Minted at genesis to addresses; the **contracts** were never deployed:

| Allocation | Amount | Physically at | Contract status |
|---|--:|---|---|
| CEX/DEX liquidity | 14M | EOA `0x584681a8…1be6` | CEXLiquidityReserve = **0x0 (not deployed)** |
| LBP | 5M | **Founder EOA** `0xe585…` | no dedicated LBP contract |
| Treasury | 3M | EOA `0xaf598c51…7261` | TreasuryVesting not the holder of these |

So Phase-F option (1) is correct for LBP (parked in founder), and CEX/Treasury are parked in two **separate EOAs** (`0x584681`, `0xaf598c`) — likely deployer-controlled, but their key custody is **not documented**.

## Anomalies

| # | Severity | Finding |
|---|---|---|
| A-1 | **MEDIUM** | **17M (CEX 14M + Treasury 3M) held in undocumented EOAs**, not vesting/reserve contracts. Key custody of `0x584681` and `0xaf598c` is unverified. On testnet it's mock value; on mainnet this is real treasury sitting in plain EOAs. |
| A-2 | **MEDIUM** | **LBP 5M minted to the founder's operational EOA** (same wallet as owner/keeper/relayer-admin). Allocation not segregated; a key compromise touches both ops control and 5M of supply. |
| A-3 | **LOW/INFO** | Founder wallet carries **+2,222.22** from the E2E test redeem (BondVault → founder). Expected testnet residue; net-neutral to total supply. |
| — | — | **No supply integrity anomaly.** No duplicate mint, no over-mint, no unexpected mint authority exercised after genesis (only the one genesis tx). |

## Mint authority check

`LuminaTokenV2` mints the full 100M once in `initialize` (genesis tx). No post-genesis mints observed (all balances reconcile to the genesis split minus the single E2E redeem move). Whether a re-mint is *possible* (un-capped `mint`) should be confirmed in code review — out of scope here, but flagged: verify there is no callable `mint` beyond the one-shot initializer before mainnet.

## Recommendations (founder decides; nothing done here)

1. **Mainnet:** deploy CEXLiquidityReserve, TreasuryVesting, and a dedicated LBP deposit; transfer the 14M / 3M / 5M from the EOAs into them **before** or atomically with genesis. Do not launch mainnet with 22M in plain EOAs.
2. **Document the EOA custodians** of `0x584681` (14M) and `0xaf598c` (3M) now, and move them to a multisig if they must stay as EOAs on testnet.
3. **Segregate the LBP 5M** out of the founder operational wallet.
4. **Confirm no un-capped `mint`** exists on `LuminaTokenV2` (code review).
5. Update docs: "CEX/LBP/Treasury not deployed" should clarify *the allocations exist on-chain in EOA custody* (the contracts are pending), so it doesn't read as "unminted".

## Reverse Audit: 9.5/10
Every number is sourced to an on-chain read or the genesis tx (`0x794ff5ba…`, block 41,680,297). Conservation verified exact (100,000,000.00). Mint recipients decoded directly from `Transfer(0x0→…)` events; current balances re-read post-decode. The +2,222.22 cross-checked to the E2E redeem tx.

## Limitations (honest)
- Did not enumerate **every** Transfer event across all 42M blocks (public RPC range limits); instead used the genesis mint block + targeted balance/owner reads + the from=founder filter. Given conservation is exact and founder OUT=0, no hidden movement is possible without breaking the 100M sum.
- Key custody / EOA ownership of `0x584681` and `0xaf598c` was **not** determined (would need off-chain/deployer info).
- `mint`-authority (re-mint possibility) flagged but not code-reviewed here.
- Testnet only (mock value).
