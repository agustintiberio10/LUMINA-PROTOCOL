# Tareas manuales founder post-merge de Sprint Z.2 cleanup

Las 5 PRs draft del Sprint Z.2 quitan todas las referencias a addresses viejas Sepolia.
Después de mergearlas, hay tareas manuales en plataformas externas que Claude **no
puede** ejecutar. Lista canónica abajo.

> ⚠️ Pre-requisito: NO redeployar contratos antes de completar este checklist. Las
> envs deben quedar VACÍAS hasta que el próximo sprint corra el deploy script (con
> ADR-012 + invariantes intactas) y entregue las direcciones nuevas.

---

## 1. Railway (`lumina-api`)

1. Abrir Railway dashboard → proyecto `lumina-api` → tab **Variables**.
2. **ELIMINAR** estas env vars (lista canónica; agregar las que aparezcan extras):
   - `FOUNDER_VESTING_ADDRESS`
   - `BOND_VAULT_ADDRESS`
   - `LUMINA_TOKEN_ADDRESS`
   - `COVER_ROUTER_ADDRESS`
   - `POLICY_MANAGER_ADDRESS`
   - `TWAP_BURNER_ADDRESS`
   - `CLAIM_BOND_ADDRESS`
   - `LUMINA_ORACLE_V2_ADDRESS` / `ORACLE_V2_ADDRESS`
   - `CAPACITY_ORACLE_ADDRESS`
   - `SOLVENCY_ORACLE_ADDRESS`
   - `MARKETPLACE_ADDRESS` / `BOND_MARKETPLACE_ADDRESS`
   - `BUYBACK_ENGINE_ADDRESS`
   - `SHIELD_KEEPER_ADDRESS`
   - Cualquier `*_SHIELD_ADDRESS`
3. **PRESERVAR** (NO borrar):
   - `RPC_URL`, `BASE_SEPOLIA_RPC_URL`
   - `DATABASE_URL`
   - `ORACLE_PRIVATE_KEY`, `RELAYER_PRIVATE_KEY`
   - `MULTISIG` (cuando lo configures correctamente para el próximo deploy)
   - Cualquier var de Stripe/Sentry/Auth0/Github
4. Trigger deploy manual o esperar a que Railway auto-redeploy desde la branch
   mergeada — la API debe levantar con **addresses vacías**.
5. Post-redeploy (próximo sprint), poblar de nuevo con las direcciones nuevas.

---

## 2. Vercel (`v0-lumina-landing-page`)

1. Abrir Vercel dashboard → proyecto `v0-lumina-landing-page` → **Settings → Environment Variables**.
2. **ELIMINAR** todas las env vars cuyo nombre matchee el patrón:
   - `NEXT_PUBLIC_*_ADDRESS`
   - `NEXT_PUBLIC_CONTRACT_*`
   - `NEXT_PUBLIC_BOND_VAULT*`
   - `NEXT_PUBLIC_COVER_ROUTER*`
   - `NEXT_PUBLIC_LUMINA_TOKEN*`
   - `NEXT_PUBLIC_*_SHIELD*`
3. **PRESERVAR**:
   - `NEXT_PUBLIC_API_URL` (apunta a Railway).
   - `NEXT_PUBLIC_CHAIN_ID` (84532 Sepolia hasta mainnet).
   - WalletConnect project ID.
   - Cualquier var de analytics (PostHog/GA/Vercel Analytics).
4. Trigger redeploy (`Deployments → Redeploy`) — el footer/transparency section
   ya está blanqueado en código a `"Awaiting redeploy post-Sprint Z.2"`.
5. Post-redeploy (próximo sprint), poblar de nuevo con las direcciones nuevas.

---

## 3. npm `@lumina-org/sdk`

1. **NO desinstalar** ni `npm unpublish` v0.5.2 — queda como histórico.
2. La próxima versión `v0.5.3` se publicará **post-redeploy** con las direcciones
   nuevas y CHANGELOG entry referenciando ADR-024.
3. El SDK ya estaba migrado a `getContracts()` runtime helper desde 0.5.2 (Sprint
   redeploy-proof), así que NO hay cleanup adicional en SDK más allá de marcar
   ADR-024 en el próximo release notes.

---

## 4. GitHub (todos los repos)

1. **NO mergear las 5 PRs draft** hasta que el founder valide el diff de cada uno
   (especialmente C.3 `lumina-api` que toca indexer/ponder.config.ts).
2. Después de mergear: borrar las branches `*sprint-z2-cleanup` localmente y en
   remoto.
3. **NO** force-push a main. **NO** rebasear los merge commits.

---

## 5. Multisig configuration (PRE-REDEPLOY GATE)

Antes de correr `script/deploy/DeployLuminaV5Complete.s.sol` en el redeploy:

1. Confirmar que `cfg.multisig` apunte a un Safe **multi-firmante real** (NO al
   deployer EOA). Esto es lo que bricked el SET B antes.
2. El deploy script ya tiene invariantes `require(...)` que aseveran que el
   deployer conserva `DEFAULT_ADMIN_ROLE` post-deploy. Si las invariantes fallan,
   el deploy revierte.
3. Transfer to multisig es un flujo **SEPARADO** post-deploy (ver ADR-012 comment
   block en `DeployLuminaV5Complete.s.sol` L559-580): primero verificar que el
   multisig responde (firmar una noop tx), después grantRole, después revokeRole.

---

## 6. Verificación post-tareas

Después de aplicar 1+2+5:

```bash
curl https://api.lumina-org.com/api/v1/health
```

- **Esperado:** addresses field vacío o `"0x0000…0000"`. Esto es OK — el sistema
  está en "pause" hasta el redeploy.
- **NO esperado:** addresses viejas Sepolia. Si aparecen, alguna env var quedó sin
  borrar — repetir paso 1.

```bash
curl https://lumina-org.com  # landing page
```

- Section8LiveState debe mostrar `"Awaiting redeploy post-Sprint Z.2"` en lugar
  de las direcciones.

---

## Items NO automatizables que requieren tu atención

- [ ] Drenar/recuperar fondos USDC bloqueados en BondVault SET C bricked (si los hubo).
- [ ] Notificar a betatesters (Discord/email) que el testnet está down hasta el redeploy.
- [ ] Decidir si los 9 shields se redespliegan o se mantienen (no estaban en la
      known-list de Sprint Z.2; ADR-024 los preservó como "founder discretion").
- [ ] Decidir destino de BuybackEngine `0xC824…AD5a` y ShieldKeeper `0x474C…DbcF`
      — no entraron en la known-list.

---

_Generado por Sprint Z.2 cleanup. Branch `feat/sprint-z2-cleanup`._
