# LUMINA Protocol V5.0 - Explicado en Espanol

> Documento generado a partir del codigo fuente real. Cada numero, porcentaje y regla
> viene directamente de los contratos en `src/`. Nada es inventado.

---

## 1. Que es LUMINA en una frase

LUMINA es un protocolo de seguros parametricos para criptomonedas: los usuarios pagan
una prima en USDC, y si el precio de BTC, ETH o USDT cumple una condicion especifica
(por ejemplo, cae mas de 5% en 1 hora), reciben un pago automatico en forma de bonos
que maduran en 24 meses y se cobran en tokens LUMINA.

---

## 2. Los actores del protocolo

| Actor | Que hace |
|-------|----------|
| **Comprador de poliza** | Paga una prima en USDC, elige un producto (ej: "Flash BTC 1 hora"). Si se cumple la condicion, recibe un bono. |
| **Tenedor de bono (ClaimBond)** | Tiene un "ticket de cobro" que vale una cantidad fija en dolares. Puede esperar 24 meses para cobrarlo, o venderlo antes en el marketplace. |
| **Keeper (robot automatico)** | Llama periodicamente al TWAPBurner para que compre LUMINA en el mercado y los destruya. Cualquiera puede ser keeper. |
| **Relayer** | Puede comprar polizas en nombre de otros (por ejemplo, un agente de inteligencia artificial que opera via API). |
| **Gnosis Safe (multifirma)** | Es el "dueno" administrativo de la mayoria de contratos. Necesita varias firmas para hacer cambios. |
| **Founder** | Tiene 8M de LUMINA bloqueados hasta que se cumplan condiciones de AltSeason (o pasen 4 anos). |

---

## 3. Los "bolsillos" de dinero

### 5 bolsillos de LUMINA (100M totales, nunca se crean mas)

| # | Bolsillo | Cantidad | Porcentaje | Reglas |
|---|----------|----------|------------|--------|
| 1 | **BondVault** (Boveda de Bonos) | 70,000,000 LUMINA | 70% | No tiene dueno, no tiene funcion de retiro. Los tokens solo salen cuando alguien cobra un bono maduro, o cuando el BuybackEngine quema (maximo 5% del saldo por operacion). |
| 2 | **CEX Liquidity Reserve** | 14,000,000 LUMINA | 14% | Dividido en 3 sub-bolsillos: **Uso Inmediato** (2.8M), **Vesting Lineal** (8.4M en 730 dias), **Reserva Estrategica** (2.8M bloqueada 547 dias). Limite mensual: 1M de LUMINA. |
| 3 | **Founder Vesting** | 8,000,000 LUMINA | 8% | Bloqueado hasta que se cumplan 2 de 3 condiciones de AltSeason durante 7 dias seguidos, o hasta que pasen 1,460 dias (~4 anos). Se libera en 3 partes cada 31 dias. |
| 4 | **LBP (Fjord Foundry)** | 5,000,000 LUMINA | 5% | Venta inicial de liquidez. Una vez enviados, no hay control adicional desde el protocolo. |
| 5 | **Treasury Vesting** | 3,000,000 LUMINA | 3% | Bloqueado 180 dias. Despues, maximo 250,000 LUMINA por mes. Solo el Gnosis Safe puede liberarlos. |

### 3 bolsillos de USDC

| # | Bolsillo | De donde viene | Para que sirve |
|---|----------|----------------|----------------|
| 6 | **TWAPBurner** | 100% de las primas de seguros + comisiones del marketplace | Compra LUMINA en Uniswap V3 y los destruye. En modo adaptativo, puede repartir entre 4 destinos (ver seccion 6). |
| 7 | **MaintenanceReserve** | Parte de la distribucion adaptativa del TWAPBurner | Paga gastos operativos: infraestructura, auditorias, herramientas, marketing, legal. Tiene un limite mensual configurable. |
| 8 | **BuybackEngine** | USDC depositados para comprar bonos en el marketplace | Compra bonos con descuento y los destruye (Double Burn). Solo se activa 365 dias despues de desplegarse. |

---

## 4. Los 9 productos de seguro

Todos los productos pagan el **80% de la cobertura** si se activa la condicion (hay un deducible del 20%). No hay periodo de espera en ninguno.

### Productos de Bitcoin (BTC)

| Producto | ID | Duracion | Condicion para cobrar | Ejemplo |
|----------|-----|----------|----------------------|---------|
| Flash BTC 1h | FLASHBTC1H-001 | 1 hora fija | BTC cae mas de **5%** | Si BTC esta a $100,000 al comprar y baja a $94,999 en la siguiente hora, se activa. Cobertura de $1,000 paga $800. |
| Flash BTC 4h | FLASHBTC4H-001 | 4 horas fija | BTC cae mas de **8%** | Si BTC esta a $100,000 y baja a $91,999 en 4 horas. |
| Flash BTC 24h | FLASHBTC24-001 | 24 horas fija | BTC cae mas de **10%** | Si BTC esta a $100,000 y baja a $89,999 en 24 horas. |
| Flash BTC 48h | FLASHBTC48-001 | 48 horas fija | BTC cae mas de **15%** | Si BTC esta a $100,000 y baja a $84,999 en 48 horas. |

### Productos de Ethereum (ETH)

| Producto | ID | Duracion | Condicion para cobrar |
|----------|-----|----------|-----------------------|
| Flash ETH 1h | FLASHETH1H-001 | 1 hora fija | ETH cae mas de **7%** |
| Flash ETH 24h | FLASHETH24-001 | 24 horas fija | ETH cae mas de **12%** |
| Flash ETH 48h | FLASHETH48-001 | 48 horas fija | ETH cae mas de **18%** |

### Productos especiales

| Producto | ID | Duracion | Condicion para cobrar |
|----------|-----|----------|-----------------------|
| Micro Depeg (USDT) | MICRODEPEG-001 | 7 dias fija | USDT baja de **$0.995** (precio absoluto, no relativo) |
| Rate Shock (Aave USDC) | RATESHOCK-001 | 7 dias fija | La tasa variable de prestamo en Aave V3 para USDC supera **10% anual**. Se lee directo del contrato de Aave, sin necesidad de prueba del oraculo. |

> Cobertura minima para todos los productos: **$100 USDC**.

---

## 5. Flujo completo de una poliza (historia paso a paso)

Imaginemos que Maria quiere protegerse contra una caida rapida de BTC.

**Paso 1 - Comprar la poliza:**
Maria va al CoverRouter y elige "Flash BTC 1h" con $1,000 de cobertura. El sistema calcula
la prima usando la formula: cobertura x ratio de pago x probabilidad de disparo x margen.
Por ejemplo, si la prima sale $2.40, Maria paga $2.40 USDC.

**Paso 2 - El dinero de la prima:**
El 100% de esos $2.40 USDC van al TWAPBurner. No se queda nada el equipo (al menos
en modo no-adaptativo). En modo adaptativo, se reparte segun la situacion de solvencia
(ver seccion 6).

**Paso 3 - Se registra la poliza:**
El PolicyManager registra la poliza con el precio de BTC en ese momento (digamos $100,000).
El precio de disparo se fija en $95,000 (5% menos). La poliza vence en exactamente 1 hora.

**Paso 4a - Si BTC NO cae:**
La poliza expira despues de 1 hora. Cualquiera puede marcarla como expirada. Maria perdio
sus $2.40, que ya se usaron para comprar y quemar LUMINA.

**Paso 4b - Si BTC SI cae a menos de $95,000:**
Alguien (puede ser Maria, un bot, cualquier persona) envia una prueba firmada por el oraculo
de que BTC bajo de $95,000 durante la hora de cobertura. El sistema verifica la firma,
confirma que el precio y el momento son correctos.

**Paso 5 - Emision del bono:**
El BondVault emite 800 tokens ClaimBond (1 token = $1 USD) a nombre de Maria.
Epoca de vencimiento: 24 meses despues.

**Paso 6 - Esperar o vender:**
Maria tiene dos opciones:
- **Esperar 24 meses:** Cobra $800 en LUMINA al precio de mercado del momento de cobro.
  Si LUMINA vale $0.10, recibe 8,000 LUMINA.
- **Vender en el marketplace:** Lista sus 800 bonos y alguien los compra con descuento
  (por ejemplo, a $640). El comprador espera los 24 meses y cobra los $800.

**Paso 7 - Cobro del bono (despues de 24 meses):**
El tenedor del bono llama a `redeemBond`. El sistema mira el precio actual de LUMINA,
calcula cuantos LUMINA equivalen a $800, y se los transfiere del BondVault.

> Hay un periodo de gracia de 24 horas despues de que la poliza expire para enviar pruebas
> de eventos que ocurrieron DURANTE la cobertura. Esto protege contra retrasos en la red.

---

## 6. Sistema adaptativo de distribucion (4 cubetas)

### Que son las 4 cubetas

Cuando alguien paga una prima o hay comisiones del marketplace, el dinero (USDC) se
puede repartir en 4 "cubetas":

1. **Burn** - Comprar LUMINA y destruirlos (reduce la cantidad total que existe)
2. **Buyback** - Guardar USDC para que el BuybackEngine compre bonos con descuento
3. **Ops** - Operaciones (gastos del protocolo)
4. **Maintenance** - Mantenimiento (infra, auditorias, herramientas, marketing, legal)

### Como se decide el reparto: la matriz 4x4

El sistema mide dos cosas:
- **Solvencia**: cuanto valen las reservas vs. cuanto se debe en bonos
  - Ultra (mas de 200%): la boveda tiene de sobra
  - Saludable (100-200%): todo bien
  - Estresado (70-100%): las cosas se estan poniendo apretadas
  - Crisis (menos de 70%): hay que actuar
- **Momentum**: como se esta moviendo el precio de LUMINA
  - Rally (sube mas de 10%): el mercado esta a favor
  - Estable (entre -5% y +10%): normal
  - Declive (entre -15% y -5%): bajando
  - Crash (menos de -15%): caida fuerte

Combinando ambos ejes, hay 16 escenarios posibles. Estos son los porcentajes reales del codigo:

| Solvencia \ Momentum | Rally | Estable | Declive | Crash |
|----------------------|-------|---------|---------|-------|
| **Ultra** | 95/0/0/5 | 90/5/0/5 | 85/10/0/5 | 75/20/0/5 |
| **Saludable** | 90/5/0/5 | 85/8/2/5 | 70/21/2/7 | 55/35/2/8 |
| **Estresado** | 75/18/2/5 | 55/35/2/8 | 38/55/2/5 | 18/75/2/5 |
| **Crisis** | 48/45/2/5 | 28/65/2/5 | 8/85/2/5 | 0/96/2/2 |

> Formato: Burn/Buyback/Ops/Maintenance (todo en porcentaje)

**Lectura del ejemplo mas extremo:** En Crisis + Crash, el 0% se quema, el 96% va a buyback
(para comprar bonos y reducir deuda), 2% a operaciones y 2% a mantenimiento.

**Lectura del mejor escenario:** En Ultra + Rally, el 95% se quema (maximo efecto
deflacionario) y solo 5% a mantenimiento.

### Valores de respaldo (si el oraculo falla)

Si el sistema adaptativo no responde, se usan estos valores fijos:
- Burn: 85%
- Buyback: 8%
- Ops: 2%
- Maintenance: 5%

### Protecciones del sistema

- La evaluacion de solvencia se hace maximo una vez por dia.
- El cambio de cuadrante tiene un enfriamiento de 7 dias (para evitar que salte
  constantemente entre modos).
- El promedio se calcula con las ultimas 3 evaluaciones (suavizado).
- Umbrales de solvencia: Ultra >=200%, Saludable >=100%, Estresado >=70%, Crisis <70%.
- Umbrales de momentum: Rally >=110%, Estable >=95%, Declive >=85%, Crash <85%.

---

## 7. Marketplace de bonos

Los ClaimBonds son tokens que se pueden transferir libremente. El marketplace nativo
permite comprarlos y venderlos antes de su vencimiento.

**Como funciona:**

1. El vendedor lista sus bonos: "Vendo 800 bonos de la epoca 202804 por $640 USDC"
2. Un comprador acepta y paga $640 + 1.5% de comision del comprador ($9.60)
3. Al vendedor se le descuenta 1.5% de comision ($9.60) y recibe $630.40
4. Las comisiones totales (3%, es decir $19.20) van al TWAPBurner para comprar y quemar LUMINA

**Reglas:**
- Solo se pueden listar bonos que aun no hayan vencido
- El vendedor no puede poner precio de $0
- El vendedor puede cancelar su listado y recuperar sus bonos
- Las comisiones son fijas: **1.5% el comprador + 1.5% el vendedor = 3% total**

---

## 8. BuybackEngine (a partir del mes 12)

El BuybackEngine es un mecanismo que empieza a funcionar **365 dias despues de ser desplegado**.
Compra bonos con descuento en el marketplace y ejecuta un "Double Burn":

### Que es Double Burn

1. **Primera quema:** El bono comprado se destruye (ya nadie puede cobrarlo). Esto reduce
   las obligaciones del BondVault en la cantidad de dolares que valia ese bono.
2. **Segunda quema:** Si la solvencia del protocolo esta por encima de 150%, ademas se
   queman LUMINA del BondVault por el valor equivalente en dolares del bono destruido.
   Si la solvencia es menor a 150%, solo se hace la primera quema.

### Limites de seguridad

- No funciona hasta que pasen 365 dias desde el despliegue
- El operador configura un presupuesto diario y un precio maximo (hasta 95% del valor nominal)
- Cada ronda de configuracion dura maximo 72 horas
- La quema de LUMINA del BondVault esta limitada a maximo 5% del saldo por operacion
- Si la solvencia es menor a 150%, la segunda quema se bloquea automaticamente

**Ejemplo numerico:** El BuybackEngine compra 1,000 bonos de la epoca 202804 por $700 USDC
(descuento del 30%). Destruye los bonos, reduciendo las obligaciones en $1,000. Si la
solvencia es 180% (mayor a 150%), tambien quema $1,000 en LUMINA del BondVault (al precio
actual de mercado).

---

## 9. Quien controla que (permisos)

| Contrato | Quien lo controla | Que puede hacer |
|----------|-------------------|-----------------|
| **LuminaTokenV2** | DEFAULT_ADMIN_ROLE (deployer) | Asignar/revocar BURNER_ROLE. NO puede crear tokens nuevos. |
| **LuminaTokenV2** | BURNER_ROLE (TWAPBurner) | Quemar tokens de cualquier direccion. |
| **BondVault** | PolicyManager | Emitir bonos (issueBond). |
| **BondVault** | Cualquier persona | Cobrar bonos maduros (redeemBond). |
| **BondVault** | Cualquier persona | Activar el interruptor de emergencia si el precio baja de $0.005. |
| **BondVault** | Cualquier persona | Resetear el interruptor si el precio sube a $0.008 (con 1h de enfriamiento). |
| **BondVault** | AUTHORIZED_CALLER_ADMIN_ROLE | Autorizar/revocar direcciones para decreaseObligations y burnFromReserves. |
| **BondVault** | Authorized callers (BuybackEngine) | Reducir obligaciones y quemar reservas (max 5% por operacion). |
| **ClaimBond** | Owner (Gnosis Safe) | Configurar BondVault (una sola vez). |
| **ClaimBond** | BondVault | Crear y destruir bonos. |
| **ClaimBond** | Holder o aprobado | burnByHolder (para Double Burn). |
| **CoverRouterV2** | Owner (Gnosis Safe) | Pausar, configurar productos, agregar relayers. |
| **CoverRouterV2** | Cualquier persona | Comprar polizas (purchasePolicy). |
| **CoverRouterV2** | Relayer autorizado | Comprar polizas para otros (purchasePolicyFor). |
| **CoverRouterV2** | Cualquier persona | Enviar prueba de disparo (submitTrigger). |
| **PolicyManagerV2** | Owner (Gnosis Safe) | Registrar/desactivar productos, configurar router. |
| **PolicyManagerV2** | Router (CoverRouterV2) | Registrar polizas y procesar disparos. |
| **PolicyManagerV2** | Cualquier persona | Marcar polizas como expiradas (markExpired). |
| **TWAPBurner** | Owner (Gnosis Safe) | Cambiar parametros (cooldown, slippage, limites), activar modo adaptativo. |
| **TWAPBurner** | Cualquier persona | Ejecutar la quema (executeBurn, con cooldown de 15 min). |
| **CEXLiquidityReserve** | ALLOCATOR_ROLE (Gnosis Safe) | Asignar fondos de los sub-bolsillos. |
| **MaintenanceReserve** | SPENDER_ROLE (Gnosis Safe) | Gastar USDC con categoria y memo. |
| **CapacityOracle** | Owner (Gnosis Safe) | Cambiar pool de Uniswap, ventana TWAP, precio de emergencia. |
| **SolvencyOracle** | ADMIN_ROLE | Pausar/despausar emergencia. |
| **SolvencyOracle** | Cualquier persona | Ejecutar evaluacion (cada 24h minimo). |
| **BuybackEngine** | BUYBACK_OPERATOR_ROLE | Configurar presupuesto diario. |
| **BuybackEngine** | Cualquier persona | Ejecutar ofertas (executeOffer) si hay configuracion activa. |
| **LuminaBondMarketplace** | Cualquier persona | Listar, cancelar y comprar bonos. |
| **LuminaBondMarketplace** | FEE_MANAGER_ROLE | Cambiar la direccion del TWAPBurner. |
| **FounderVesting** | Owner (deployer) | Cambiar el destinatario de los tokens. |
| **FounderVesting** | Cualquier persona | Verificar condiciones AltSeason y liberar tranches. |
| **TreasuryVesting** | Owner (Gnosis Safe) | Liberar tokens (max 250K/mes despues de 180 dias). |

---

## 10. Que NO puede pasar nunca (garantias del codigo)

1. **No se pueden crear mas LUMINA.** No existe ninguna funcion de "mint" despues del despliegue.
   El suministro maximo es 100,000,000 y solo puede bajar (por quema).

2. **Nadie puede sacar tokens del BondVault directamente.** No hay funcion de retiro.
   Solo salen tokens por redeemBond (cobro de bono maduro) o burnFromReserves (quema
   autorizada, max 5% del saldo por operacion).

3. **El cobro de bonos nunca se puede bloquear.** Aunque el interruptor de emergencia
   este activo, redeemBond sigue funcionando. El interruptor solo bloquea la emision
   de bonos nuevos.

4. **El BondVault no puede comprometer mas del 50% del valor de sus reservas.** El factor
   de seguridad (SAFETY_FACTOR_BPS = 5000) limita los compromisos al 50% del valor
   total de las reservas en dolares.

5. **Los bonos del founder no se pueden tocar antes de tiempo.** Se necesitan 2 de 3
   condiciones de AltSeason sostenidas 7 dias, o esperar 1,460 dias.

6. **La CEX Reserve tiene tope mensual de 1M LUMINA** y la reserva estrategica esta
   bloqueada 547 dias.

7. **El Treasury Vesting no libera mas de 250K LUMINA por mes** y tiene 180 dias de
   bloqueo inicial.

8. **El setBondVault en ClaimBond solo se puede llamar UNA vez.** Despues de configurarse,
   nadie puede cambiarlo.

9. **El interruptor de emergencia no se puede resetear al instante.** Hay un enfriamiento
   minimo de 1 hora entre activacion y reseteo.

10. **El BuybackEngine no funciona durante el primer ano.** El ACTIVATION_DELAY de 365
    dias impide cualquier operacion antes de esa fecha.

---

## 11. Preguntas frecuentes

**P1: Si pago $2 de prima, a donde va ese dinero?**
R: Va 100% al TWAPBurner. En modo adaptativo, se reparte segun la tabla de cuadrantes
(seccion 6). En modo legado (antes de activar el modo adaptativo), el 100% se usa
para comprar LUMINA y destruirlos.

**P2: Si me activan la poliza, cuando recibo mi dinero?**
R: No recibes dinero inmediato. Recibes bonos que representan tu pago en dolares.
Esos bonos maduran 24 meses despues. Al madurar, los canjeas por LUMINA al precio
de mercado de ese dia.

**P3: Que pasa si el precio de LUMINA baja mucho cuando voy a cobrar?**
R: Tu bono siempre vale la misma cantidad en dolares ($800 por ejemplo). Si LUMINA
baja, recibes mas tokens LUMINA. Pero hay un piso minimo de $0.001 por LUMINA
para el calculo de redencion.

**P4: Puede el fundador vender sus tokens?**
R: No antes de que se cumplan las condiciones de AltSeason (2 de 3: ETH/BTC > 0.050,
ETH > $4,000, tasa de Aave > 7%) durante 7 dias seguidos. Si nunca se cumplen,
se desbloquean despues de ~4 anos (1,460 dias). Luego se liberan en 3 partes,
una cada 31 dias (~2.67M por parte).

**P5: Que son las condiciones de AltSeason?**
R: Son tres indicadores de que el mercado esta en una etapa favorable:
- A: La relacion ETH/BTC esta por encima de 0.050
- B: ETH vale mas de $4,000
- C: La tasa de prestamo variable de USDC en Aave V3 supera el 7% anual
Se necesitan al menos 2 de 3 sostenidas durante 7 dias consecutivos.

**P6: Que pasa si el oraculo de precios falla?**
R: El CapacityOracle tiene un precio de emergencia configurable. Si no puede leer
el precio de Uniswap, usa ese precio de respaldo.

**P7: Puede alguien pausar el protocolo entero?**
R: El CoverRouterV2 se puede pausar (bloquea nuevas compras). El interruptor de
emergencia del BondVault se activa automaticamente si LUMINA baja de $0.005
(solo bloquea nuevos bonos, nunca los cobros). No hay un "boton de apagar todo".

**P8: Como funciona el precio TWAP?**
R: El CapacityOracle lee el precio promedio de LUMINA en los ultimos 30 minutos
(1,800 segundos) del pool de Uniswap V3. Esto evita que alguien manipule el
precio con una compra grande justo antes de una operacion.

**P9: Que es el Double Burn?**
R: Es cuando el BuybackEngine compra un bono con descuento y luego: (1) destruye
el bono (borrando la deuda) y (2) destruye LUMINA del BondVault por el valor
equivalente. Solo se hace la parte 2 si la solvencia esta arriba de 150%.

**P10: Cuanto cuesta usar el marketplace de bonos?**
R: 3% total: 1.5% lo paga el vendedor y 1.5% el comprador. Toda la comision
va al TWAPBurner para comprar y quemar LUMINA.

**P11: Puede alguien emitir bonos falsos?**
R: No. Solo el BondVault puede llamar a mint() en ClaimBond, y el BondVault solo
emite cuando el PolicyManager se lo pide despues de verificar una poliza activada.

**P12: Que pasa con los $14M de LUMINA para CEX/DEX?**
R: Se dividen en tres partes: 2.8M disponibles inmediatamente (para el pool de
Uniswap, por ejemplo), 8.4M que se liberan linealmente en 730 dias (2 anos),
y 2.8M bloqueados 547 dias (~18 meses). Maximo 1M por mes en total.

**P13: El TWAPBurner puede quedarse con USDC?**
R: No puede simplemente guardarlos. Cada 15 minutos (cooldown configurable), cualquier
persona puede llamar executeBurn. Maximo $10,000 por ejecucion, minimo $1. El USDC
no se puede sacar por otra via; solo hay una funcion de emergencia para recuperar
tokens que NO sean USDC ni LUMINA.

**P14: Que es el periodo de gracia de 24 horas?**
R: Despues de que tu poliza expire, tienes 24 horas extras para enviar la prueba
del oraculo de un evento que ocurrio DURANTE la cobertura. Esto protege contra
retrasos en la red o problemas del secuenciador de la cadena.

**P15: Cuantas polizas puede soportar el protocolo?**
R: Depende del precio de LUMINA. La boveda de 70M LUMINA con factor de seguridad
del 50% significa que se pueden emitir bonos hasta por la mitad del valor de
mercado de esas reservas. Por ejemplo, si LUMINA vale $0.10, las reservas valen
$7M, y se pueden comprometer hasta $3.5M en bonos activos.

---

## 12. Checklist de verificacion

Antes de ir a produccion, revisar cada punto:

- [ ] **LuminaTokenV2:** Confirmar que totalSupply() == 100,000,000 y que no existe funcion mint
- [ ] **LuminaTokenV2:** Verificar que BURNER_ROLE esta asignado al TWAPBurner correcto
- [ ] **BondVault:** Confirmar que no hay funcion withdraw() ni escape hatch
- [ ] **BondVault:** Verificar MIN_PRICE = $0.005 y RESET_PRICE = $0.008 -- VERIFICAR CON FOUNDER si estos valores son los deseados
- [ ] **BondVault:** Confirmar SAFETY_FACTOR_BPS = 5000 (50%)
- [ ] **BondVault:** Verificar que BOND_MATURITY_SECONDS = 730 dias (24 meses)
- [ ] **BondVault:** Confirmar que burnFromReserves tiene cap de 5% por operacion
- [ ] **BondVault:** Verificar que redeemBond funciona incluso con paused=true
- [ ] **ClaimBond:** Confirmar que setBondVault solo se puede llamar una vez
- [ ] **ClaimBond:** Verificar que los bonos son transferibles (necesario para marketplace)
- [ ] **CoverRouterV2:** Confirmar que 100% de primas van al TWAPBurner
- [ ] **CoverRouterV2:** Verificar cobertura minima = $100 USDC
- [ ] **PolicyManagerV2:** Confirmar payout fijo al 80% (payoutAmount = coverage * 8000 / 10000)
- [ ] **PolicyManagerV2:** Verificar que solo el Router puede registrar polizas y procesar disparos
- [ ] **TWAPBurner:** Verificar valores de respaldo (85% burn, 8% buyback, 2% ops, 5% maintenance)
- [ ] **TWAPBurner:** Confirmar cooldown = 900 segundos (15 min) y maxBurnAmount = $10,000
- [ ] **TWAPBurner:** Verificar maxSlippageBps = 500 (5% de deslizamiento maximo)
- [ ] **AdaptiveFeeDistributor:** Verificar que los 16 cuadrantes suman <= 10,000 bps cada uno
- [ ] **CapacityOracle:** Verificar ventana TWAP = 1,800 segundos (30 min) -- VERIFICAR CON FOUNDER si es suficiente
- [ ] **CapacityOracle:** Confirmar que existe precio de emergencia y es razonable
- [ ] **SolvencyOracle:** Verificar umbrales: Ultra=200%, Saludable=100%, Estresado=70%
- [ ] **SolvencyOracle:** Confirmar cooldown de cambio de cuadrante = 7 dias
- [ ] **SolvencyOracle:** Confirmar intervalo de evaluacion = 1 dia
- [ ] **CEXLiquidityReserve:** Verificar sub-bolsillos: 2.8M + 8.4M + 2.8M = 14M
- [ ] **CEXLiquidityReserve:** Confirmar vesting = 730 dias, strategic lock = 547 dias
- [ ] **CEXLiquidityReserve:** Confirmar monthly cap = 1,000,000 LUMINA
- [ ] **MaintenanceReserve:** Verificar que solo acepta USDC y que tiene limite mensual configurable
- [ ] **BuybackEngine:** Confirmar ACTIVATION_DELAY = 365 dias
- [ ] **BuybackEngine:** Verificar MIN_SOLVENCY_FOR_DOUBLE_BURN = 150% (15000 bps)
- [ ] **BuybackEngine:** Confirmar que maxPricePercent tiene limite de 95%
- [ ] **LuminaBondMarketplace:** Confirmar comisiones: 1.5% comprador + 1.5% vendedor
- [ ] **LuminaBondMarketplace:** Verificar que comisiones van al TWAPBurner
- [ ] **FounderVesting:** Verificar condiciones AltSeason: ETH/BTC>0.050, ETH>$4,000, Aave>7%
- [ ] **FounderVesting:** Confirmar SUSTAINED_DURATION = 7 dias
- [ ] **FounderVesting:** Confirmar TOTAL_TRANCHES = 3, TRANCHE_INTERVAL = 31 dias
- [ ] **FounderVesting:** Confirmar FALLBACK_DURATION = 1,460 dias
- [ ] **TreasuryVesting:** Confirmar LOCK_DURATION = 180 dias
- [ ] **TreasuryVesting:** Confirmar MAX_MONTHLY_RELEASE = 250,000 LUMINA
- [ ] **Shields (9 productos):** Verificar que todos tienen DEDUCTIBLE_BPS = 2000 (80% payout)
- [ ] **Shields:** Confirmar TRIGGER_DROP_BPS de cada producto: BTC 1h=5%, 4h=8%, 24h=10%, 48h=15%; ETH 1h=7%, 24h=12%, 48h=18%; Depeg=$0.995; RateShock=10%
- [ ] **Shields:** Verificar que el periodo de gracia (CLAIM_GRACE_PERIOD) = 24 horas
- [ ] **Gnosis Safe:** Verificar que el multisig esta configurado con el numero correcto de firmas -- VERIFICAR CON FOUNDER cuantas firmas se requieren
- [ ] **Despliegue:** Confirmar que todos los constructores recibieron direcciones correctas y no address(0)
- [ ] **Despliegue:** Verificar que setPolicyManager en BondVault se llamo con la direccion correcta
- [ ] **Despliegue:** Verificar que setBondVault en ClaimBond se llamo y ya no se puede volver a llamar
- [ ] **Oraculo:** Verificar que el pool de Uniswap V3 esta correctamente configurado en CapacityOracle
- [ ] **Integracion:** Confirmar que BuybackEngine esta autorizado en BondVault (setAuthorizedCaller)

---

> Documento generado el 2026-04-19. Basado exclusivamente en el codigo fuente de
> `src/` del repositorio LUMINA-PROTOCOL. Los valores marcados "VERIFICAR CON FOUNDER"
> requieren confirmacion explicita del fundador.
