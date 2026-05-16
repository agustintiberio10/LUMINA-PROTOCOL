# V5.0 Sepolia Deployment — Deprecation Notice

> ⚠️ OBSOLETO — Direcciones citadas blanked en Sprint Z.2 pre-redeploy (bug L476-477).
> Documento conservado como registro histórico. Direcciones se repoblarán post-redeploy.

**Status:** DEPRECATED. Do NOT use.
**Replaced by:** V5.1 redeploy with all 8 fixes applied (audit #32).

---

## 1. V5.0 deployed addresses (Base Sepolia)

| Contract | Address |
|---|---|
| Deployer wallet | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8) --> |
| RPC | `https://base-sepolia.g.alchemy.com/v2/79vtoU18JYDiweaO1njwU` |
| LuminaTokenV2 | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904) --> |
| BondVault | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0x8b4B1E1985e105bb0b50A02F7d1AcD3efc950673) --> |
| ClaimBond | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025) --> |
| CoverRouterV2 | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0x71DBcE71AA36370f7357F6D8E0c8ba96343C8306) --> |
| PolicyManagerV2 | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e) --> |
| MockUSDC | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a) --> |
| MockBTCOracle | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xB52BB8B09Df13dB2D244746688C14A720ceE4C09) --> |
| FlashBTCShield1h | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xDcac6614E6d8CAB79bD655649B5cfdA497f80aeD) --> |

---

## 2. Reasons for deprecation

The V5.0 deployment is **structurally broken** and **incomplete** by V5.1 standards. It is missing every fix landed during the V5.1 audit cycle:

### Code-level bugs in V5.0

| Issue | Audit | Impact |
|---|---|---|
| `configureProduct` parameter mismatch | V5.0 phase 7.8 | Wrong product config wired |
| Product ID mismatches between scripts and shields | V5.0 phase 7.8 | Some products non-functional |
| MicroDepeg / RateShock duration off | V5.0 phase 7.8 | Premiums miscalculated |

### V5.1 fixes NOT in V5.0

| Fix | What it does | Why missing in V5.0 = bad |
|---|---|---|
| **Fix M-01** | TWAPBurner price oracle integration | Burns at unsafe prices in V5.0 |
| **Fix M-02** | TWAPBurner minOut floor on swap | Sandwich-attackable in V5.0 |
| **Fix M-03** | BuybackEngine reads marketplace fee BPS | BuybackEngine over/under-approves |
| **Fix #18** | NFT metadata + restricted ClaimBond transfers | Bonds transferable by anyone — bad UX, anti-grief gap |
| **Fix #26** | recoverToken in 7 fund-holding contracts + LOW-1 event | Stuck tokens unrecoverable |
| **Fix #27** | Admin-setter events on 7 setters | No observability of config changes |
| **Fix #28** | Pause auto-pause hysteresis + KeeperPaused event | Auto-pause flaps near threshold |
| **Fix #31** | Deploy script CRITICAL — `setAuthorizedOperator(marketplace)` | **Marketplace 100% non-functional in V5.0** |

### UUPS migration NOT applied to V5.0

V5.0 was deployed with the original "immutable token" pattern. V5.1 migrated all 24 contracts to UUPS proxies (Phase B/C/D migration in PRs #39-42). The V5.0 deployment **cannot be upgraded** to V5.1 because:

- It's not behind a UUPS proxy.
- Storage layout in V5.0 differs from V5.1 (V5.1 added namespaced storage for ReentrancyGuard via fix #26 etc.).
- Constructor arguments differ.

The only path forward is a fresh V5.1 deploy.

---

## 3. Disposition

- **Do NOT** post any new transactions to V5.0 addresses on Sepolia.
- **Do NOT** reference V5.0 addresses in front-end / API integrations going forward.
- The V5.0 contracts will remain on-chain (Sepolia is testnet, no cleanup needed) but should be considered abandoned.
- Any test USDC / test policy data on V5.0 is lost (acceptable for testnet).

---

## 4. Path forward

1. Audit #32 (this document) — pre-deploy preparation.
2. Founder executes the runbook in `03-DEPLOY-RUNBOOK.md` to deploy V5.1 fresh.
3. Founder records the new addresses in `deployments/sepolia/V5.1-{date}.json`.
4. Founder runs the verify script. If all checks pass, V5.1 Sepolia is operational.
5. Optionally: announce the new addresses to community + update API/front-end integrations.

The V5.0 deployment is then formally retired.
