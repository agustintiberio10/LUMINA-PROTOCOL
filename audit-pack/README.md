# Audit Pack — Lumina V5.1

**Última actualización**: 2026-05-18 (Sprint Reconexión)
**Status**: ACTIVO — documento vivo, se actualiza en cada sprint

## Propósito

Trackear exhaustivamente:

1. **Qué se ha auditado** al día de hoy (con números concretos y verificables en CI).
2. **Qué quedó pendiente** (con razón explícita de por qué aún no se cubrió).

El audit-pack es la "fuente de verdad" del estado de aseguramiento del protocolo. Quien quiera saber qué tan probado está Lumina V5.1 abre estos 2 documentos.

## Estructura

| Archivo | Contenido | Actualización |
|---|---|---|
| [`what-we-tested.md`](./what-we-tested.md) | Todo lo auditado al día de hoy (9 categorías) | Cada sprint que agregue tests o suba números |
| [`what-is-pending.md`](./what-is-pending.md) | Lo que NO está cubierto y por qué (12 items abiertos) | Cada sprint que cierre o agregue gaps |

## Política de mantenimiento

### Cuándo actualizar

El audit-pack se **ACTUALIZA en CADA sprint** donde:

- Se agreguen tests nuevos → mover items de `what-is-pending.md` a `what-we-tested.md` con fecha.
- Se descubra un gap nuevo → agregar a `what-is-pending.md` con razón explícita.
- Cambien los números: tests passing, Echidna properties, runs totales, contratos Halmos, workflows CI, ADRs.

### Cómo actualizar

1. Al **iniciar** un sprint nuevo: abrir `audit-pack/` y revisar ambos documentos.
2. Identificar qué items se van a cerrar (o abrir) en ese sprint.
3. Al **cerrar** el sprint, antes del commit final del sprint:
   - Editar `what-we-tested.md` con los números nuevos.
   - Mover items completos de `what-is-pending.md` → `what-we-tested.md`.
   - Agregar un entry al **Changelog** de cada documento con la fecha (YYYY-MM-DD) + el sprint que lo generó.
4. Incluir la actualización del audit-pack como un **paso explícito en la lista de tareas del sprint** (parte del DoD, "definition of done").

### Quién actualiza

- **Founder**: aprueba los cambios.
- **Claude Code (sprint runner)**: ejecuta la actualización siguiendo el template.
- **Cada sprint**: el sprint actual debe incluir update del audit-pack como tarea, no como afterthought.

### Versionado

Cada sprint que toque el audit-pack debe:

- Agregar un entry al Changelog del archivo modificado.
- Formato: `- YYYY-MM-DD (Sprint XX): <breve descripción del cambio>`.
- Si el sprint cambia números (tests, runs, properties): actualizar el header "Última actualización" + "Última verificación de números".

## Resumen rápido (snapshot al 2026-05-18)

### Auditado ✅

- **2996 tests passing** (0 failed, 24 skipped sobre 3020 total).
- **74 Echidna properties PROVEN** sobre **13.2M runs** (200k × cada una).
- **4 contratos** con verificación formal Halmos.
- **18 tests fork Sepolia** con `LuminaOracleV2 SET A` real (`0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194`).
- **50 stress tests** adversariales (económicos / técnicos / timing / multi-shield).
- **14 workflows CI** activos en cada push (Aderyn, Mythril, Slither vía CI step, Halmos, Echidna matrix de 8 contratos, Coverage, Gas Snapshot, build + test + fmt).
- **ADRs 010-027** documentando 18 decisiones arquitectónicas.
- **Sprint Deploy V5.2 ejecutado** 2026-05-18: 26 contratos deployados a Base Sepolia, 16/16 Phase C checks PASS, 0.000302 ETH gastados.
- **Sprint Reconexión completado** 2026-05-18: API Railway + landing Vercel + SDK 0.5.3 + audit-pack actualizados. 3/5 E2E tests PASS (D.3/D.4 skipped por USDC balance founder=0).

### Pendiente ⏳ (12 items abiertos)

1. Halmos cobertura sobre 23 contratos restantes (timeouts en algunos, Echidna ya cubre).
2. Differential fuzzing.
3. Simulación de escenarios de mercado completos.
4. Aave V3 integration extrema.
5. LBP testing (post-deploy mainnet).
6. Multi-DEX routing edge cases.
7. Análisis actuarial de umbrales.
8. Análisis económico de los 3 paths FounderVesting.
9. Oracle assumptions validation.
10. Stress testing con flash loans reales.
11. Multi-block sequences extensas en Echidna (`seqLen > 100`).
12. Gas optimization analysis dirigida.

## Changelog del audit-pack

- **2026-05-18 (Sprint Reconexión)**: Sección 11 agregada a `what-we-tested.md` con resultados E2E (3 PASS + 2 SKIPPED). Item 13 agregado a `what-is-pending.md` (USDC E2E). Header + resumen rápido + ADRs 010-027.
- **2026-05-18 (Sprint Deploy)**: Sección 10 agregada a `what-we-tested.md` con verificación on-chain post-deploy V5.2 (16/16 checks PASS, 26 contratos deployados a Base Sepolia). Manifest completo en tracker PR #28.
- **2026-05-18 (Sprint DD)**: documento inicial creado. Snapshot del estado al cierre de Sprint EE-FIX.
