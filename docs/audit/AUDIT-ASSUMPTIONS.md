# Lumina Protocol V5.0 -- Audit Assumptions

Document version: 2026-04-15 | Branch: `feat/v5-phase4-integration-tests`

---

## Oracle Assumptions

ASSUMPTION 1: Chainlink / Custom Oracle Liveness
Description: CapacityOracle's `getLuminaPrice()` returns a valid TWAP within 30 minutes of real-time. BondVault, SolvencyOracle, and BuybackEngine all depend on this single price source.
Why it matters: If the oracle returns stale or zero price, BondVault's `_getSafePrice()` reverts ([Fix C-3] removed silent fallback to MIN_REDEEM_PRICE; [F-REVERSE-1] also reverts on values ≥ MAX_REDEEM_PRICE = 1000e18). Redemptions block until admin replaces the oracle. SolvencyOracle computes infinite solvency when obligations are zero, masking real risk.
How we validate: Integration test: mock oracle returning 0 and verify `_getSafePrice()` reverts with "Oracle price out of range"; mock oracle returning ≥ 1000e18 and verify same revert; verify SolvencyOracle.isHealthy() returns false when price is 0.
Risk if fails: CRITICAL

ASSUMPTION 2: Uniswap V3 TWAP Manipulation Resistance
Description: The 30-minute TWAP window (configurable 5min-2hr) on CapacityOracle is sufficient to resist spot manipulation on Base L2.
Why it matters: A manipulated TWAP inflates vault capacity, allowing over-issuance of bonds. Deflated TWAP triggers false circuit breakers, halting issuance. TWAPBurner derives slippage bounds from this price.
How we validate: Verify `twapWindow >= 300` enforced in `setTwapWindow()`. Simulate multi-block manipulation cost at Base L2 block times.
Risk if fails: CRITICAL

ASSUMPTION 3: Oracle Signature Authenticity (EIP-712)
Description: BaseShield's `_verifyPriceProofEIP712` assumes the oracle key cannot be compromised and that domain separator pins proofs to the correct chain and oracle instance.
Why it matters: A forged oracle proof triggers arbitrary bond issuance, draining BondVault reserves.
How we validate: Unit test: verify proofs from wrong chain/oracle/signer are rejected. Verify `verifiedAt` timestamp checked against policy coverage window.
Risk if fails: CRITICAL

## Base L2 Timing

ASSUMPTION 4: Base Sequencer Uptime
Description: BaseShield extends claim grace period by `IOracle.getSequencerDowntime()` to handle sequencer outages. Assumes the sequencer downtime oracle reports accurately.
Why it matters: If sequencer is down and downtime is underreported, legitimate claims within the 24h grace period are rejected. Policies silently expire during downtime.
How we validate: Integration test: simulate sequencer downtime, verify adjustedCleanupAt extends correctly, verify claims for in-coverage events succeed post-downtime.
Risk if fails: HIGH

ASSUMPTION 5: Base Block Times (~2s)
Description: TWAPBurner cooldown (900s), SolvencyOracle evaluation interval (1 day), and BondVault breaker cooldown (1 hour) assume consistent ~2s block production.
Why it matters: If block production halts or slows significantly, time-dependent state transitions (burn execution, quadrant changes, breaker resets) are delayed. Pending USDC in TWAPBurner accumulates, creating large single-swap impact.
How we validate: Verify maxBurnAmount ($10K cap) limits single-swap exposure. Verify cooldown logic uses `block.timestamp` not `block.number`.
Risk if fails: MEDIUM

## Multisig / Governance

ASSUMPTION 6: Gnosis Safe 2-of-3 Integrity
Description: PolicyManagerV2 owner, TWAPBurner owner, CoverRouterV2 owner, and BuybackEngine DEFAULT_ADMIN_ROLE are controlled by a 2-of-3 Gnosis Safe. Assumes at least 2 signers remain honest and available.
Why it matters: A compromised multisig can: reconfigure products with zero premiums, change TWAPBurner reserves, authorize arbitrary callers on BondVault, pause/unpause CoverRouter, and drain CEXLiquidityReserve allocations.
How we validate: Verify all admin functions are onlyOwner/onlyRole. Verify no single-signer backdoors exist. Review Safe configuration on-chain post-deployment.
Risk if fails: CRITICAL

ASSUMPTION 7: BondVault Authorization Chain
Description: `setAuthorizedCaller()` on BondVault is gated by `policyManager` (immutable). PolicyManagerV2 owner (multisig) must first call this to authorize BuybackEngine for `decreaseObligations` and `burnFromReserves`.
Why it matters: If policyManager address is incorrect at deployment, no entity can ever authorize callers on BondVault (immutable, no admin). BuybackEngine becomes permanently non-functional.
How we validate: Deployment script test: verify policyManager is set correctly. Verify authorized caller can call decreaseObligations and burnFromReserves.
Risk if fails: HIGH

## Gas and Economic

ASSUMPTION 8: Gas Costs on Base L2
Description: Gas costs for TWAPBurner.executeBurn() (Uniswap swap + burn) and CoverRouter.purchasePolicy() remain economically viable on Base.
Why it matters: If L1 data costs spike (e.g., blobs full), keeper execution of executeBurn() may become unprofitable, stalling the burn mechanism and accumulating USDC.
How we validate: Monitor keeper profitability. Verify minBurnAmount ($1) is low enough for frequent small burns.
Risk if fails: LOW

## Token Behavior

ASSUMPTION 9: USDC 6-Decimal Consistency
Description: All premium calculations, fee computations, and capacity checks assume USDC uses 6 decimals. Coverage amounts are in 6-dec USDC; bond payouts convert via `payoutAmount / 1e6` to integer dollars.
Why it matters: If USDC is upgraded to different decimals or a non-6-decimal stablecoin is used, all pricing math silently produces wrong results. PolicyManagerV2 line 157: `payoutUSD = payoutAmount / 1e6`.
How we validate: Assert `usdc.decimals() == 6` in deployment scripts. CoverRouterV2 hardcodes min coverage as `100e6`.
Risk if fails: CRITICAL

ASSUMPTION 10: LUMINA 18-Decimal and Burn Semantics
Description: LuminaTokenV2 is ERC20Burnable with 18 decimals. BondVault calls `IBurnable(lumina).burn(amount)` which burns from the caller's balance (BondVault holds the tokens). TWAPBurner similarly burns after receiving from swap.
Why it matters: If burn() does not reduce totalSupply or reverts unexpectedly, the deflationary mechanism breaks. BondVault.burnFromReserves would revert, blocking BuybackEngine Double Burn entirely.
How we validate: Unit test: verify totalSupply decreases after burn. Verify BondVault holds LUMINA and burn() succeeds.
Risk if fails: HIGH

## Uniswap V3 / DEX Interaction

ASSUMPTION 11: Uniswap V3 Pool Liquidity
Description: TWAPBurner swaps USDC for LUMINA on a 1% fee tier Uniswap V3 pool. Assumes sufficient liquidity exists for up to $10K swaps with <= 5% slippage.
Why it matters: Insufficient liquidity causes swaps to revert (amountOutMinimum check) or produces extreme slippage, wasting protocol revenue. If capacityOracle is not set, amountOutMin defaults to 0, allowing sandwich attacks.
How we validate: Verify capacityOracle is set in production. Monitor pool TVL. Verify maxSlippageBps (5%) and maxBurnAmount ($10K) bound exposure.
Risk if fails: HIGH

## ERC-1155 Transfer Hooks

ASSUMPTION 12: ClaimBond ERC-1155 Receiver Compliance
Description: LuminaBondMarketplace and BuybackEngine use `safeTransferFrom` for ClaimBond ERC-1155 tokens. Both inherit ERC1155Holder to accept transfers. External buyers must also implement onERC1155Received or be EOAs.
Why it matters: If a buyer contract does not implement ERC1155Holder, marketplace purchases revert, locking the seller's bonds in the marketplace contract until cancelled. BuybackEngine execution also reverts.
How we validate: Verify BuybackEngine and Marketplace inherit ERC1155Holder and override supportsInterface. Integration test: contract-to-contract bond transfer.
Risk if fails: MEDIUM

## Deploy Ordering

ASSUMPTION 13: Circular Dependency Resolution
Description: ClaimBond requires BondVault address (one-shot `setBondVault()`), but BondVault requires ClaimBond at construction. Deploy order: ClaimBond -> BondVault -> setBondVault(). If setBondVault is front-run or forgotten, ClaimBond is permanently bricked.
Why it matters: `setBondVault()` is onlyOwner and one-shot (`_bondVaultSet` flag). A front-run attack on mempool is mitigated by onlyOwner, but forgetting to call it post-deploy bricks all mint/burn.
How we validate: Deployment script must atomically deploy and call setBondVault in same transaction batch. Verify _bondVaultSet == true post-deploy.
Risk if fails: CRITICAL

## Contract Initialization

ASSUMPTION 14: SolvencyOracle Initial State
Description: SolvencyOracle initializes at quadrant (1,1) = Healthy/Stable with empty history arrays. The 7-day cooldown between quadrant changes means the system cannot react to a crisis for at least 7 days after deployment.
Why it matters: If a crisis occurs within the first week, AdaptiveFeeDistributor uses the default Healthy/Stable distribution (88% burn, 10% buyback), potentially under-funding buyback reserves when the protocol most needs defense.
How we validate: Verify initial quadrant is documented. Verify COOLDOWN_BETWEEN_QUADRANT_CHANGES is acceptable for launch conditions.
Risk if fails: MEDIUM

## MEV on Base

ASSUMPTION 15: MEV Resistance of TWAPBurner Swaps
Description: TWAPBurner executes permissionless swaps with oracle-derived slippage protection. Assumes MEV searchers on Base cannot profitably sandwich swaps bounded by maxSlippageBps (5%) and maxBurnAmount ($10K).
Why it matters: Without capacityOracle set, amountOutMinimum is 0, making every burn a free sandwich opportunity. Even with oracle protection, 5% slippage on $10K is $500 extractable per burn.
How we validate: Verify capacityOracle is non-zero before mainnet launch. Consider reducing maxSlippageBps to 200 (2%) post-liquidity-establishment. Verify burnCooldown prevents rapid repeated extraction.
Risk if fails: HIGH

ASSUMPTION 16: Marketplace Front-Running
Description: LuminaBondMarketplace executeBuy() is permissionless. A front-runner can observe a pending buy TX and submit their own buy first, then relist at higher price.
Why it matters: Sellers receive fair payment regardless, but buyers pay inflated prices. BuybackEngine is especially vulnerable as its daily config (maxPricePercent, dailyBudget) is public on-chain.
How we validate: Verify BuybackEngine's maxPricePercent cap limits overpayment. Consider private mempools or commit-reveal for high-value listings.
Risk if fails: MEDIUM
