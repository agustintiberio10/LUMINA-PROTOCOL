# REPO HYGIENE AUDIT — CROSS-REPO ANALYSIS
**Date:** 2026-04-04 | **Repos:** LUMINA-PROTOCOL, MOLTAGENTINSURANCE, v0-lumina-landing-page

---

## URGENTE (act immediately)

| # | Issue | Location | Action |
|---|-------|----------|--------|
| 1 | **Private key in plaintext** `532ed79f...` in 3 .env files | LP/.env, MOLT/.env, MOLT/bot/.env | Rotate key immediately. Key controls deployer + fee receiver. |
| 2 | **SESSION-SUMMARY publicly served** reveals founder name, infra details, delay=0 history | landing/public/SESSION-SUMMARY-*.md | Delete from public/ |
| 3 | **Security audit publicly served** reveals exact risk scores and weak points | landing/public/SECURITY-AUDIT-*.md | Delete from public/ or accept as transparency |
| 4 | **Claude Setup.exe in public/** | landing/public/Claude Setup.exe | Delete |
| 5 | **Comprobante.pdf in public/** (personal receipt) | landing/public/Comprobante.pdf | Delete |

## IMPORTANTE — Wrong Information (still present after fixes)

| # | Issue | Files Affected | Correct Value |
|---|-------|---------------|---------------|
| 6 | "79 tests" instead of "119" | 15+ locations (page.tsx, whitepapers, CLI, SKILL) | 119 |
| 7 | Cooldowns 30/90/365 instead of 37/97/372 | ~20 locations (SKILL-v2, CLI, whitepapers, DeployUUPS.s.sol) | 37/97/97/372 |
| 8 | BSS waiting "None" instead of "1 hour" | 7+ locations (SKILL-v2, page.tsx, CLI, whitepapers) | 1 hour |
| 9 | M(U) values 1.88/2.63 (wrong post-kink) | 10+ locations (whitepapers HTML, CLI, page.tsx) | 2.25/3.0/3.75 |
| 10 | Oracle "2-of-3" without "planned" qualifier | 4 locations (whitepaper pages, CLI) | 1-of-1 (planned 2-of-3) |
| 11 | Old product names LIQSHIELD/GASSPIKE/SLIPPAGE/BRIDGE | 15+ locations in landing page components | BSS/DEPEG/IL/EXPLOIT |
| 12 | "MoltX" in landing page footer | components/lumina/footer.tsx | Remove or rename |
| 13 | EP V1 address in subgraph not marked deactivated | subgraph/subgraph.yaml, README.md | Update to new EP |

## DUPLICATES

| Type | Count | Recommendation |
|------|-------|---------------|
| SKILL files | 6 versions across repos | Keep only LUMINA-PROTOCOL/docs/SKILL-V3.0.md as source of truth |
| Whitepapers | 4 duplicate PDFs with (1)(2)(3) suffixes | Delete duplicates |
| Security reports | 4 copies in landing public/ | Delete from public/ (keep in LP/docs/) |
| Whitepaper ES V3 md | 3 copies (LP docs, landing public, landing public (1)) | Keep 1, delete rest |

## HYGIENE

| # | Issue | Location |
|---|-------|----------|
| 14 | 5 .backup/.bak files not gitignored | MOLTAGENTINSURANCE/agent/ |
| 15 | .vscode/settings.json committed | landing page |
| 16 | deploy-lumina-output.json, state.json not gitignored | MOLTAGENTINSURANCE |
| 17 | files.zip in api/ | Both repos |

## VERIFIED CORRECT

- All UUPS proxy addresses consistent
- All V1 addresses removed from active docs (except subgraph)
- Governance addresses (Timelock, Safe) correct everywhere
- Chainlink feed addresses correct
- 3 roles (AI Agent, Agent Owner, LP) consistent
- Fee structure (3% premium + 3% payout + 3% perf) consistent
- Product parameters match code (except BSS waiting noted above)
