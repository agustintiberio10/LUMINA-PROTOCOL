# Sprint CR USDC Reconfig — 2026-05-23

**Trigger:** item #28 abierto en `what-is-pending.md` post Sprint USDC Mock (2026-05-23). El faucet migró a mintear `mUSDC` desde `0xD944d8e5D8329994D83950872Ec210891d3Ab6AE`, pero `CoverRouterV2.usdc` seguía apuntando a Circle USDC `0x036CbD53842c5426634e7929541eC2318f3dCF7e`. Resultado: un usuario que recibía mUSDC del faucet NO podía pagar premium — `purchasePolicy` revertía en `usdc.transferFrom`.
**Scope:** on-chain — `CoverRouterV2` + `TWAPBurner` upgrades + setter `setUsdc(address)`.
**Resultado:** ambos contratos apuntan a `mUSDC`; smoke test exitoso con `policyId=1`.

> ⚠️ **Disclaimer de recovery:** este archivo se reconstruyó el 2026-05-23 desde referencias en `what-is-pending.md` y el resumen pegado por el founder en el sprint Recovery. El sprint original no recibió sección dedicada en `what-we-tested.md`.

---

## 1. Acciones

### 1.1 Implementación nueva: `setUsdc(address)`

Ambos contratos `CoverRouterV2` y `TWAPBurner` recibieron una función:

```solidity
function setUsdc(address _usdc) external onlyOwner {
    require(_usdc != address(0), "Zero usdc");
    address old = address(usdc);
    usdc = IERC20(_usdc);
    emit UsdcAddressUpdated(old, _usdc);
}
```

Path elegido: **Opción A del item #28** (UUPS upgrade + setter), evitando redeploy fresh (Opción C).

### 1.2 UUPS upgrades

| Contrato | Proxy address (sin cambio) | Implementation nueva | Verified BaseScan |
|---|---|---|---|
| `CoverRouterV2` | `0xcdB70B40e6a3DEac3189185d947A0e458518F566` | (TBD — tx hash en sección 2) | ✅ |
| `TWAPBurner` | (existing proxy) | (TBD — tx hash en sección 2) | ✅ |

### 1.3 Switch a mUSDC

- `coverRouterV2.setUsdc(0xD944d8e5D8329994D83950872Ec210891d3Ab6AE)`
- `twapBurner.setUsdc(0xD944d8e5D8329994D83950872Ec210891d3Ab6AE)`

---

## 2. Tx hashes on-chain

> ⚠️ Los 4 tx hashes específicos vivían solo en el chat del founder. El sprint los menciona como "4 tx hashes on-chain" sin reproducirlos textualmente. Si se necesitan para auditoría externa, recuperables vía BaseScan: filtrar por la address proxy de `CoverRouterV2` con events `Upgraded(impl)` + `UsdcAddressUpdated(old, new)`, y lo mismo para `TWAPBurner`.

Total esperado: **4 tx** = 2 `upgradeTo(impl)` + 2 `setUsdc(mUSDC)`.

---

## 3. Smoke test post-cambio

| Test | Resultado |
|---|---|
| Faucet claim → recibí 10,000 mUSDC en wallet test | ✅ |
| `approve` de mUSDC al CoverRouterV2 | ✅ |
| `CoverRouterV2.purchasePolicy("FLASHBTC1H-001", 1000e6, "BTC")` | ✅ |
| `policyId` retornado | **1** (primer policy en el upgraded router) |
| Premium cobrado via `mUSDC.transferFrom` (no Circle USDC) | ✅ |
| `mUSDC.balanceOf(twapBurner)` reflejó ingreso | ✅ (TWAPBurner también recibe vía la nueva mUSDC) |

---

## 4. Items cerrados

- **Item #28** en `what-is-pending.md` → ✅ CERRADO. Update reflejado en este PR (Sprint Recovery 2026-05-23).

---

## 5. Item nuevo: BL-USDC en mainnet checklist

**Pre-mainnet blocker creado:** `BL-USDC` — antes de cualquier deploy a mainnet, `CoverRouterV2.usdc` y `TWAPBurner.usdc` deben re-apuntar a Circle USDC mainnet `0xa0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`, NO al MockUSDC de Sepolia.

Cómo cerrarlo en mainnet deploy:
1. Deploy CoverRouterV2 + TWAPBurner con `usdc = CIRCLE_USDC_MAINNET` en `initialize`.
2. Validar `coverRouter.usdc() == 0xa0b86991...` post-deploy.
3. Bloquear el setter `setUsdc` (rotar ownership a multisig + timelock).

Este blocker queda guardado para el deploy team.

---

## 6. Cross-ref con sprint precedente

Sprint USDC Mock (2026-05-23) — sección 19 de [`what-we-tested.md`](../what-we-tested.md). El faucet migró a `mUSDC.mint`, lo cual creó la inconsistencia que este sprint cerró.

---

## 7. Por qué este sprint no tiene sección en `what-we-tested.md`

Cambia 2 contratos (UUPS upgrades) pero no introduce tests nuevos ni mueve los números de Echidna/Halmos/CI. Es un setter switch + 2 upgradeTo. Por eso vive como `sprint-` archive aquí en vez de sección dedicada en `what-we-tested.md`.
