# Fix C-1 — Marketplace USDC Mismatch (RESOLVED)

**Date**: 2026-05-26
**Network**: Base Sepolia (84532)
**Solution**: **Option B — UUPS upgrade** (added `setUsdc`, then repointed)
**Marketplace proxy**: `0x0938205f4cBe5F572656533FC930FFce6F5F4345`
**Marketplace operativo post-fix**: **SÍ** ✅

---

## Problem
`marketplace.usdc()` returned the deprecated Circle Base Sepolia USDC `0x036CbD53842c5426634e7929541eC2318f3dCF7e` while the protocol migrated to mUSDC `0xD944d8e5D8329994D83950872Ec210891d3Ab6AE`. `executeBuy` reverted `ERC20: transfer amount exceeds allowance` for every (mUSDC-funded) buyer → secondary market unusable. (Found in PR LP#174.)

## Phase A — Diagnosis
| Question | Answer |
|---|---|
| Has `setUsdc`? | **No** (only `setTwapBurner`, `setMinPricePerUnit`). Confirmed on-chain (reverts). |
| UUPS upgradeable? | **Yes** — `_authorizeUpgrade` gated `onlyRole(DEFAULT_ADMIN_ROLE)`. Old impl `0x8b650b51…1b53`. |
| Owner/upgrader = founder? | **Yes** — founder holds `DEFAULT_ADMIN_ROLE` (and `FEE_MANAGER_ROLE`). |
| `usdc` mutable? | **Yes** — `IERC20 public usdc;` (storage), set only in `initialize`. |

→ **Option B**: add a `setUsdc` setter via UUPS upgrade. No new storage var → **storage layout identical** → safe.

## Phase B/C — Solution applied
**Code change** (`src/marketplace/LuminaBondMarketplace.sol`): appended
```solidity
event UsdcUpdated(address indexed oldUsdc, address indexed newUsdc);
function setUsdc(address _new) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_new != address(0), "Zero");
    address old = address(usdc);
    usdc = IERC20(_new);
    emit UsdcUpdated(old, _new);
}
```
No storage layout change (function + event only). `forge build` clean; `setUsdc` present in ABI.

**On-chain (founder key, dry-run → broadcast):**
| Step | Tx | Status |
|---|---|---|
| Deploy new impl `0x677E2B8E8f16962FdC6E85D19AAD7b1b6dD60713` | `0x9f4755cc…0dba4` | ✅ (proxiableUUID matches UUPS slot) |
| `upgradeToAndCall(newImpl, "")` (dry-run OK → broadcast) | `0xf5542a4b…3e86e` | ✅ status 1; impl slot now `…677e2b8e` |
| `setUsdc(mUSDC)` (dry-run OK → broadcast) | `0x46a3c882…59ae` | ✅ status 1 |

## Phase D — Verify fix
`marketplace.usdc()` = **`0xD944d8e5D8329994D83950872Ec210891d3Ab6AE`** ✅ (= mUSDC). Impl slot = new impl ✅.

## Phase E — Re-test buy flow (the fix in action)
Founder listed 40 units (epoch 202805) @ $5 → listing #2. Fresh buyer wallet C funded with mUSDC (faucet was IP-rate-limited from the prior sprint's wallet B, so funded directly from founder: 10 mUSDC + 0.004 ETH gas). Wallet C approved mUSDC → `executeBuy(2)`:

| Invariant | Expected | Actual |
|---|---|---|
| listing #2 active | false | **false** ✅ |
| buyer (C) bond 202805 | 40 | **40** ✅ (bond delivered) |
| seller (founder) bond | 40 | 40 ✅ |
| buyer mUSDC spent | 5,075,000 ($5 + 1.5% buyer fee) | balance 10e6 → **4,925,000** ✅ |
| **TWAPBurner mUSDC** | +150,000 (3% total fee) | 25,744,000 → **25,894,000** ✅ |
| seller proceeds (pull) | 4,925,000 ($5 − 1.5% seller fee) | pending **4,925,000** ✅ |
| founder `withdraw()` | status 1 | ✅ (`0xd9d470e5…913b`) |

**Buy test: PASS.** The 3% fee (1.5%+1.5%) routed exactly to the TWAPBurner; the bond transferred to the buyer; the seller's net was pull-paid and withdrawn. (Some `cast` balance reads lagged by a block — public-RPC lag — but each step's tx `status 1` + the settled balances confirm correctness.)

## Result
- **Solution: Option B (UUPS upgrade + setUsdc).**
- New impl: `0x677E2B8E8f16962FdC6E85D19AAD7b1b6dD60713`. Upgrade `0xf5542a4b…3e86e`, setUsdc `0x46a3c882…59ae`.
- **Buy test post-fix: PASS** (bond transfer + exact 3% fee to TWAPBurner + seller withdraw).
- **Marketplace operativo: SÍ** ✅ — C-1 closed; secondary market is now usable by any mUSDC-funded user.

## Notes / follow-ups (founder)
- **BaseScan verify** the new impl `0x677E2B8E…0713` (cosmetic).
- **Mainnet runbook**: initialize the marketplace with the canonical payment token from the start, and keep `setUsdc` in the deployed impl as an operational lever.
- Update the V5.4 manifest / `lumina_canonical_addresses_v54` with the new marketplace impl.
- ⚠️ The founder private key is in plaintext in `Desktop/instrucciones2.txt` — rotate after this work (already on the standing rotation list).
- ⛔ Draft PR — **do not merge** (per task).
