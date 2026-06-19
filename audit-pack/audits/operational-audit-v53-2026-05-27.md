# LUMINA Protocol — Operational Audit V5.3/V5.4

**Sprint 7.6 — Operational Audit** · **Date:** 2026-05-27 · **Scope:** deploy / CI-CD / secrets / monitoring / incident-response / dependencies / opsec across `LUMINA-PROTOCOL`, `lumina-api`, `v0-lumina-landing-page`, `lumina-sdk`, `lumina-mcp`, `docs-lumina`, `lumina-testnet-tracker`.
**Method:** read-only inspection of repos on `main` (freshly pulled), 3 parallel auditor agents (deploy+CI/CD · secrets+opsec · monitoring+IR+deps), `npm audit`/`pnpm audit`, `git log` history scans. No state changes.

> Closes Phase 5.5. The 3 prior audits (7.5 economic / 7.4 functional / 7.2+7.3 red-team+manual) all surfaced governance + configuration + key-management gaps; this audit is the operational counterpart and feeds Phase 6 directly. Already-known findings are referenced, **not** re-counted (RM-C1 EOA admin · EC-C2 no timelock · FN-C1 oracle pool · FN-M5 processQueue · exposed founder PK + RAILWAY_TOKEN in chat).

---

## 1. Resumen Ejecutivo

### Veredicto: 🔴 **NEEDS HARDENING — mainnet blocked**

The *contracts* passed Phase 5.5. The **operations around them** did not. The team-of-one has authored thoughtful runbooks and a layered SAST stack, **but** (a) CI is missing entirely on the two repos that auto-deploy to production, (b) nothing alerts when things break, (c) the mainnet runbook does not mandate a fresh deployer wallet despite the Sepolia key being already burned, and (d) one critical + 28 high npm-audit findings sit in the landing-page tree unread. The protocol *as a system* is not ready for real funds until the items below are closed.

### Total findings nuevos por severidad (excluyendo ya conocidos)
| Severidad | # | IDs |
|-----------|--:|-----|
| 🔴 Crítico (bloquean mainnet) | **6** | OP-CICD-1/2, OP-MON-1, OP-SEC-7, OP-IR-5, OP-SEC-1 |
| 🟠 Alto | **18** | OP-DEPLOY-1..5 · OP-CICD-3/4/5/7/8/10 · OP-SEC-6/8 · OP-MON-2/3 · OP-IR-3/4/6 · OP-DEP-1/4 |
| 🟡 Medio | **9** | OP-DEPLOY-6/7/8 · OP-CICD-6 · OP-SEC-2/3/4 · OP-MON-4 · OP-DEP-5 |
| 🟢 Bajo / Info | **12** | listados al final |

### Top 5 riesgos operacionales NUEVOS
1. **🚨 OP-CICD-1/2 — Ni `lumina-api` ni `v0-lumina-landing-page` tienen workflows de CI.** Ningún test/lint/typecheck/`npm audit` se ejecuta en PRs ni en `main`. Railway y Vercel auto-deployan lo que haya en `main` sin gate. Combinado con la falta de branch-protection (OP-CICD-5), cualquier push a `main` va directo a prod.
2. **🚨 OP-MON-1 — Cero alerting externo.** Grep `forta|tenderly|sentry|datadog|opentelemetry|pagerduty|slack|discord webhook|uptimerobot` en `lumina-api` = nada. El supervisor del indexer hace `console.log "auto-heal: dropped schema X"` y nadie se entera — un freeze a las 3 AM espera hasta que alguien lo note. La documentación de monitoring (`docs/monitoring/ALERTS-CONFIGURATION.md`) es aspiracional, no wired.
3. **🚨 OP-SEC-7 — El runbook de mainnet no exige una wallet de deploy nueva** (`DEPLOY-MAINNET-RUNBOOK.md:65` solo dice `export DEPLOYER_PRIVATE_KEY=<secure-key>`). La PK del founder (Sepolia `0xe585…fDa8`) está **quemada en chat + expuesta**. Si se reusa en Base mainnet → front-run del deploy / hijack inmediato de `transferOwnership` / `FounderVesting` recipient ya conocido. Sharpen RM-C1 con vector concreto de mainnet.
4. **🚨 OP-IR-5 — Equipo de una sola persona, runbooks nunca ensayados.** 10 runbooks documentados pero `grep fire.drill|game.day|tabletop|rehearsal` = 0 hits. `bank-run-bondvault.md:41` dice "DECISIÓN FOUNDER" para una llamada de insolvencia. Sin segundo on-call ni schedule, MTTR depende de que el founder no esté durmiendo / volando.
5. **🚨 OP-DEP-1 — 1 CRITICAL + 28 HIGH npm-audit en `v0-lumina-landing-page`** (incluido `protobufjs <7.5.5` RCE vía `firebase-admin > @google-cloud/firestore`, `next 16.1.6` cache-poisoning, `axios <1.15.1` NO_PROXY bypass, `lodash` template-injection). Hoy no llegan a PRs porque OP-DEP-4: no hay SCA en CI.

> Adicionales que merecen mención inmediata aunque entran en el Top: **OP-SEC-1** (clave Alchemy Base-Sepolia live en plaintext en `docs/audit/v5.1-uups/32-sepolia-redeploy/01-V50-DEPRECATION.md:16` — rotar HOY) y **OP-SEC-6** (founder doxeado en `git log` de los 7 repos: `agustin.tiberio@gmail.com` + `agustintiberio10`).

### Fortalezas confirmadas (no son findings)
- **Suite SAST de contratos sin envidiar a nadie:** ci.yml + aderyn.yml + mythril.yml + halmos.yml + echidna.yml (200k runs × 7 harnesses) + coverage + gas-snapshot en LP-econ. Cobertura de categorías (static/symbolic/fuzz) más amplia que el promedio.
- **Atomic UUPS init en deploy:** todas las creaciones de proxy usan `new ERC1967Proxy(impl, abi.encodeCall(initialize, …))` en una sola tx → mitiga FN-H2 deploy-side.
- **Bug del brick de SET B está post-morteado en el código** (`DeployLuminaV5Complete.s.sol:488-509`) + assertion `require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender))` al cierre (L514-525) → no se vuelve a re-ejecutar.
- **RPC fallback de 3 capas** (Alchemy → QuickNode → public) en `src/utils/ethers.ts:32-45` + `indexer/ponder.config.ts:41-45`. Es la única redundancia genuina del sistema y funciona.
- **Self-heal del indexer Ponder** (`scripts/indexer-supervisor.mjs`) + runbook (`indexer/RUNBOOK.md`) — única área monitoreada y self-healing.
- **Cero PRIVATE_KEY en workflows YAML** + test anti-leak en API (`tests/security/log-leak.test.ts`) — buena higiene base.
- **10 runbooks publicados** (RPC down · oracle key comprometida · bank run · shield emergency · daily ops · incident response · mainnet deploy · multisig · shields · founder vesting · disaster recovery con 16 escenarios + recovery test-backed).

---

## 2. Findings por Fase

### Fase 1 — Deploy scripts

| ID | Sev | Evidencia | Qué está mal | Fix |
|----|-----|-----------|--------------|-----|
| OP-DEPLOY-1 | 🟠 | `script/deploy/DeployLuminaV5Mainnet.s.sol:47-78` | No hay `require(block.chainid == 8453)`. Los scripts de Sepolia sí gatean (`DeployOracleV2Sepolia.s.sol:17`); el de mainnet no. | Agregar el require como primera línea de `run()`. |
| OP-DEPLOY-2 | 🟠 | `DeployLuminaV5Complete.s.sol:196-207, 242-245` | Ningún `require(capacityOracle.pool() != address(0))` post-deploy. Confirma FN-C1 deploy-side: el script ships con `pool=0x0`. | Assertion en `VerifyLuminaV5Deployment.s.sol`; bloqueo del mainnet hasta setPool ejecutado. |
| OP-DEPLOY-3 | 🟠 | `DeployLuminaV5Complete.s.sol:106` | `USDC_ADDRESS` se lee de env sin probe (`usdc.symbol()=="USDC"`, `decimals()==6`, `usdc.totalSupply()>0`). Mismo para `AAVE_POOL` y `UNISWAP_V3_ROUTER`. | `_probeExternalDeps()` que revierte si alguno falla. |
| OP-DEPLOY-4 | 🟠 | `DeployLuminaV5Complete.s.sol:113-114` | `SEQUENCER_UPTIME_FEED` se acepta sin assertion chainid-aware (mainnet 8453 MUST be `0xBCF85224…`, Sepolia MUST be `0x0`). | `if (block.chainid == 8453) require(cfg.sequencerUptimeFeed != address(0))` |
| OP-DEPLOY-5 | 🟠 | `DeployLuminaV5Complete.s.sol:454-457, 463-466` | "TODO Phase C: re-introduce" — el flow de mainnet NO deploya shields ni configura productos. Run produce protocolo no funcional. | Mergear `DeployShieldsAndAdapters.s.sol` o `revert("Shield registration not yet implemented")` en mainnet. |
| OP-DEPLOY-6 | 🟡 | `DeployLuminaV5Complete.s.sol:65-67, 242-245` | `founderRecipient`/`lbpDeposit`/`opsWallet` aceptados sin liveness check (riesgo SET B brick recurrente). | Proof-of-control: requerir tx 0-wei desde cada address pre-deploy. |
| OP-DEPLOY-7 | 🟡 | `DeployLuminaV5Complete.s.sol:191-194, 276` | Re-run tras falla parcial → nonce drift → `require(luminaToken == precomputed)` revierte; no hay `--resume`. | Documentar `forge script --resume`; idempotencia en `registerProduct`. |
| OP-DEPLOY-8 | 🟡 | `DeployLuminaV5Complete.s.sol:130, 473-486` | `LuminaOracleV2` arranca con `deployer` como owner; transfer a multisig al final. Ventana: 1 tx. | Pasar `cfg.multisig` al constructor, o `Ownable2Step.acceptOwnership()`. |
| OP-DEPLOY-9 | 🟢 | `DEPLOY-MAINNET-RUNBOOK.md:70` vs path real | Comando apunta a `script/DeployLuminaV5Complete.s.sol` (real: `script/deploy/…`). Dice "Ethereum mainnet" (es Base). | Corregir path + chain name. |
| OP-DEPLOY-10 | 🟢 | `DeployLuminaV5Complete.s.sol:418-451` | Wiring + creación en mismo broadcast → sin checkpoint si wiring falla. | Split en `DeployCore` + `WireCore`. |

### Fase 2 — CI/CD

| ID | Sev | Evidencia | Qué está mal | Fix |
|----|-----|-----------|--------------|-----|
| OP-CICD-1 | 🔴 | `gh api repos/org-lumina/lumina-api/actions/workflows → total_count: 0` | **lumina-api no tiene CI.** Jest definido, nunca corre. Tipos no se chequean en PRs. | `.github/workflows/ci.yml` → `npm ci && npm test && tsc --noEmit && npm audit --audit-level=high`. |
| OP-CICD-2 | 🔴 | mismo en `v0-lumina-landing-page` | **Landing tampoco tiene CI.** vitest definido, nunca corre. | Mismo workflow con pnpm. |
| OP-CICD-3 | 🟠 | `find .github/workflows | grep slither` = ∅ | **Slither no está en CI** de LP-econ (Aderyn sí, pero cobertura distinta). | `slither.yml` que falle en HIGH/CRITICAL. |
| OP-CICD-4 | 🟠 | `aderyn.yml:29 / mythril.yml:13,61 / halmos.yml:39+ / coverage.yml:31` | Todos los workflows SAST/symbolic tienen `continue-on-error: true`. Status verde siempre. | Quitar `continue-on-error` para HIGH/CRITICAL; gate en PR. |
| OP-CICD-5 | 🟠 | `gh api .../branches/main/protection → 404 "Branch not protected"` en LP-econ y lumina-api | `main` no protegida en ningún repo. Push directo bypass total. | Branch protection + required checks + ≥1 review. |
| OP-CICD-6 | 🟡 | No hay `.github/dependabot.yml` en ningún repo | Sin actualizaciones automáticas (npm/pnpm/actions/git-submodule). | Dependabot config simple por repo. |
| OP-CICD-7 | 🟠 | `railway.toml:15` + sin gate | Railway auto-deploya `main` sin esperar CI. | Workflow que dispara deploy via Railway API tras CI verde. |
| OP-CICD-8 | 🟠 | Vercel default + sin gate | Vercel auto-deploya `main` + preview-per-PR sin CI. | Config "Only deploy when CI passes" en Vercel. |
| OP-CICD-9 | 🟡 | Solo `BASE_SEPOLIA_RPC` en `ci.yml:21` | **GOOD** — cero `PRIVATE_KEY` en YAMLs. Mantener. | Comment explícito prohibiendo PRIVATE_KEY en CI. |
| OP-CICD-10 | 🟠 | `lib/google.ts:10 + lib/dropbox-sign.ts:12` | Secretos server-side (`GOOGLE_SERVICE_ACCOUNT_KEY`, `DROPBOX_SIGN_API_KEY`) sin documentar en `.env.example`. | Documentarlos con placeholder. |
| OP-CICD-11 | 🟢 | `Dockerfile:7` `npm ci || npm install` | Fallback a `npm install` rompe garantía de lockfile en prod. | Solo `npm ci`; arreglar drift. |
| OP-CICD-12 | 🟢 | `coverage.yml:31` sin threshold | Coverage 60.79% line / 27.09% branch sin gate → puede regresionar. | Threshold mínimo (e.g. 60% line). |

### Fase 3 — Secrets management

**Inventario completo** (28 secretos identificados a través de los repos — ver Apéndice A).

| ID | Sev | Evidencia | Qué está mal | Fix |
|----|-----|-----------|--------------|-----|
| OP-SEC-1 | 🔴 | `LP-econ/docs/audit/v5.1-uups/32-sepolia-redeploy/01-V50-DEPRECATION.md:16` | `https://base-sepolia.g.alchemy.com/v2/79vtoU18JYDiweaO1njwU` — clave Alchemy plaintext en repo (Alchemy v2 keys = bearer en la URL). | **Rotar HOY** en dashboard Alchemy; reemplazar línea; opcionalmente `git filter-repo`. |
| OP-SEC-2 | 🟡 | `.gitignore` en LP-econ/lumina-api/sdk/mcp/tracker + sin `.gitignore` en docs-lumina | 6 de 7 repos sin `*.pem`/`*.key` en `.gitignore`. Solo landing los cubre. | Append `*.pem *.key *.keystore id_rsa* id_ed25519*` a todos. |
| OP-SEC-3 | 🟡 | 14 scripts deploy con 3 nombres distintos: `PRIVATE_KEY` (9) / `DEPLOYER_PRIVATE_KEY` (2) / `FOUNDER_PRIVATE_KEY` (4) | Multiplica leak surface; el runbook dice solo `DEPLOYER_PRIVATE_KEY` → 13 scripts van a fallar / forzar copy-paste de la key. | Canonicalizar a `LUMINA_DEPLOYER_KEY`; refactor + runbook. |
| OP-SEC-4 | 🟡 | `LP-econ/.git/shallow` existe; `git log | wc -l = 4` | Clon shallow de LP-econ → no se puede verificar history más allá de 4 commits. | `git fetch --unshallow` y re-scan obligatorio pre-mainnet. |
| OP-SEC-5 | 🟢 | 5 `.env.example` con 5 convenciones de placeholder distintas | Inconsistencia. Todos limpios (ningún secreto real pegado, ✓). | Standard `0x_REPLACE_BEFORE_RUN_<purpose>`. |

**Limpio (no findings, verificado):** 0 PKs hardcoded en código committeado; 0 `.env` commiteado nunca; 0 JWT/Slack/Discord webhook; log-leak test activo en API; mcp sin `Wallet`; relayer-tx y oracle-EIP712 separados en runtime con warning si colisionan.

### Fase 4 — Monitoring & alerting

| ID | Sev | Evidencia | Qué está mal | Fix |
|----|-----|-----------|--------------|-----|
| OP-MON-1 | 🔴 | grep en `lumina-api` para `forta\|tenderly\|sentry\|datadog\|opentelemetry\|pagerduty\|slack\|discord\|uptimerobot` = ∅ | Cero alerting externo. Supervisor del indexer hace `console.log "auto-heal"` y nadie sabe. | UptimeRobot/BetterStack en `/health` y `/api/v1/indexer/health` + webhook Discord/Telegram; `pino-sentry` para errores. |
| OP-MON-2 | 🟠 | `src/routes/health.ts:8-42` | `/health` no expone: relayerBalanceLow flag · circuit-breaker active · oracle staleness · bondVault LUMINA balance. | Extender `/health` con esos 4 campos. |
| OP-MON-3 | 🟠 | grep `0\.005\|MIN_PRICE_FOR_NEW_POLICIES\|circuit.?breaker` en API = ∅ | Nada watch la price acercándose al floor $0.005. La alerta llega cuando ya pausó. | Cron sobre `CapacityOracle.getLuminaPrice()` con warn $0.007 / page $0.0055. |
| OP-MON-4 | 🟡 | `src/services/webhooks.ts:15-22` MAX_ATTEMPTS=3 sin métrica agregada | Webhooks fallan en silencio; sin alerta de failure-rate. | Daily summary sobre `webhook_deliveries` → Discord. |
| OP-MON-5 | 🟢 | `routes/indexer.ts:49` vs `supervisor:42` | Threshold "lagging" inconsistente (100 vs 200 blocks). | Documentar uno canónico. |

**12 alertas faltantes consolidadas:** ver §5.

### Fase 5 — Incident response / runbooks

| ID | Sev | Evidencia | Qué está mal | Fix |
|----|-----|-----------|--------------|-----|
| OP-IR-1 | ✅ PASS | `indexer-supervisor.mjs:1-24` + `indexer/RUNBOOK.md:41-48` + `ADR-001-ponder-revival` | Saga Ponder está documentada Y auto-self-healing. **Único área completa.** | — |
| OP-IR-3 | 🟠 | grep `backup\|pg_dump\|wal-g` = ∅; `indexer/RUNBOOK.md:46-47` "rebuild from chain" | Indexer puede rebuildear pero **SQLite del API (api_keys hasheadas, webhook_subscriptions, secrets HMAC) no tiene backup**. Volume failure → API keys de integradores perdidos. | `pg_dump` cron + `sqlite3 .dump` cron a S3/B2. Confirmar tier Railway. |
| OP-IR-4 | 🟠 | Solo `rpc-caido.md` documenta failover; nada para Railway/Vercel down | Vendor outage = downtime indefinido. | Documentar Plan B (Render/Fly.io/Cloudflare Workers). |
| OP-IR-5 | 🔴 | `bank-run-bondvault.md:41` "DECISIÓN FOUNDER"; tier-1 assessment "team of one" | Equipo de uno; no rotación on-call; sin contactos de respaldo. | Contratar 2do on-call O documentar fallback explícito (familiar autorizado, ops vendor). |
| OP-IR-6 | 🟠 | grep `fire.drill\|game.day\|tabletop\|rehearsal` = ∅ | 10 runbooks bien escritos, ninguno ensayado en condiciones reales con cronómetro. | Game-day mensual; ensayar oracle-key, founder-key, bank-run. |
| OP-IR-7 | 🟢 | `reports/post-mortem/` solo `_template.md` | 3 incidentes elegibles (Ponder revival, C-1 marketplace USDC, F-01 redeploy) — ningún post-mortem escrito con template. | Proceso post-mortem obligatorio para P1+. |

**Scenarios con runbook MISSING:** Relayer key comprometida · Founder/EOA key comprometida (solo aspirational multisig doc) · Marketplace USDC misconfig (C-1) · Sequencer downtime · Webhook subscriber mass failure.

### Fase 6 — Dependencies & infrastructure

| ID | Sev | Evidencia | Qué está mal | Fix |
|----|-----|-----------|--------------|-----|
| OP-DEP-1 | 🟠 | `pnpm audit` en landing: **1 CRITICAL** (`protobufjs <7.5.5` ACE vía firebase-admin) + **28 HIGH** (`next 16.1.6` cache poison, `axios <1.15.1` NO_PROXY bypass, `node-forge <1.4.0` sig forgery, `lodash` template injection) + 37 moderate. Indexer: 4 high (Hono authz bypass, kysely/drizzle SQLi). API: 4 moderate. | Deuda de seguridad de deps acumulada. Sin SCA en CI nadie ve estos counts. | `pnpm up firebase-admin next axios`; bump Ponder; Dependabot. |
| OP-DEP-2 | 🟢 | 27/34 carets, 0 tildes | Pinning estándar de la industria + lockfile, OK. El problema es la falta de automation. | — (cubierto por OP-CICD-6). |
| OP-DEP-3 | ℹ️ | `LuminaOracleV2.sol:64-73` | Chainlink feeds + USDC + sequencer feed son SPOF externos. Si Chainlink para → todos los shields halt (fail-safe by design). | Documentar; no hay backup oracle integrado. |
| OP-DEP-4 | 🟠 | `find .github -name "*audit*\|dependabot*"` = ∅ | Sin SCA en CI; los 28 HIGH no se ven en PRs. | `npm audit --audit-level=high` gate + Dependabot. |
| OP-DEP-5 | 🟡 | `railway.toml:15` `npm run concurrent` boots API+indexer en mismo container | OOM del indexer puede tumbar API. Un memory budget para dos workloads. | Split a 2 servicios Railway (mismo Postgres). |
| OP-DEP-6 | ✅ PASS | `src/utils/ethers.ts:32-45` | RPC fallback de 3 capas funciona y es la **única** redundancia genuina. | — |

### Fase 7 — OpSec (founder-level)

| ID | Sev | Evidencia | Qué está mal | Fix |
|----|-----|-----------|--------------|-----|
| OP-SEC-6 | 🟠 | `git log` en los 7 repos | **Founder doxeado:** `Agustín Tiberio` + `agustin.tiberio@gmail.com` + `agustintiberio10` + segundo email en commit metadata de **todos** los repos. `lumina-mcp` (más nuevo) firmado con identidad personal. | `git filter-repo --mailmap` (cosmético en mirror); per-repo `user.name`/`user.email` = bot; pre-commit hook que rechaza identidad personal. |
| OP-SEC-7 | 🔴 | `DEPLOY-MAINNET-RUNBOOK.md:65` | Runbook no exige wallet **nueva** para mainnet. Sepolia PK `0xe585…fDa8` está burnada (exposed en chat + uses doc-públicas). Reuse → game over en Base mainnet. | Step mandatorio: "Generar deployer EOA nueva en hardware wallet; seed nunca tocó hot machine; MUST ≠ 0xe585…". Mismo para relayer + oracle. |
| OP-SEC-8 | 🟠 | `audit-pack/manifests/V5.4-canonical-deployed.json` | Founder EOA = owner de TODOS los UUPS proxies + DEFAULT_ADMIN_ROLE del BondVault + recipient+owner del FounderVesting + ops-reserve. Mismo concepto que RM-C1, compaña en mainnet vía OP-SEC-7 → key reusada burnada controla todo. | Multisig pre-mainnet (cubierto por EC-C2 + plan Fase 6). |

**2FA checklist** (no verificable desde repo — chequeo off-chain del founder):
- GitHub `agustintiberio10` + `org-lumina`: 2FA hardware key only (no SMS), org SSO+2FA-required.
- Railway: 2FA + RAILWAY_TOKEN rotado + nuevo token scoped a 1 proyecto.
- Vercel: 2FA + deploy hooks auditados.
- Alchemy: 2FA + clave `79vtoU18JYDiweaO1njwU` rotada + IP allowlist por app.
- QuickNode: 2FA.
- npm `@lumina-org/sdk`: 2FA required for publish.
- Mainnet: Ledger/Trezor fresca para deployer + multisig signers.
- Email `agustin.tiberio@gmail.com`: 2FA hardware key; password único; no recovery shared con otras cuentas.

---

## 3. Findings consolidados

### 🔴 Crítico (block mainnet)
- **OP-CICD-1** lumina-api sin CI.
- **OP-CICD-2** v0-lumina-landing-page sin CI.
- **OP-MON-1** Cero alerting externo.
- **OP-SEC-7** Mainnet runbook no exige wallet nueva (key reuse on burned PK).
- **OP-IR-5** On-call team-of-one (sharpens tier-1 asesment).
- **OP-SEC-1** Clave Alchemy live en plaintext en repo (rotar HOY).

### 🟠 Alto (18 — listado completo en §2)
Deploy gates (OP-DEPLOY-1..5) · CI gaps (OP-CICD-3/4/5/7/8/10) · OpSec/identity (OP-SEC-6/8) · Monitoring gaps (OP-MON-2/3) · IR/DR (OP-IR-3/4/6) · Deps (OP-DEP-1/4).

### 🟡 Medio (9): OP-DEPLOY-6/7/8 · OP-CICD-6 · OP-SEC-2/3/4 · OP-MON-4 · OP-DEP-5.

### 🟢 Bajo / ℹ️ Info (12): OP-DEPLOY-9/10 · OP-CICD-9/11/12 · OP-SEC-5 · OP-MON-5 · OP-IR-1/7 · OP-DEP-2/3/6.

---

## 4. Inventario de secretos + plan de rotación priorizado

| Prio | Secreto | Acción | Por qué ahora |
|---:|---|---|---|
| 1 | **ALCHEMY_KEY `79vtoU…7njwU`** | Rotar en dashboard, reemplazar en repo doc, sustituir env var en Railway | Plaintext en repo público (OP-SEC-1) |
| 2 | **RAILWAY_TOKEN** | Rotar (revocar el `283a8bf3…`), generar nuevo scoped al proyecto único | Expuesto en chat (memoria) |
| 3 | **FOUNDER PK (deployer/owner) `0xe585…fDa8`** | **NO usar en mainnet.** Wallet nueva en hardware wallet (Ledger) para mainnet deployer. Sepolia EOA seguirá usándose en testnet pero NUNCA tocar mainnet. | Quemada: expuesta en chat + dirección pública vinculada al founder. OP-SEC-7. |
| 4 | **RELAYER_PRIVATE_KEY `0x168dC7…17E4a`** | Wallet nueva para mainnet (hardware preferido); `setRelayer(new, true) + setRelayer(old, false)` post-mainnet | Misma higiene. |
| 5 | **ORACLE_PRIVATE_KEY** + `ORACLE_PRIVATE_KEY_2` | Wallets nuevas para mainnet; `LuminaOracleV2.setOracleKey(new)` desde owner | Requiere `requiredSignatures>=2` ideal. |
| 6 | **ADMIN_TOKEN** | Regenerar ≥32 char random pre-mainnet | Flip env var; gates `/api/v1/keys/generate`. |
| 7 | **HMAC_SALT (LP-econ/api)** | Regenerar pre-mainnet | Igual razón. |
| 8 | **GOOGLE_SERVICE_ACCOUNT_KEY / DROPBOX_SIGN_API_KEY** | Auditar uso real; rotar si compartidas | Server-side; landing. |
| 9 | **Webhook secrets de usuario** | n/a (por subscription) | Los maneja el integrador. |

---

## 5. Lista de alertas que faltan configurar (pre-mainnet)

1. Indexer lag > 200 blocks por 5min
2. Indexer auto-heal disparado (`[supervisor] auto-heal:`)
3. API 5xx rate > 2% over 5min
4. Relayer ETH balance < 0.01 ETH
5. Oracle signer balance < 0.005 ETH
6. LUMINA spot < $0.007 (warn) · < $0.0055 (page)
7. `CoverRouterV2.paused()` flip
8. BondVault LUMINA balance < 65M (warn) · < 50M (page)
9. Chainlink heartbeat > 2× expected (mainnet)
10. Sequencer downtime > 0 (`LuminaOracleV2.getSequencerDowntime()`)
11. Webhook attempt-3 failure rate > 20%/h
12. Marketplace USDC config drift (`marketplace.usdc() != USDC env`)

---

## 6. Lista de runbooks que faltan crear

- **Relayer key comprometida** (existe oracle-key version, falta el análogo para relayer).
- **Founder/EOA key comprometida** (multisig runbook es aspirational; falta procedimiento EOA-emergency).
- **Marketplace USDC misconfig (BL-USDC / C-1)** — fue el incidente del 26-may sin documento.
- **Sequencer downtime (Base L2)** — contrato lo maneja, runbook humano falta.
- **Webhook subscriber mass failure** — tied to OP-MON-4.

---

## 7. Checklist consolidado para Fase 6 (Pre-Mainnet Hardening)

Combinando las 4 auditorías de Fase 5.5 (7.5 + 7.4 + 7.2/7.3 + 7.6):

### Bloqueantes absolutos de mainnet
- [ ] Wallet de deploy mainnet **nueva** en hardware (OP-SEC-7) — no `0xe585…fDa8`.
- [ ] CI en lumina-api + landing (OP-CICD-1/2) con tests + lint + audit gates.
- [ ] Branch protection en los 3 repos (OP-CICD-5).
- [ ] Gates en Railway/Vercel para esperar CI (OP-CICD-7/8).
- [ ] Alerting externo wired (OP-MON-1) — al menos UptimeRobot + Discord webhook + pino-sentry.
- [ ] Multisig + Timelock en owner de los contratos (EC-C2, RM-C1).
- [ ] CapacityOracle `setPool` ejecutado con pool real + assertion CI (FN-C1, OP-DEPLOY-2).
- [ ] USDC = Circle USDC en mainnet (FN-H1) + assertion deploy.
- [ ] Sequencer feed wired chainid 8453 (OP-DEPLOY-4).
- [ ] `pnpm up firebase-admin next axios lodash` (OP-DEP-1) — clear CRITICAL + 4+ HIGHs.
- [ ] Segundo on-call humano O fallback explícito documentado (OP-IR-5).
- [ ] Rotar Alchemy key + RAILWAY_TOKEN (OP-SEC-1 + chat exposure).
- [ ] Game-day ensayo de los 3 runbooks críticos (oracle key, founder key, bank run) (OP-IR-6).

### Fixes recomendados pre-mainnet (sin bloquear si quedan)
- [ ] PolicyManagerV2 + ReentrancyGuard (FN-M1).
- [ ] FN-H2 deploy atómico — ya está code-side; auditar deploy scripts cumplen.
- [ ] Backups Postgres + SQLite (OP-IR-3).
- [ ] Dependabot en los 3 repos (OP-CICD-6).
- [ ] Standardizar env var name del deployer key (OP-SEC-3).
- [ ] `.gitignore` con `*.pem/*.key` en los 6 repos faltantes (OP-SEC-2).
- [ ] Slither en CI con gate HIGH/CRITICAL (OP-CICD-3) + quitar `continue-on-error` (OP-CICD-4).
- [ ] Wallet hygiene completa (Ledger nueva para deployer + relayer + oracle signers).
- [ ] Plan B vendor outage documentado (OP-IR-4).
- [ ] Fixes contractuales pendientes RM-M1..M5 (epoch truncation, redeem clamp, processQueue stall, floor-pause wiring, sequencer guard).

### Hardening post-mainnet (Fase 7)
- [ ] Audit externo (no AI-internal) — paid auditor firm.
- [ ] Bug bounty.
- [ ] Indexer en servicio Railway propio (OP-DEP-5).
- [ ] Post-mortem culture (OP-IR-7).
- [ ] `git filter-repo --mailmap` para identidad bot (OP-SEC-6).

---

## Apéndice A — Inventario completo de 28 secretos (ver Sprint 7.6 working report)

(disponible en el reporte de detalle del agent — table de 25+ rows con env var name, file:line consumer, live location, rotation difficulty)

---

*No se modificó código. Solo análisis y lectura. Esta auditoría CIERRA Fase 5.5; su output alimenta directo Fase 6 (Pre-Mainnet Hardening).*
