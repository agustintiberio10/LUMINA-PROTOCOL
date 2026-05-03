# Lumina Protocol V5.0 -- Threat Model

Document version: 2026-04-15 | Branch: `feat/v5-phase4-integration-tests`

---

THREAT 1: Oracle Price Manipulation to Inflate Bond Capacity
Category: Economic
Actor: whale / MEV bot
Description: Attacker manipulates Uniswap V3 spot price upward for multiple blocks, inflating CapacityOracle TWAP. BondVault.issueBond() reads inflated price, computes higher reserveValueUSD, allowing over-issuance of bonds beyond real backing.
Impact: CRITICAL
Current mitigation: 30-minute TWAP window in CapacityOracle; SAFETY_FACTOR_BPS at 50% provides 2x buffer; MIN_PRICE circuit breaker at $0.005.
Test coverage: test_capacity_oracle_twap_window, test_bond_vault_safety_factor
Residual risk: Multi-block manipulation on Base (2s blocks) over 30 minutes costs ~900 blocks of capital. Cost may be low for thin-liquidity pools in early days.

THREAT 2: Oracle Price Suppression to Drain BondVault via Redemption
Category: Economic
Actor: whale
Description: Attacker suppresses LUMINA price, then redeems matured bonds. At lower price, `luminaAmount = usdAmount * 1e36 / currentPrice` yields more LUMINA per dollar of bonds, draining reserves faster.
Impact: HIGH
Current mitigation: [Fix C-3] MIN_REDEEM_PRICE raised to $0.005 (aligned with CoverRouter auto-pause floor). At the floor, $1 bond redeems 200 LUMINA (was 1M LUMINA at the old $0.001 floor). With 70M reserves, the vault sustains $350K of redemptions at the worst-case floor (was $70K). _getSafePrice() now reverts on oracle failure (no silent fallback to floor) and on prices ≥ MAX_REDEEM_PRICE = 1000e18 [F-REVERSE-1].
Test coverage: test_RedemptionAtMinPrice, test_RedemptionWithFailingOracle, test_RedemptionWithZeroOracle, test_DrainAttackBlocked, test_RedemptionWithAnomalouslyHighOracle.
Residual risk: At $0.005 floor, large epoch concentration ($350K+) still drains the vault. Bank-run defense (per-epoch cap, queue, pause) is the C-4 follow-up fix.

THREAT 3: BuybackEngine Double Burn Draining Reserves Below Solvency
Category: Economic
Actor: malicious admin (compromised BUYBACK_OPERATOR_ROLE)
Description: Operator sets high dailyBudget and maxPricePercent (95%), buys bonds at near-face-value, triggers Double Burn repeatedly. burnFromReserves removes LUMINA from BondVault, reducing solvency ratio. Solvency check uses stale SolvencyOracle state (evaluated daily).
Impact: CRITICAL
Current mitigation: 150% solvency circuit breaker (MIN_SOLVENCY_FOR_DOUBLE_BURN); 5% per-tx cap on burnFromReserves; ACTIVATION_DELAY of 365 days; AccessControl via multisig.
Test coverage: test_double_burn_solvency_breaker, test_burn_from_reserves_5pct_cap
Residual risk: Between daily SolvencyOracle evaluations, solvency can drop below 150% undetected. 5% cap compounds across multiple txs in same day.

THREAT 4: Sandwich Attack on TWAPBurner executeBurn
Category: Economic
Actor: MEV bot
Description: Bot observes pending executeBurn() TX, front-runs by buying LUMINA (raising price), lets burn execute at worse rate, then sells. Extracts up to maxSlippageBps (5%) of burn amount.
Impact: HIGH
Current mitigation: Oracle-derived amountOutMinimum when capacityOracle is set; maxBurnAmount caps single swap at $10K; burnCooldown of 15 minutes.
Test coverage: test_twap_burner_slippage_protection, test_burn_cooldown
Residual risk: If capacityOracle is not set, amountOutMinimum is 0. 5% of $10K = $500 extractable per burn cycle.

THREAT 5: ClaimBond setBondVault Front-Running
Category: Technical
Actor: malicious user
Description: Attacker monitors deployment mempool, calls setBondVault() with attacker-controlled address before the legitimate deployer, permanently bricking ClaimBond mint/burn.
Impact: CRITICAL
Current mitigation: setBondVault() is onlyOwner (deployer). Attacker cannot call it.
Test coverage: test_set_bond_vault_only_owner, test_set_bond_vault_one_shot
Residual risk: None if deployer uses private mempool or batched deployment. Risk if deployed on public mempool with separate transactions.

THREAT 6: Reentrancy via ERC-1155 Transfer Hooks
Category: Technical
Actor: malicious user
Description: Attacker deploys contract with malicious onERC1155Received that re-enters LuminaBondMarketplace.executeBuy() or BuybackEngine.executeOffer() during safeTransferFrom.
Impact: HIGH
Current mitigation: Both contracts use ReentrancyGuard. All state changes (listing.active = false, spentToday update) occur before external transfers.
Test coverage: test_marketplace_reentrancy_guard, test_buyback_reentrancy
Residual risk: Minimal. OpenZeppelin ReentrancyGuard is well-audited.

THREAT 7: Marketplace Fee Bypass via Direct ClaimBond Transfer
Category: Economic
Actor: malicious user
Description: Users trade ClaimBonds via direct ERC-1155 safeTransferFrom, bypassing marketplace entirely. No fees collected, no USDC flows to TWAPBurner.
Impact: MEDIUM
Current mitigation: None -- ClaimBond is freely transferable by design for composability.
Test coverage: N/A (by design)
Residual risk: Fee revenue from secondary trading may be lower than projected. Protocol relies on marketplace UX and BuybackEngine activity for fee generation.

THREAT 8: PolicyManager Router Hijack
Category: Operational
Actor: malicious admin
Description: Compromised multisig calls setRouter() on PolicyManagerV2 to point to attacker contract. Attacker contract calls recordPolicy() and triggerPayout() arbitrarily, issuing unlimited bonds.
Impact: CRITICAL
Current mitigation: setRouter() is onlyOwner (multisig). 2-of-3 threshold.
Test coverage: test_policy_manager_only_router
Residual risk: Relies entirely on multisig security. No timelock on router changes.

THREAT 9: CoverRouter Product Misconfiguration
Category: Operational
Actor: malicious admin
Description: Multisig configures a product with triggerProbBps=10000 (100%) and marginBps=1 (0.01x), resulting in near-zero premiums for maximum coverage. Attacker buys policies, triggers them, gets bonds for almost free.
Impact: HIGH
Current mitigation: onlyOwner gating. No on-chain bounds on individual pricing parameters.
Test coverage: test_configure_product_valid_params
Residual risk: No minimum premium ratio enforced in code. Admin must manually verify configuration correctness.

THREAT 10: SolvencyOracle Stale Quadrant
Category: Economic
Actor: N/A (systemic)
Description: SolvencyOracle requires external caller to invoke evaluate() daily. If no one calls it, quadrant remains stale. AdaptiveFeeDistributor uses stale quadrant, potentially distributing 88% to burn during a crisis instead of routing to buyback.
Impact: HIGH
Current mitigation: isHealthy() returns false if lastEvaluation > 7 days ago. TWAPBurner falls back to hardcoded ratios (88/10/2).
Test coverage: test_solvency_oracle_staleness, test_twap_burner_fallback_distribution
Residual risk: Fallback ratios (88% burn) are identical to Healthy/Stable. During a crisis, the fallback still over-burns. 7-day staleness window is long.

THREAT 11: BondVault Circuit Breaker Flap Attack
Category: Technical
Actor: griefer
Description: Attacker manipulates price briefly below $0.005 to trigger circuit breaker (permissionless triggerBreaker()). Bond issuance halts. After 1-hour cooldown and price recovery to $0.008, attacker resets and re-triggers.
Impact: MEDIUM
Current mitigation: BREAKER_COOLDOWN of 1 hour; hysteresis gap ($0.005 trigger / $0.008 reset) requires significant capital to repeatedly cross.
Test coverage: test_circuit_breaker_cooldown, test_breaker_hysteresis
Residual risk: On thin-liquidity pools, cost to flash price below $0.005 may be low. Repeated flapping blocks new policy issuance.

THREAT 12: CEXLiquidityReserve Monthly Cap Bypass via Timing
Category: Governance
Actor: malicious admin
Description: ALLOCATOR_ROLE calls allocate() just before month boundary, then again just after, effectively allocating 2M LUMINA in a short window (1M per "month"). Month is calculated as `(timestamp - deploymentTimestamp) / 30 days`.
Impact: MEDIUM
Current mitigation: MONTHLY_CAP of 1M LUMINA per 30-day period. Each allocation checks `monthlySpent + amount <= MONTHLY_CAP`.
Test coverage: test_cex_reserve_monthly_cap
Residual risk: Edge-case: allocating 1M at day 29.9 and 1M at day 30.1 yields 2M in ~5 hours. Multisig governance is the ultimate safeguard.

THREAT 13: BuybackEngine Activation Delay Bypass
Category: Technical
Actor: malicious user
Description: Attacker attempts to call executeOffer() or setDailyBuyback() before the 365-day activation delay passes.
Impact: LOW
Current mitigation: `_isActivated()` checks `block.timestamp >= deploymentTimestamp + ACTIVATION_DELAY`. deploymentTimestamp is immutable, set in constructor.
Test coverage: test_buyback_activation_delay
Residual risk: None. Immutable timestamp cannot be manipulated.

THREAT 14: AdaptiveFeeDistributor Distribution Sum Overflow
Category: Technical
Actor: N/A (code bug)
Description: If SolvencyOracle returns out-of-range quadrant values (sLevel >= 4 or mLevel >= 4), _lookupDistribution reverts, causing TWAPBurner._getDistribution() to catch the revert and use fallback.
Impact: LOW
Current mitigation: Require statements in _lookupDistribution. TWAPBurner wraps in try/catch with safe fallback. Additionally checks `burnBps + buybackBps + opsBps <= 10000`.
Test coverage: test_adaptive_fee_all_quadrants, test_invalid_quadrant_fallback
Residual risk: Fallback is always safe. No funds at risk.

THREAT 15: TreasuryVesting Early Drain
Category: Governance
Actor: malicious admin
Description: After 6-month lock, compromised multisig calls release() every month for the max 250K LUMINA, depleting the 3M treasury in 12 months.
Impact: MEDIUM
Current mitigation: MAX_MONTHLY_RELEASE of 250K. Month tracking via lastReleaseMonth prevents multiple releases per month. totalReleased cap at TOTAL_AMOUNT.
Test coverage: test_treasury_vesting_monthly_cap, test_treasury_lock_period
Residual risk: Over 12 months, all 3M can be legitimately extracted. This is by design but depends on multisig discipline.

THREAT 16: FounderVesting Oracle Manipulation
Category: Economic
Actor: malicious admin (founder)
Description: Founder manipulates oracle to report ETH > $4000 and ETH/BTC > 0.050 for 7 consecutive days, triggering AltSeason prematurely. 8M LUMINA unlocks in 3 tranches over ~2 months.
Impact: HIGH
Current mitigation: Oracle is immutable in constructor. Conditions require 2-of-3 including Aave borrow rate (harder to manipulate). 7-day sustained duration.
Test coverage: test_founder_vesting_alt_season_conditions, test_sustained_duration
Residual risk: If founder controls the oracle key, conditions can be spoofed. 4-year fallback exists regardless.

THREAT 17: Marketplace Listing Griefing -- Stale Listings
Category: Technical
Actor: griefer
Description: Attacker lists bonds at extremely high prices, creating noise. Or lists then transfers their ClaimBonds away, making listings unbuyable (safeTransferFrom from marketplace fails since marketplace holds the bonds after listing -- actually bonds are transferred to marketplace on list()).
Impact: LOW
Current mitigation: Bonds are custodied by marketplace on listing. Seller can cancel to retrieve. Buyer pays market price.
Test coverage: test_marketplace_list_cancel
Residual risk: Minimal. Stale high-price listings are simply ignored.

THREAT 18: TWAPBurner USDC Accumulation During Extended Downtime
Category: Operational
Actor: N/A (systemic)
Description: If no keeper calls executeBurn() for extended periods, USDC accumulates. When finally called, maxBurnAmount ($10K) limits single execution, but accumulated balance creates predictable MEV opportunity across multiple burns.
Impact: MEDIUM
Current mitigation: maxBurnAmount caps per-execution exposure. burnCooldown of 15 minutes spaces executions. Permissionless execution means anyone can trigger.
Test coverage: test_twap_burner_max_burn_cap
Residual risk: After long accumulation, a sequence of burns at 15-minute intervals creates predictable trading pattern for MEV extraction.

THREAT 19: BondVault decreaseObligations Without Actual Bond Burn
Category: Technical
Actor: malicious admin (via compromised authorized caller)
Description: Authorized caller calls decreaseObligations() to reduce totalCommittedUSD without actually burning corresponding ClaimBond tokens. This inflates solvency ratio artificially, enabling more bond issuance than reserves can back.
Impact: CRITICAL
Current mitigation: Only addresses authorized via setAuthorizedCaller() (gated by policyManager) can call. BuybackEngine atomically burns bonds then decreases obligations in _executeDoubleBurn().
Test coverage: test_decrease_obligations_authorized_only, test_double_burn_atomicity
Residual risk: If a custom authorized caller is added that does not burn bonds before calling decreaseObligations, the invariant breaks. No on-chain enforcement of burn-before-decrease.

THREAT 20: LuminaTokenV2 BURNER_ROLE Permanent Lock
Category: Governance
Actor: malicious admin
Description: DEFAULT_ADMIN_ROLE holder renounces the admin role. BURNER_ROLE can never be granted to a new address. If TWAPBurner is replaced or compromised, no new burner can be authorized, permanently disabling the burn mechanism.
Impact: HIGH
Current mitigation: Warning comment in LuminaTokenV2 source code [L-10]. Admin should only renounce after confirming TWAPBurner stability.
Test coverage: test_burner_role_management
Residual risk: Human error. If admin renounces prematurely, burn mechanism is permanently locked to current TWAPBurner address.

THREAT 21: Cross-Contract Decimal Mismatch in BondVault Capacity Check
Category: Technical
Actor: N/A (code bug)
Description: BondVault.issueBond() normalizes usdPayout to 18-dec (`usdPayout * 1e18`) for capacity comparison. PolicyManagerV2 passes `payoutUSD = payoutAmount / 1e6` (integer dollars). If rounding causes payoutUSD to be 0 for small policies (< $1), bonds are issued with zero USD commitment, inflating capacity.
Impact: MEDIUM
Current mitigation: PolicyManagerV2 enforces `require(payoutUSD > 0, "Payout too small for bond issuance")` [M-6]. CoverRouterV2 enforces minimum coverage of $100.
Test coverage: test_minimum_payout_enforcement, test_min_coverage_100usd
Residual risk: Minimal with current $100 minimum coverage and 80% payout ratio ($80 minimum payout).

THREAT 22: Marketplace executeBuy Fee Transfer to Non-Compliant TWAPBurner
Category: Technical
Actor: malicious admin
Description: FEE_MANAGER_ROLE changes twapBurner to a contract that reverts on USDC receipt. All marketplace purchases revert, freezing bond trading.
Impact: HIGH
Current mitigation: setTwapBurner() is gated by FEE_MANAGER_ROLE (multisig). Marketplace uses safeTransfer (reverts on failure, does not silently fail).
Test coverage: test_marketplace_fee_routing
Residual risk: Relies on multisig not setting a broken twapBurner address. No validation that new address can receive USDC.
