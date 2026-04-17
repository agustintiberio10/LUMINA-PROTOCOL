# Risk Disclosures — Lumina Protocol V2

## 1. Smart Contract Risk

**Audits performed:**
- Internal line-by-line audit (5 parallel senior-auditor agents, 14 contracts, ~300 findings triaged). See `docs/LINE-BY-LINE-AUDIT.md`.
- Security review round 1 + 2 + 3 with fix verification. See `docs/SECURITY-AUDIT-V4.md`.
- CertiK-style adversarial simulation (22 attack vectors). See `test/audit/CertiKSimulation.t.sol`.
- 5 BondVault invariants across 250,000 randomized call sequences. See `test/invariant/`.
- Slither static analysis: 0 HIGH, 0 MEDIUM findings. See `docs/SLITHER-FINDINGS.md`.

**External audit status:** TBD — Zellic, Spearbit, or CertiK engagement planned pre-mainnet.

**Known gaps:**
- Full Uniswap V3 pool lifecycle integration test deferred to staging (requires live pool creation). See `test/integration/CapacityOracleFork.t.sol`.
- CapacityOracle `!isToken0Lumina` branch (token1-Lumina decimal handling) requires deployment-time empirical verification. Mitigated by CREATE2 salt mining ensuring LUMINA is always token0.

## 2. Oracle Risk

**Primary oracle:** CapacityOracle reads Uniswap V3 TWAP (30-minute window) for LUMINA/USDC price.

**Risks:**
- **TWAP manipulation:** 30-minute window resists single-block flash loan attacks. Sustained manipulation for 30+ minutes on a thin-liquidity pool is expensive but not impossible post-LBP when liquidity is low (~$50K-100K POL). Increasing the window to 1-2 hours post-launch is recommended.
- **Emergency fallback:** If TWAP read fails (pool not deployed, insufficient observation cardinality, revert), `emergencyPrice` is returned. This is owner-settable — if owner key is compromised, the oracle can be manipulated. Mitigated by Gnosis Safe + Timelock ownership.
- **Tick rounding:** Corrected in LBL-H3 to match Uniswap V3 OracleLibrary's floor semantics for negative tick deltas (downtrends). Bias eliminated.

**Trigger oracles:** Chainlink price feeds for BTC/ETH (on Base mainnet) via EIP-712 signed proofs from the relayer. No on-chain Chainlink direct reads for triggers (relayer mediates).

## 3. BondVault Depletion Risk

**Scenario:** If LUMINA price crashes 36x+ between bond issuance and maturity (24 months), a single $100K bond at $0.001/LUMINA would require 100M LUMINA — exceeding the 82M vault.

**Mitigations:**
- **SAFETY_FACTOR = 50%**: BondVault only commits up to 50% of its USD-denominated reserve value at issuance time.
- **Capacity check at issuance**: `require(totalCommittedUSD + usdPayout * 1e18 <= maxCommitUSD)` prevents over-commitment at current price.
- **Circuit breaker**: If LUMINA drops below $0.005, new issuance is paused (persistent via `triggerBreaker()`). Reset requires price recovery to $0.008 + 1-hour cooldown.
- **MIN_REDEEM_PRICE = $0.001**: Redemptions below this price floor revert, preventing catastrophic drain at dust prices.
- **24-month maturity spread**: Bonds mature in monthly epochs, distributing redemption pressure over time rather than allowing simultaneous mass-exit.

**Residual risk:** A sustained 90%+ price decline over 24 months combined with concentrated maturity epochs could still exhaust the reserve for late redeemers. This is a protocol-level economic risk, not a contract bug.

## 4. Upgrade Risk

**Immutable contracts (cannot be changed after deploy):**
- `BondVault` — no owner, no withdraw, no admin, no upgrade. 82M LUMINA only exits via `redeemBond()`. Verified by grep + invariant testing.
- `ClaimBond` (ERC-1155) — `setBondVault` is one-shot `onlyOwner`. Once set, the vault pointer is permanent.
- `LuminaTokenV2` — fixed supply, no mint. `BURNER_ROLE` management via `DEFAULT_ADMIN_ROLE`.

**Upgradeable contracts (via Timelock + Gnosis Safe 2/3):**
- `CoverRouter` (V1, UUPS with 47-slot gap)
- `PolicyManager` (V1, UUPS with 49-slot gap)

**Non-upgradeable but admin-configurable:**
- `CoverRouterV2` — owner can: pause, configure products, set relayers, swap PolicyManager/TWAPBurner addresses.
- `PolicyManagerV2` — owner can: set router, register/deactivate products.
- `TWAPBurner` — owner can: set pool fee, slippage, burn amounts, cooldown, oracle.
- `CapacityOracle` — owner can: set pool, TWAP window, emergency price.
- `FounderVesting` — owner can: update recipient.
- `TreasuryVesting` — owner can: release funds (max 250K/month after 6-month lock).

**Key rotation:** All owner roles are held by a Gnosis Safe multisig (2-of-3). Admin changes go through a 48-hour TimelockController.

## 5. Liquidity Risk

- **LBP (Fjord Foundry):** 5M LUMINA (5% of supply) launched over 72 hours with 96/4 → 50/50 weight curve. Expected raise: $52K-$133K USDC.
- **POL (Protocol-Owned Liquidity):** 100% of LBP proceeds seed the Uniswap V3 LUMINA/USDC pool. No team-held LP tokens.
- **Slippage on redemptions:** At $0.036/LUMINA and $50K POL, an $800 bond redemption (22,222 LUMINA at launch price) represents ~44% of pool depth — significant slippage. Mitigated by TWAPBurner's distributed micro-swaps (max $10K per 15 minutes) and 24-month maturity buffer.
- **Secondary bond market:** ERC-1155 ClaimBonds are transferable. A secondary marketplace (LuminaBondMarketplace.sol) is planned with 3% fee (1.5% buyer + 1.5% seller), 100% burned.

## 6. Regulatory Risk

Lumina Protocol is a decentralized, permissionless smart contract system deployed on Base L2. It does not custody user funds, does not require KYC, and does not make investment recommendations.

The protocol's "parametric insurance" products function as binary prediction markets / parametric bets, not as regulated insurance products. Users should consult their own legal and tax advisors.

The team does not represent or guarantee any returns, token price appreciation, or insurance-like protection. Bond payouts are denominated in USD but settled in $LUMINA at market price — users bear the price risk of the $LUMINA token during the 24-month maturity period.

This document is for informational purposes only and does not constitute financial advice.
