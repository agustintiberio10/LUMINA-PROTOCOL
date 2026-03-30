#!/usr/bin/env node
/**
 * LUMINA PROTOCOL — Terminal M2M Interactiva - Whitepaper V3
 *
 * Usage:
 *   node lumina-cli.mjs
 *   node lumina-cli.mjs --lang=es
 *   node lumina-cli.mjs --lang=en
 */

const CYAN = '\x1b[36m'
const GREEN = '\x1b[32m'
const YELLOW = '\x1b[33m'
const RED = '\x1b[31m'
const GRAY = '\x1b[90m'
const WHITE = '\x1b[97m'
const BOLD = '\x1b[1m'
const DIM = '\x1b[2m'
const RESET = '\x1b[0m'

const lang = process.argv.includes('--lang=es') ? 'es' : 'en'

const content = {
  en: {
    subtitle: 'Terminal M2M Interactive - Whitepaper V3',
    menu: [
      'Executive Summary (Problem & Solution)',
      'The 4 Products (BSS, Depeg, IL, Exploit)',
      'Vaults, APYs & 1:1 Collateral',
      'Business Model (Fees)',
      'Actuarial Data (Margins)',
      'Switch to Espanol',
      'Exit',
    ],
    prompt: 'Select an option (1-7): ',
    back: 'Press ENTER to return to menu...',
    sections: [
      // 1. Executive Summary
      [
        `${BOLD}${CYAN}EXECUTIVE SUMMARY${RESET}`,
        ``,
        `${WHITE}The Problem:${RESET}`,
        `  ${GRAY}- Thousands of AI agents manage DeFi positions without any protection${RESET}`,
        `  ${GRAY}- Existing insurance (Nexus Mutual, InsurAce) designed for humans${RESET}`,
        `  ${GRAY}- Claim resolution takes weeks, incompatible with autonomous agents${RESET}`,
        ``,
        `${WHITE}The Solution:${RESET}`,
        `  ${CYAN}Lumina Protocol${RESET} ${GRAY}— Parametric insurance exclusively for AI agents${RESET}`,
        `  ${GRAY}- Mathematical triggers verified by oracles (no human judges)${RESET}`,
        `  ${GRAY}- Instant payouts in a single transaction${RESET}`,
        `  ${GRAY}- Settlement in ${CYAN}USDC${RESET} ${GRAY}on ${CYAN}Base L2${RESET}`,
        `  ${GRAY}- Yield via ${CYAN}Aave V3${RESET} ${GRAY}(3-5% APY base)${RESET}`,
        ``,
        `${WHITE}Protocol at a Glance:${RESET}`,
        `  ${CYAN}4${RESET} insurance products  |  ${CYAN}4${RESET} isolated vaults  |  ${CYAN}13${RESET} verified contracts`,
        `  ${CYAN}79${RESET} tests passing     |  ${CYAN}48h${RESET} timelock       |  ${CYAN}2-of-3${RESET} multisig`,
        ``,
        `${WHITE}Flow:${RESET} ${GRAY}Human${RESET} ${CYAN}->${RESET} ${GRAY}AI Agent${RESET} ${CYAN}->${RESET} ${GRAY}API${RESET} ${CYAN}->${RESET} ${GRAY}CoverRouter${RESET} ${CYAN}->${RESET} ${GRAY}Shield${RESET} ${CYAN}->${RESET} ${GRAY}Vault (lock 1:1)${RESET}`,
      ],
      // 2. Products
      [
        `${BOLD}${CYAN}THE 4 INSURANCE PRODUCTS${RESET}`,
        ``,
        `${BOLD}${CYAN}1. Black Swan Shield (BSS)${RESET}`,
        `  ${GRAY}Trigger:${RESET}    ${WHITE}ETH/BTC drops > ${RED}30%${RESET} ${GRAY}from purchase price${RESET}`,
        `  ${GRAY}Payout:${RESET}     ${WHITE}Binary — ${GREEN}80%${RESET} ${GRAY}of coverage (20% deductible)${RESET}`,
        `  ${GRAY}Duration:${RESET}   ${WHITE}7-30 days${RESET}  ${GRAY}| Waiting: none${RESET}`,
        `  ${GRAY}Verification: TWAP 15 min or 3 consecutive Chainlink rounds${RESET}`,
        ``,
        `${BOLD}${CYAN}2. Depeg Shield${RESET}`,
        `  ${GRAY}Trigger:${RESET}    ${WHITE}Stablecoin < ${RED}$0.95${RESET}`,
        `  ${GRAY}Payout:${RESET}     ${WHITE}DAI: ${GREEN}88%${RESET} ${GRAY}(12% ded)${RESET}  ${WHITE}USDT: ${GREEN}85%${RESET} ${GRAY}(15% ded)${RESET}  ${YELLOW}USDC: excluded${RESET}`,
        `  ${GRAY}Duration:${RESET}   ${WHITE}14-365 days${RESET}  ${GRAY}| Waiting: 24h${RESET}`,
        `  ${GRAY}Discount:${RESET}   ${WHITE}91-180d: ${GREEN}10% off${RESET}  ${WHITE}181-365d: ${GREEN}20% off${RESET}`,
        ``,
        `${BOLD}${CYAN}3. IL Index Cover${RESET}`,
        `  ${GRAY}Trigger:${RESET}    ${WHITE}IL > ${RED}2%${RESET} ${GRAY}at policy expiry (European-style)${RESET}`,
        `  ${GRAY}Formula:${RESET}    ${CYAN}IL = 1 - (2*sqrt(r)) / (1+r)${RESET}`,
        `  ${GRAY}Payout:${RESET}     ${WHITE}Proportional — Coverage x max(0, IL%-2%) x ${GREEN}90%${RESET}`,
        `  ${GRAY}Cap:${RESET}        ${WHITE}Max ${GREEN}11.7%${RESET} ${GRAY}of coverage${RESET}`,
        `  ${GRAY}Duration:${RESET}   ${WHITE}14-90 days${RESET}  ${GRAY}| Settlement: 48h window${RESET}`,
        ``,
        `${BOLD}${CYAN}4. Exploit Shield${RESET}`,
        `  ${GRAY}Trigger:${RESET}    ${WHITE}DUAL — Gov token ${RED}-25%${RESET} ${GRAY}in 24h${RESET} ${WHITE}AND${RESET} ${GRAY}receipt token ${RED}-30%${RESET} ${GRAY}for 4h${RESET}`,
        `  ${GRAY}Payout:${RESET}     ${WHITE}Binary — ${GREEN}90%${RESET} ${GRAY}of coverage (10% deductible)${RESET}`,
        `  ${GRAY}Cap:${RESET}        ${YELLOW}$50,000 per wallet${RESET}`,
        `  ${GRAY}Duration:${RESET}   ${WHITE}90-365 days${RESET}  ${GRAY}| Waiting: 14 days${RESET}`,
        `  ${GRAY}Covered:${RESET}    ${WHITE}Compound, Uniswap, MakerDAO, Curve, Morpho${RESET}  ${YELLOW}Aave: excluded${RESET}`,
      ],
      // 3. Vaults
      [
        `${BOLD}${CYAN}VAULTS, APYs & 1:1 COLLATERAL${RESET}`,
        ``,
        `${WHITE}Vault               Cooldown    Products              Est. APY${RESET}`,
        `${CYAN}VolatileShort${RESET}       ${WHITE}30 days${RESET}     ${GRAY}BSS + IL Index${RESET}          ${GREEN}12-16%${RESET}`,
        `${CYAN}VolatileLong${RESET}        ${WHITE}90 days${RESET}     ${GRAY}IL long + BSS overflow${RESET}  ${GREEN}15-19%${RESET}`,
        `${CYAN}StableShort${RESET}         ${WHITE}90 days${RESET}     ${GRAY}Depeg short${RESET}             ${GREEN}11-15%${RESET}`,
        `${CYAN}StableLong${RESET}          ${WHITE}365 days${RESET}    ${GRAY}Depeg + Exploit${RESET}         ${GREEN}18-27%${RESET}`,
        ``,
        `${WHITE}Yield Composition:${RESET}`,
        `  ${GRAY}Layer 1:${RESET} ${GREEN}Aave V3 base yield (3-5% APY)${RESET}`,
        `  ${GRAY}Layer 2:${RESET} ${GREEN}Insurance premium income${RESET}`,
        `  ${GRAY}Total:${RESET}   ${GREEN}${BOLD}11-27% APY${RESET} ${GRAY}depending on vault${RESET}`,
        ``,
        `${WHITE}Key Features:${RESET}`,
        `  ${CYAN}1:1 Collateral${RESET}   ${GRAY}— Every $1 of coverage = $1 USDC locked${RESET}`,
        `  ${CYAN}Soulbound${RESET}        ${GRAY}— Shares cannot be transferred (anti-manipulation)${RESET}`,
        `  ${CYAN}Aave Yield${RESET}       ${GRAY}— Even locked collateral earns yield in Aave V3${RESET}`,
        `  ${CYAN}U_MAX = 95%${RESET}      ${GRAY}— No new policies if vault is 95%+ utilized${RESET}`,
      ],
      // 4. Fees
      [
        `${BOLD}${CYAN}BUSINESS MODEL (FEES)${RESET}`,
        ``,
        `${WHITE}Event                     Fee        Description${RESET}`,
        `${GRAY}Policy purchase${RESET}           ${CYAN}3%${RESET}         ${GRAY}3% of premium -> protocol, 97% -> vault${RESET}`,
        `${GRAY}Claim payout${RESET}              ${CYAN}3%${RESET}         ${GRAY}3% of payout -> protocol, 97% -> agent${RESET}`,
        `${GRAY}Vault withdrawal${RESET}          ${CYAN}3%${RESET}         ${GRAY}3% performance fee on positive yield only${RESET}`,
        ``,
        `${WHITE}Performance Fee Example:${RESET}`,
        `  ${GRAY}Deposit:${RESET}  ${WHITE}$10,000${RESET}`,
        `  ${GRAY}Withdraw:${RESET} ${WHITE}$10,500${RESET}`,
        `  ${GRAY}Profit:${RESET}   ${GREEN}$500${RESET}`,
        `  ${GRAY}Fee:${RESET}      ${CYAN}$15${RESET} ${GRAY}(3% x $500)${RESET}`,
        `  ${GRAY}Net:${RESET}      ${GREEN}$10,485${RESET}`,
        ``,
        `${YELLOW}No fee if no profit. You only pay when you win.${RESET}`,
        ``,
        `${WHITE}Scalability Flywheel:${RESET}`,
        `  ${GRAY}More LPs -> More capacity -> More policies -> More fees -> More yield -> More LPs${RESET}`,
      ],
      // 5. Actuarial
      [
        `${BOLD}${CYAN}ACTUARIAL DATA (MARGINS)${RESET}`,
        ``,
        `${WHITE}Product              Annual Premiums   Annual Claims    Net EV       Margin${RESET}`,
        `${CYAN}Black Swan Shield${RESET}    ${GREEN}~$54,000${RESET}          ${RED}~$34,000${RESET}         ${GREEN}+$20,000${RESET}     ${GREEN}38%${RESET}`,
        `${CYAN}Depeg Shield${RESET}         ${GREEN}~$85,000${RESET}          ${RED}~$32,000${RESET}         ${GREEN}+$52,000${RESET}     ${GREEN}62%${RESET}`,
        `${CYAN}IL Index Cover${RESET}       ${GREEN}calculated${RESET}        ${RED}calculated${RESET}       ${GREEN}+$37,000${RESET}     ${GREEN}60%${RESET}`,
        `${CYAN}Exploit Shield${RESET}       ${GREEN}calculated${RESET}        ${RED}calculated${RESET}       ${GREEN}+$2,000${RESET}      ${GREEN}65%${RESET}`,
        ``,
        `${WHITE}Worst-Case Systemic Scenario:${RESET}`,
        `  ${GRAY}Event:${RESET}    ${RED}Market crash + stablecoin depeg + protocol exploit (simultaneous)${RESET}`,
        `  ${GRAY}Loss:${RESET}     ${RED}-$438,000${RESET} ${GRAY}(-21.9% of $2M TVL)${RESET}`,
        `  ${GRAY}Recovery:${RESET} ${YELLOW}10-12 months${RESET} ${GRAY}via premium accumulation${RESET}`,
        `  ${GRAY}Probability:${RESET} ${GREEN}<0.1% annual${RESET}`,
        ``,
        `${WHITE}Kink Model Multipliers:${RESET}`,
        `  ${GRAY}0%:${RESET} ${WHITE}1.00x${RESET}  ${GRAY}20%:${RESET} ${WHITE}1.13x${RESET}  ${GRAY}40%:${RESET} ${WHITE}1.25x${RESET}  ${GRAY}60%:${RESET} ${WHITE}1.38x${RESET}`,
        `  ${GRAY}80%:${RESET} ${YELLOW}1.50x${RESET}  ${GRAY}85%:${RESET} ${YELLOW}1.88x${RESET}  ${GRAY}90%:${RESET} ${RED}2.25x${RESET}  ${GRAY}95%:${RESET} ${RED}REJECT${RESET}`,
      ],
    ],
  },
  es: {
    subtitle: 'Terminal M2M Interactiva - Whitepaper V3',
    menu: [
      'Resumen Ejecutivo (Problema y Solucion)',
      'Los 4 Productos (BSS, Depeg, IL, Exploit)',
      'Vaults, APYs y Colateral 1:1',
      'Modelo de Negocio (Fees)',
      'Datos Actuariales (Margenes)',
      'Cambiar a English',
      'Salir',
    ],
    prompt: 'Selecciona una opcion (1-7): ',
    back: 'Presiona ENTER para volver al menu...',
    sections: [
      // 1. Resumen Ejecutivo
      [
        `${BOLD}${CYAN}RESUMEN EJECUTIVO${RESET}`,
        ``,
        `${WHITE}El Problema:${RESET}`,
        `  ${GRAY}- Miles de agentes IA gestionan posiciones DeFi sin ninguna proteccion${RESET}`,
        `  ${GRAY}- Los seguros existentes (Nexus Mutual, InsurAce) son para humanos${RESET}`,
        `  ${GRAY}- La resolucion de reclamos toma semanas, incompatible con agentes autonomos${RESET}`,
        ``,
        `${WHITE}La Solucion:${RESET}`,
        `  ${CYAN}Lumina Protocol${RESET} ${GRAY}— Seguro parametrico exclusivo para agentes de IA${RESET}`,
        `  ${GRAY}- Triggers matematicos verificados por oracles (sin jueces humanos)${RESET}`,
        `  ${GRAY}- Pagos instantaneos en una sola transaccion${RESET}`,
        `  ${GRAY}- Liquidacion en ${CYAN}USDC${RESET} ${GRAY}en ${CYAN}Base L2${RESET}`,
        `  ${GRAY}- Yield via ${CYAN}Aave V3${RESET} ${GRAY}(3-5% APY base)${RESET}`,
        ``,
        `${WHITE}El Protocolo:${RESET}`,
        `  ${CYAN}4${RESET} productos de seguro  |  ${CYAN}4${RESET} vaults aislados  |  ${CYAN}13${RESET} contratos verificados`,
        `  ${CYAN}79${RESET} tests pasando       |  ${CYAN}48h${RESET} timelock      |  ${CYAN}2-of-3${RESET} multisig`,
        ``,
        `${WHITE}Flujo:${RESET} ${GRAY}Humano${RESET} ${CYAN}->${RESET} ${GRAY}Agente IA${RESET} ${CYAN}->${RESET} ${GRAY}API${RESET} ${CYAN}->${RESET} ${GRAY}CoverRouter${RESET} ${CYAN}->${RESET} ${GRAY}Shield${RESET} ${CYAN}->${RESET} ${GRAY}Vault (lock 1:1)${RESET}`,
      ],
      // 2. Productos
      [
        `${BOLD}${CYAN}LOS 4 PRODUCTOS DE SEGURO${RESET}`,
        ``,
        `${BOLD}${CYAN}1. Black Swan Shield (BSS)${RESET}`,
        `  ${GRAY}Trigger:${RESET}    ${WHITE}ETH/BTC cae > ${RED}30%${RESET} ${GRAY}desde el precio de compra${RESET}`,
        `  ${GRAY}Payout:${RESET}     ${WHITE}Binario — ${GREEN}80%${RESET} ${GRAY}del coverage (20% deducible)${RESET}`,
        `  ${GRAY}Duracion:${RESET}   ${WHITE}7-30 dias${RESET}  ${GRAY}| Waiting: ninguno${RESET}`,
        `  ${GRAY}Verificacion: TWAP 15 min o 3 rounds consecutivos de Chainlink${RESET}`,
        ``,
        `${BOLD}${CYAN}2. Depeg Shield${RESET}`,
        `  ${GRAY}Trigger:${RESET}    ${WHITE}Stablecoin < ${RED}$0.95${RESET}`,
        `  ${GRAY}Payout:${RESET}     ${WHITE}DAI: ${GREEN}88%${RESET} ${GRAY}(12% ded)${RESET}  ${WHITE}USDT: ${GREEN}85%${RESET} ${GRAY}(15% ded)${RESET}  ${YELLOW}USDC: excluido${RESET}`,
        `  ${GRAY}Duracion:${RESET}   ${WHITE}14-365 dias${RESET}  ${GRAY}| Waiting: 24h${RESET}`,
        `  ${GRAY}Descuento:${RESET}  ${WHITE}91-180d: ${GREEN}10% off${RESET}  ${WHITE}181-365d: ${GREEN}20% off${RESET}`,
        ``,
        `${BOLD}${CYAN}3. IL Index Cover${RESET}`,
        `  ${GRAY}Trigger:${RESET}    ${WHITE}IL > ${RED}2%${RESET} ${GRAY}al vencimiento (European-style)${RESET}`,
        `  ${GRAY}Formula:${RESET}    ${CYAN}IL = 1 - (2*sqrt(r)) / (1+r)${RESET}`,
        `  ${GRAY}Payout:${RESET}     ${WHITE}Proporcional — Coverage x max(0, IL%-2%) x ${GREEN}90%${RESET}`,
        `  ${GRAY}Cap:${RESET}        ${WHITE}Max ${GREEN}11.7%${RESET} ${GRAY}del coverage${RESET}`,
        `  ${GRAY}Duracion:${RESET}   ${WHITE}14-90 dias${RESET}  ${GRAY}| Ventana: 48h${RESET}`,
        ``,
        `${BOLD}${CYAN}4. Exploit Shield${RESET}`,
        `  ${GRAY}Trigger:${RESET}    ${WHITE}DUAL — Token gov ${RED}-25%${RESET} ${GRAY}en 24h${RESET} ${WHITE}AND${RESET} ${GRAY}receipt token ${RED}-30%${RESET} ${GRAY}por 4h${RESET}`,
        `  ${GRAY}Payout:${RESET}     ${WHITE}Binario — ${GREEN}90%${RESET} ${GRAY}del coverage (10% deducible)${RESET}`,
        `  ${GRAY}Cap:${RESET}        ${YELLOW}$50,000 por wallet${RESET}`,
        `  ${GRAY}Duracion:${RESET}   ${WHITE}90-365 dias${RESET}  ${GRAY}| Waiting: 14 dias${RESET}`,
        `  ${GRAY}Cubiertos:${RESET}  ${WHITE}Compound, Uniswap, MakerDAO, Curve, Morpho${RESET}  ${YELLOW}Aave: excluido${RESET}`,
      ],
      // 3. Vaults
      [
        `${BOLD}${CYAN}VAULTS, APYs Y COLATERAL 1:1${RESET}`,
        ``,
        `${WHITE}Vault               Cooldown    Productos              APY Est.${RESET}`,
        `${CYAN}VolatileShort${RESET}       ${WHITE}30 dias${RESET}     ${GRAY}BSS + IL Index${RESET}          ${GREEN}12-16%${RESET}`,
        `${CYAN}VolatileLong${RESET}        ${WHITE}90 dias${RESET}     ${GRAY}IL largo + BSS overflow${RESET} ${GREEN}15-19%${RESET}`,
        `${CYAN}StableShort${RESET}         ${WHITE}90 dias${RESET}     ${GRAY}Depeg corto${RESET}             ${GREEN}11-15%${RESET}`,
        `${CYAN}StableLong${RESET}          ${WHITE}365 dias${RESET}    ${GRAY}Depeg + Exploit${RESET}         ${GREEN}18-27%${RESET}`,
        ``,
        `${WHITE}Composicion del Yield:${RESET}`,
        `  ${GRAY}Capa 1:${RESET} ${GREEN}Yield base Aave V3 (3-5% APY)${RESET}`,
        `  ${GRAY}Capa 2:${RESET} ${GREEN}Ingreso por primas de seguro${RESET}`,
        `  ${GRAY}Total:${RESET}  ${GREEN}${BOLD}11-27% APY${RESET} ${GRAY}segun vault${RESET}`,
        ``,
        `${WHITE}Caracteristicas:${RESET}`,
        `  ${CYAN}Colateral 1:1${RESET}    ${GRAY}— Cada $1 de cobertura = $1 USDC bloqueado${RESET}`,
        `  ${CYAN}Soulbound${RESET}        ${GRAY}— Shares no transferibles (anti-manipulacion)${RESET}`,
        `  ${CYAN}Yield Aave${RESET}       ${GRAY}— Incluso el colateral bloqueado genera yield en Aave V3${RESET}`,
        `  ${CYAN}U_MAX = 95%${RESET}      ${GRAY}— No se aceptan polizas si el vault esta 95%+ utilizado${RESET}`,
      ],
      // 4. Fees
      [
        `${BOLD}${CYAN}MODELO DE NEGOCIO (FEES)${RESET}`,
        ``,
        `${WHITE}Evento                    Fee        Descripcion${RESET}`,
        `${GRAY}Compra de poliza${RESET}          ${CYAN}3%${RESET}         ${GRAY}3% de la prima -> protocolo, 97% -> vault${RESET}`,
        `${GRAY}Pago de siniestro${RESET}         ${CYAN}3%${RESET}         ${GRAY}3% del payout -> protocolo, 97% -> agente${RESET}`,
        `${GRAY}Retiro de vault${RESET}           ${CYAN}3%${RESET}         ${GRAY}3% performance fee solo sobre ganancia positiva${RESET}`,
        ``,
        `${WHITE}Ejemplo Performance Fee:${RESET}`,
        `  ${GRAY}Deposito:${RESET} ${WHITE}$10,000${RESET}`,
        `  ${GRAY}Retiro:${RESET}   ${WHITE}$10,500${RESET}`,
        `  ${GRAY}Ganancia:${RESET} ${GREEN}$500${RESET}`,
        `  ${GRAY}Fee:${RESET}      ${CYAN}$15${RESET} ${GRAY}(3% x $500)${RESET}`,
        `  ${GRAY}Neto:${RESET}     ${GREEN}$10,485${RESET}`,
        ``,
        `${YELLOW}Sin ganancia = sin fee. Solo pagas cuando ganas.${RESET}`,
        ``,
        `${WHITE}Flywheel de Escalabilidad:${RESET}`,
        `  ${GRAY}Mas LPs -> Mas capacidad -> Mas polizas -> Mas fees -> Mas yield -> Mas LPs${RESET}`,
      ],
      // 5. Actuarial
      [
        `${BOLD}${CYAN}DATOS ACTUARIALES (MARGENES)${RESET}`,
        ``,
        `${WHITE}Producto              Primas Anuales    Siniestros Anuales  EV Neto      Margen${RESET}`,
        `${CYAN}Black Swan Shield${RESET}    ${GREEN}~$54,000${RESET}          ${RED}~$34,000${RESET}            ${GREEN}+$20,000${RESET}     ${GREEN}38%${RESET}`,
        `${CYAN}Depeg Shield${RESET}         ${GREEN}~$85,000${RESET}          ${RED}~$32,000${RESET}            ${GREEN}+$52,000${RESET}     ${GREEN}62%${RESET}`,
        `${CYAN}IL Index Cover${RESET}       ${GREEN}por modelo${RESET}        ${RED}por modelo${RESET}          ${GREEN}+$37,000${RESET}     ${GREEN}60%${RESET}`,
        `${CYAN}Exploit Shield${RESET}       ${GREEN}por modelo${RESET}        ${RED}por modelo${RESET}          ${GREEN}+$2,000${RESET}      ${GREEN}65%${RESET}`,
        ``,
        `${WHITE}Peor Escenario Sistemico:${RESET}`,
        `  ${GRAY}Evento:${RESET}       ${RED}Crash + depeg + exploit (simultaneos)${RESET}`,
        `  ${GRAY}Perdida:${RESET}      ${RED}-$438,000${RESET} ${GRAY}(-21.9% de $2M TVL)${RESET}`,
        `  ${GRAY}Recuperacion:${RESET} ${YELLOW}10-12 meses${RESET} ${GRAY}via acumulacion de primas${RESET}`,
        `  ${GRAY}Probabilidad:${RESET} ${GREEN}<0.1% anual${RESET}`,
        ``,
        `${WHITE}Multiplicadores Modelo Kink:${RESET}`,
        `  ${GRAY}0%:${RESET} ${WHITE}1.00x${RESET}  ${GRAY}20%:${RESET} ${WHITE}1.13x${RESET}  ${GRAY}40%:${RESET} ${WHITE}1.25x${RESET}  ${GRAY}60%:${RESET} ${WHITE}1.38x${RESET}`,
        `  ${GRAY}80%:${RESET} ${YELLOW}1.50x${RESET}  ${GRAY}85%:${RESET} ${YELLOW}1.88x${RESET}  ${GRAY}90%:${RESET} ${RED}2.25x${RESET}  ${GRAY}95%:${RESET} ${RED}RECHAZADO${RESET}`,
      ],
    ],
  },
}

function clear() { process.stdout.write('\x1b[2J\x1b[H') }

function showBanner(currentLang) {
  const c = content[currentLang]
  console.log(`
${CYAN}${BOLD}
  ██╗     ██╗   ██╗███╗   ███╗██╗███╗   ██╗ █████╗
  ██║     ██║   ██║████╗ ████║██║████╗  ██║██╔══██╗
  ██║     ██║   ██║██╔████╔██║██║██╔██╗ ██║███████║
  ██║     ██║   ██║██║╚██╔╝██║██║██║╚██╗██║██╔══██║
  ███████╗╚██████╔╝██║ ╚═╝ ██║██║██║ ╚████║██║  ██║
  ╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝
${RESET}
  ${GRAY}${c.subtitle}${RESET}
  ${DIM}${GRAY}Base L2 | USDC | Aave V3 | 2026${RESET}
`)
}

function showMenu(currentLang) {
  const c = content[currentLang]
  console.log(`${BOLD}${WHITE}  MENU${RESET}\n`)
  c.menu.forEach((item, i) => {
    const num = `${CYAN}[${i + 1}]${RESET}`
    console.log(`  ${num} ${GRAY}${item}${RESET}`)
  })
  console.log()
}

function showSection(currentLang, idx) {
  const lines = content[currentLang].sections[idx]
  console.log()
  lines.forEach(l => console.log(`  ${l}`))
  console.log()
}

async function waitEnter(currentLang) {
  const c = content[currentLang]
  process.stdout.write(`  ${DIM}${c.back}${RESET}`)
  return new Promise(resolve => {
    if (process.stdin.setRawMode) process.stdin.setRawMode(false)
    process.stdin.resume()
    process.stdin.once('data', () => resolve())
  })
}

async function getInput(currentLang) {
  const c = content[currentLang]
  process.stdout.write(`  ${c.prompt}`)
  return new Promise(resolve => {
    if (process.stdin.setRawMode) process.stdin.setRawMode(false)
    process.stdin.resume()
    process.stdin.once('data', (data) => {
      resolve(data.toString().trim())
    })
  })
}

async function main() {
  let currentLang = lang

  while (true) {
    clear()
    showBanner(currentLang)
    showMenu(currentLang)

    const choice = await getInput(currentLang)
    const num = parseInt(choice)

    if (num >= 1 && num <= 5) {
      clear()
      showSection(currentLang, num - 1)
      await waitEnter(currentLang)
    } else if (num === 6) {
      currentLang = currentLang === 'en' ? 'es' : 'en'
    } else if (num === 7) {
      clear()
      console.log(`\n  ${CYAN}Lumina Protocol${RESET} ${GRAY}— lumina-org.com${RESET}\n`)
      process.exit(0)
    }
  }
}

main().catch(console.error)
