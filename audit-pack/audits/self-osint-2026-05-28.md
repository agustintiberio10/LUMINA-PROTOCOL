# Self-OSINT — ¿desde Lumina Protocol se llega al nombre real del founder?

**Fecha:** 2026-05-28 · **Tipo:** auditoría defensiva (self-OSINT) · **Punto de partida del "atacante":** solo `lumina-org.com` + repos org-lumina + token público.
**Reglas éticas respetadas:** solo fuentes públicas; sin login; sin contactar terceros; sin scraping autenticado.

---

## 1. Resumen ejecutivo

### ¿Se pudo llegar al nombre real? **SÍ.**
### Pasos desde `lumina-org.com` hasta nombre completo: **2 (caminos múltiples paralelos, todos triviales).**
### Nivel de exposición: 🔴 **CRÍTICO**

Un atacante sin contexto previo necesita literalmente:
1. abrir el repo público vinculado en `npm view @lumina-org/sdk` (`github.com/org-lumina/lumina-sdk`),
2. correr `git log` → ve `Agustin Tiberio <agustin.tiberio@gmail.com>` en el primer commit.

O, alternativa aún más simple (1 paso):
- Buscar en Google: `"Lumina Protocol" "Agustin Tiberio"` → primer página de resultados incluye un perfil Facebook con nombre completo (`Agustin Luis Tiberio`).

Las dos rutas se refuerzan: incluso reescribiendo `git history` (que es irreversible para clones ya hechos), la asociación nombre↔proyecto quedó ya en índices de Google.

---

## 2. Tabla consolidada de PII encontrado

| # | Dato | Fuente exacta (verificable) | Facilidad | Severidad | Cómo eliminarlo |
|---|------|---------------------------|-----------|-----------|------------------|
| 1 | **`Agustin Tiberio`** (nombre real) | `git log` en `lumina-api`, `v0-lumina-landing-page`, `lumina-sdk`, `docs-lumina` (4 de 7 repos) | Trivial (un comando) | 🔴 Crítico | `git filter-repo --mailmap` + force-push (parcial: clones existentes conservan la vieja history) |
| 2 | **`Agustín Tiberio`** (con tilde) | `git log` en `v0-lumina-landing-page` | Trivial | 🔴 Crítico | Mismo fix que #1 |
| 3 | **`agustin.tiberio@gmail.com`** (email personal) | `git log` en 4 repos (mismo set que #1); además aparece como email del autor `org-lumina <agustin.tiberio@gmail.com>` — la identidad "bot" fue committeada con email personal | Trivial | 🔴 Crítico | Mismo fix; aclarar `user.email` a `86575301+org-lumina@users.noreply.github.com` |
| 4 | **`agustintiberio10`** (handle GitHub) | `git log` autores en 6 de 7 repos; primer commit de `lumina-api`, `lumina-mcp`, `lumina-testnet-tracker` (también primer commit del que reescribir history es muy obvio) | Trivial | 🟠 Alto | `git filter-repo --mailmap` + cambiar `user.name` global; pre-commit hook |
| 5 | **`agustintiberio@gmail.com`** (email secundario sin punto) | `git log` en 5 repos como email de `agustintiberio10` | Trivial | 🟠 Alto | Mismo fix |
| 6 | **`Agustin Luis Tiberio`** (nombre completo + segundo nombre) | Resultado web (Google) de `"Lumina Protocol" "Agustin Tiberio"` → enlace a Facebook profile público | Trivial (una búsqueda) | 🔴 Crítico | Privatizar/borrar el perfil de Facebook si es del founder; NO desindexable en Google sin acción sobre Facebook |
| 7 | **`C:\Users\AGUSTIN`** (username Windows) | Committeado en: `LP-econ/docs/audit/v5.1-uups/32-sepolia-redeploy/03-DEPLOY-RUNBOOK.md:12`, `v0-lumina-landing-page/docs/archive/LUMINA-FLASH-DEPLOY-MAINNET.txt:3,147,253`, y otros 3+ archivos en `docs/archive/` | Trivial (grep) | 🟡 Medio | Borrar los archivos `docs/archive/LUMINA-FLASH-*` (eran prompts de desarrollo viejos, ya no se necesitan); reescribir history; pre-commit hook que rechace paths absolutos `C:\Users\` |
| 8 | **Wallet del founder `0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8`** públicamente vinculada al protocolo | `audit-pack/manifests/V5.4-canonical-deployed.json` + decenas de docs/runbooks/deploy JSONs + `FounderVestingV2*.t.sol` constants + private key **expuesta en este chat** | Trivial | 🔴 Crítico | NO usar esa wallet en mainnet (ya marcado en OP-SEC-7 de la auditoría operacional); generar wallet nueva en hardware |
| 9 | **Wallet relayer `0x168dC7105e907294f9d066cee24f30caa5A17E4a`** hardcoded | `LP-econ/script/deploy/DeployShieldsAndAdapters.s.sol:79`, `script/ops/AuthorizeRelayer.s.sol:19` + manifests | Trivial | 🟡 Medio | Wallet nueva para mainnet |
| 10 | **Tiempos/zona horaria del founder** | `git log --format=%ad` muestra timestamps en `-0300` (UTC−3 = Argentina/Uruguay/Chile/Brasil-East/Paraguay). Apellido italiano + zona AR/UY → fuerte señal Argentina | Trivial | 🟡 Medio | Cambiar `git config --global commit.gpgsign true` con clave firmada por identidad bot; o `TZ=UTC` para commits (cosmético) |

### Lo que está LIMPIO (verificado)
- **npm `@lumina-org/sdk` y `@lumina-org/mcp-server`:** `author = "Lumina Protocol"`, `maintainers = lumina-org <support@lumina-org.com>`. Cero PII personal.
- **crt.sh** para `lumina-org.com`: solo el dominio raíz aparece (no hay subdominios olvidados tipo `staging.`/`dev.`/`internal.` con info).
- **Búsqueda orgánica `"Lumina Protocol" founder Base Sepolia parametric insurance`:** el proyecto del founder NO domina los resultados — varios "Lumina" homónimos (un protocolo estético chileno, otro de prediction markets en BNB, un DEX, una OS de digital assets, etc.). El **homonimato actúa como ofuscación accidental** para descubrimiento casual; no para un atacante que ya sabe el nombre.
- **`@lumina-org/mcp-server` (commiteado solo bajo identidad personal):** publicado en npm sin exponer la identidad → la cadena "npm package → autor → email" no funciona acá.
- **Búsqueda `"agustintiberio10" lumina github`** en Google: NO indexa la conexión (la página GitHub del handle existe pero los resultados orgánicos no la traen al frente sin URL exacta).

---

## 3. Cadena de desanonimización más corta

```
          lumina-org.com (público)
                │
                │ (footer / docs / npm)
                ▼
       github.com/org-lumina  ← organización pública
                │
                │ (cualquier repo, especialmente
                │  lumina-api, landing, sdk, docs)
                ▼
       git log  ← 1 comando
                │
                ▼
   "Agustin Tiberio <agustin.tiberio@gmail.com>"
   "agustintiberio10"
   "Agustín Tiberio"
        ┌───────┴────────┐
        ▼                ▼
  Google search       Email lookup
"Lumina + Agustin" → "agustin.tiberio@gmail.com"
        │              en breaches públicos / LinkedIn
        ▼
  Facebook profile
  "Agustin Luis Tiberio"
  (3er nombre + red social
   personal completa)
```

**Mínimo absoluto:** 1 Google search (`"Lumina Protocol" "Agustin Tiberio"`) → perfil Facebook con nombre completo + foto.
**Mínimo "técnico":** 2 comandos (`git clone` + `git log`).
**No hay paso difícil ni gating.** Cualquier persona con curiosidad casual lo encuentra.

### "Single point of doxx"
**No existe** un único dato cuya eliminación corte toda la cadena. El daño está distribuido en:
1. `git history` de 4-6 repos públicos (irreversible salvo force-push + reescritura, y aun así clones existentes mantienen la versión vieja).
2. Resultado #10 de Google (fuera del control directo del repo).
3. Asociación nombre↔proyecto ya cacheada por buscadores y posiblemente por archivos como Wayback (no verificado por rate-limit; **chequealo vos:** https://web.archive.org/web/*/lumina-org.com y https://web.archive.org/web/*/github.com/org-lumina/).

---

## 4. Plan de remediación priorizado

### 🔴 Hacer YA (antes de cualquier announcement público amplio)
1. **`git filter-repo --mailmap`** en los 7 repos para reemplazar `Agustin Tiberio <agustin.tiberio@gmail.com>` y `agustintiberio10 <agustintiberio@gmail.com>` → `org-lumina <86575301+org-lumina@users.noreply.github.com>`. **Force-push**. Cierre de la fuga futura (clones existentes son irrecuperables, pero el mirror oficial queda limpio).
2. **`git config --global user.name "org-lumina"` y `user.email "86575301+org-lumina@users.noreply.github.com"`** en TODAS las máquinas del founder. **Pre-commit hook global** (`~/.githooks/pre-commit`) que rechaza commits con email distinto.
3. **Borrar archivos `docs/archive/LUMINA-FLASH-*.txt`** (landing) y `docs/audit/v5.1-uups/32-sepolia-redeploy/03-DEPLOY-RUNBOOK.md` (LP-econ) — son prompts viejos de desarrollo, ya no necesarios, y filtran `C:\Users\AGUSTIN`. Reescribir history para borrarlos del pasado también.
4. **Privatizar/borrar/renombrar el perfil Facebook** que aparece como `Agustin Luis Tiberio` si es del founder (no puedo verificarlo desde acá). Sin acción ahí, el resultado #10 de Google sigue vivo.
5. **Generar wallet nueva en hardware (Ledger)** para deployer + relayer + oracle de mainnet, NUNCA reusar `0xe585…fDa8`. (Ya marcado en OP-SEC-7 de la auditoría operacional.)

### 🟠 Hacer pronto (semanas)
6. Email separado para Lumina (`founder@lumina-org.com` o similar, no Gmail personal). Usarlo como `git user.email` futuro si querés algo más útil que el noreply.
7. **GitHub:** mover el handle personal `agustintiberio10` fuera de la org (kickearlo); que el único miembro de `org-lumina` sea una cuenta bot/anon distinta. Si el founder lo usa como su personal, crear una segunda cuenta GitHub anon y migrar.
8. **WHOIS:** verificar que `lumina-org.com` tenga **privacy protection** activado (yo no pude verificarlo desde acá — chequealo en https://lookup.icann.org/en/lookup → buscar `lumina-org.com` → ver "Registrant" / "Admin" / "Tech". Si exponen tu nombre real o email personal, activá privacy en el registrar AHORA).
9. **ENS:** chequear si la wallet `0xe585…fDa8` tiene ENS name asociado (https://app.ens.domains/0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8). Si sí y revela algo → renunciar al nombre o transferirlo a una wallet anon.
10. **Wayback Machine:** chequear https://web.archive.org/web/*/lumina-org.com y de los repos. Pedir baja de snapshots viejos via formulario de IA si exponen algo crítico.

### 🟡 Hacer eventualmente
11. Renombrar `docs-lumina` git author identity (el más limpio de los 7) para que sea el modelo a futuro.
12. Revisar perfiles redes sociales del founder (Twitter, LinkedIn, Farcaster) — buscar manualmente si mencionan Lumina. Si sí → decidir si separar identidades.
13. Si el negocio crece: jurisdicción / wrapper legal a nombre LLC/foundation, no a nombre personal.

---

## 5. Lo que NO se pudo verificar (chequealo vos)

Estos checks no los pude completar desde mi entorno (RDAP no devolvió JSON, llamarpc RPC timeout, archive.org rate-limited):

- **WHOIS / RDAP de `lumina-org.com`**: ¿Registrant Name / Email / Address están redactados ("REDACTED FOR PRIVACY") o expuestos? Verificalo en https://lookup.icann.org/en/lookup → search `lumina-org.com`.
- **ENS reverse para `0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8`**: ¿la wallet tiene nombre ENS asociado? Verificalo en https://app.ens.domains/0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8.
- **Wayback / archive.org**: ¿hay snapshots viejos del sitio con información que después se borró? Verificalo en https://web.archive.org/web/*/lumina-org.com.
- **Twitter/X de `@lumina_org` o variantes**: ¿existe? ¿linkea a una cuenta personal? Search manual.
- **LinkedIn**: buscá `"Agustin Tiberio"` + crypto/DeFi en LinkedIn → si tu perfil profesional menciona Lumina como "founder of", **ese es el doxx más institucional posible** (no se borra fácil).
- **`agustin.tiberio@gmail.com` en breaches públicos**: chequealo en https://haveibeenpwned.com/. Si aparece en alguna brecha, los password hashes / metadata adicional están circulando.

---

## 6. Veredicto honesto

El founder es **estructuralmente doxable en ≤2 pasos** desde `lumina-org.com`. La causa no es ningún error de hoy: es la suma de **decisiones de identidad de desarrollo** (config de git con email personal) en **8 meses de commits**. Es **irreversible para los clones existentes** del repo público; el daño en buscadores ya está caché-eado.

El plan de remediación corta la fuga **futura** y reduce la superficie indexable, pero asume con honestidad: **alguien con motivación moderada ya tiene tiempo de sobra para haber capturado todo esto** desde que los repos son públicos. El cálculo correcto es: actuar para reducir descubrimiento casual + asumir que un actor dirigido ya conoce la identidad y planear desde ahí (multisig, hardware wallets, separación legal).

*Auditoría defensiva. Solo fuentes públicas. Sin modificaciones.*
