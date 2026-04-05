# LUMINA PROTOCOL — DOCUMENTATION AUDIT
**Date:** 2026-04-04 | **Agents:** Buyer, LP, Tech, Math, Security

---

## SCORE CARD

| Agent | Score | Summary |
|-------|-------|---------|
| A - Buyer Agent | 7/10 | Can operate but missing signature format, 6h trigger fallback, edge cases |
| B - LP Investor | 6/10 | Adequate but cooldown discrepancy (30 vs 37d), no UI walkthrough |
| C - Tech Integrator | 5.5/10 | No OpenAPI spec, no testnet, incomplete ABIs, product ID conflicts |
| D - Math Verifier | 7/10 | BSS waiting=0 in SKILL (should be 1h), M(U) table wrong post-kink |
| E - Security Reviewer | 7/10 | Oracle 2-of-3 claimed but deployed 1-of-1, no RBAC matrix |
| **AVERAGE** | **6.5/10** | Functional but has critical inconsistencies that must be fixed |

---

## TOP 20 GAPS (by impact)

| # | Gap | Impact | Fix |
|---|-----|--------|-----|
| 1 | BSS Waiting Period: SKILL says "None", code says 1h | Agents think coverage starts immediately | Update SKILL to "1 hour" |
| 2 | Cooldown discrepancy: config says 30/90/365, on-chain is 37/97/372 | LPs miscalculate withdrawal timing | Update lumina-config.ts and SKILL |
| 3 | Oracle claimed 2-of-3 but deployed 1-of-1 | False security claim | Change docs to "1-of-1 (planned 2-of-3)" or deploy 2-of-3 |
| 4 | Section 8 M(U) table wrong (1.88 vs 2.25 at 85%) | Premium estimates off by 25-40% | Fix table to match Section 8.1 |
| 5 | No OpenAPI/Swagger spec | Blocks machine-readable integration | Generate from API source |
| 6 | Product ID conflict: BSS vs BLACKSWAN-001 | Integration errors | Consolidate — API accepts both |
| 7 | ExploitShield $150K lifetime cap undocumented | Unexpected reverts for agents | Add to SKILL product table |
| 8 | EIP-712 signature format undocumented | Can't verify/construct signatures | Document domain, types, struct |
| 9 | No testnet/sandbox | Must test on mainnet with real USDC | Deploy testnet contracts |
| 10 | Full CoverRouter ABI not published | Can't interact without reading source | Export ABI JSON to docs |
| 11 | 6h anyone-can-trigger not in user docs | Agents don't know about fallback | Add to SKILL claim section |
| 12 | No dashboard UI walkthrough for LPs | Non-technical humans can't deposit | Add step-by-step with screenshots |
| 13 | Sequencer downtime grace extension not user-documented | Agents don't know about protection | Add to SKILL claim section |
| 14 | No webhooks/events for monitoring | No real-time policy notifications | Document subgraph or add webhooks |
| 15 | No gas cost estimates | Can't budget for transactions | Add estimates per operation |
| 16 | USDC depeg impact on LPs not documented | LPs unaware of risk | Add to risk section |
| 17 | Share price decrease during cooldown not warned | LPs surprised by lower withdrawal | Add explicit warning |
| 18 | No consolidated RBAC matrix | Auditors can't verify permissions | Create roles→functions→contracts map |
| 19 | Premium formula v2 vs v3 inconsistency | Confusion on RiskMult/DurationDiscount | Consolidate into single formula |
| 20 | No "can't collect" scenarios list | Agents don't know edge cases | Add consolidated warning section |

---

## CRITICAL INCONSISTENCIES

| # | File A | File B | Issue |
|---|--------|--------|-------|
| 1 | LUMINA-SKILL.txt "Waiting: None" | BlackSwanShield.sol WAITING=1h | BSS waiting period |
| 2 | lumina-config.ts cooldown:30 | On-chain cooldownDuration:37d | Cooldown values |
| 3 | ANTI-FRAUD-PLAYBOOK "Oracle 2-of-3" | On-chain requiredSignatures=1 | Oracle threshold |
| 4 | SKILL Sec 8 M(85%)=1.88x | PremiumMath.sol M(85%)=2.25x | Kink multiplier |
| 5 | SKILL "BSS/DEPEG/IL/EXPLOIT" | CoverRouter "BLACKSWAN-002" etc | Product IDs |

---

## DUPLICATED INFORMATION (desync risk)

| Info | Locations | Risk |
|------|-----------|------|
| Contract addresses | PRODUCTION-ADDRESSES.md, SKILL.txt, lumina-config.ts, API index.js, whitepaper | HIGH — any update must hit all 5 |
| Product parameters | SKILL Sec 2, SKILL Sec 8, Catalog doc | MEDIUM — 3 versions |
| Cooldown values | SKILL, lumina-config.ts, vault contracts, dashboard | HIGH — 4 locations |
| Premium formula | SKILL Sec 8, PremiumMath.sol, lumina-config.ts | MEDIUM — 3 versions |

---

## RECOMMENDATIONS

| Audience | Ready? | Verdict |
|----------|--------|---------|
| AI agent buying autonomously | **YES with fixes** | Fix BSS waiting, product IDs, add signature format |
| Human LP depositing | **PARTIALLY** | Fix cooldown values, add UI walkthrough, risk docs |
| Developer integrating | **NO** | Need OpenAPI spec, testnet, full ABIs, consistent IDs |
| Auditor auditing | **YES** | Audit V3 + Playbook + Validation doc sufficient |
| Institutional investor | **PARTIALLY** | Fix inconsistencies, add RBAC matrix, historical data |
