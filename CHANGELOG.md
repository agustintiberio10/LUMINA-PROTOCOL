# Changelog

## [Unreleased] — V2 Oracle Migration
### Added
- **LuminaOracleV2** with EIP-712 domain-separated proof verification. The EIP-712 domain pins every proof to (`chainId = 8453`, `verifyingContract = LuminaOracleV2 address`), eliminating cross-chain and cross-contract replay vectors identified in the oracle audit.
- **5 V2 shields** (BCS V2, EAS V2, Depeg V2, IL V2, Exploit V2) consuming the new EIP-712 verification path on LuminaOracleV2 (`verifyPriceProofEIP712` / `verifyExploitGovProofEIP712`).
- **Relayer now signs proofs with `signTypedData`** (EIP-712 typed data) instead of raw `keccak256` digests. Proofs are auditable, hardware-wallet compatible, and bound to chain + contract by the domain separator.
- **Circuit breakers configurable via Safe batch**: `maxPayoutsPerDay`, `largePayoutThreshold`, `largePayoutDelay` can be adjusted by the Gnosis Safe without redeploying.

### Documentation fixes (honesty pass)
- Removed false **UUPS / upgradeable** claims for `LuminaOracle` and `LuminaPhalaVerifier`. Both contracts are `Ownable` and **NOT upgradeable** — replacement requires deploying a new instance, updating `CoverRouter.setOracle()`, and redeploying every Shield that references the old oracle (`Shield.oracle` is `immutable`).
- Removed false **TWAP** claims ("TWAP 15 min", "TWAP 30 min", "3 consecutive Chainlink rounds"). The contracts do not implement on-chain TWAP. The relayer reads Chainlink `latestRoundData` spot and signs the result via EIP-712.
- Removed false **Phala TEE hardware attestation / "tamper-proof"** claims. `LuminaPhalaVerifier` only performs `ecrecover` against an admin-curated `authorizedWorkers` set of EOAs. There is no on-chain SGX/TDX quote verification.
- Corrected BTC feed address in `LuminaOracle.sol` NatSpec: the old placeholder `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` was wrong for Base mainnet. The actually registered feed is `0xCCADC697c55bbB68dc5bCdf8d3CBe83CdD4E071E` (Chainlink BTC/USD on Base, already correctly registered on-chain and already correct in `PRODUCTION-ADDRESSES.md`).
- Added `@dev V1 — superseded by LuminaOracleV2` notice at the top of `LuminaOracle.sol` NatSpec.

## [Previous Unreleased entries]
### Added
- BTCCatastropheShield (BCS): BTC -50% trigger, 7-30d, pBase 15%, maxAlloc 30%
  Deployed 2026-04-06 at `0x36e37899D9D89bf367FA66da6e3CebC726Df4ce8`, registered in CoverRouter via Safe→Timelock.
- ETHApocalypseShield (EAS): ETH -60% trigger, 7-30d, pBase 20%, maxAlloc 25%
  Deployed 2026-04-06 at `0xA755D134a0b2758E9b397E11E7132a243f672A3D`, registered in CoverRouter via Safe→Timelock.
### Deprecated
- BlackSwanShield (BSS): Replaced by BCS + EAS. No new policies. Address registered in CoverRouter is `0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e`. The legacy orphan deploy `0x2926202bbe3f25f71ef17b25a20ebe8be028af5f` was never registered and is not used.
### Changed
- VolatileShort APY: 3.3%-22.2% → 3.9%-16.9%
- VolatileLong APY: 3.3%-24.7% → 4.0%-20.5%
### Security
- TimelockController `minDelay` changed from `172800` (48h, original deploy) to `0` for operational flexibility during pre-launch phase. Verified on-chain on 2026-04-06.
  **NOTE**: This MUST be reverted to `172800` (or higher) before institutional launch. The whitepaper documents a 48h delay as the security promise.
### Fixed
- **Oracle key format mismatch (BCS/EAS/BSS) — RESOLVED 2026-04-07** via Safe→Timelock batch (`script/safe-tx-register-oracle-feeds-bytes32.json`). The Volatile-asset shields call `IOracle.getLatestPrice(params.asset)` with `params.asset = bytes32("BTC")` or `bytes32("ETH")` (left-padded literal), but `LuminaOracle._feeds` was only keyed by `keccak256("BTC")`/`keccak256("ETH")`, so calls reverted with `FeedNotRegistered`. Fix: registered the literal `bytes32("ETH")` and `bytes32("BTC")` as alternate keys pointing to the same Chainlink aggregators (`0x71041d...` ETH/USD, `0xCCADC6...` BTC/USD) with the same 1200s staleness as the existing `keccak` entries. The original `keccak` keys are untouched. Verified on-chain: `isFeedActive(bytes32("ETH"))=true`, `isFeedActive(bytes32("BTC"))=true`, and `getLatestPrice` returns valid Chainlink prices for both. BCS/EAS `createPolicy` will no longer revert at the oracle step (still gated by per-product capacity, which depends on vault TVL).
- **Audit M-1 (BSS proof reuse) — RESOLVED at observation 2026-04-07.** The BSS shield (`0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e`) has `totalPolicies = 0` on-chain — never had a single policy in production. With BSS already `setProductActive(false)` (purchases blocked) and zero existing policies (no `policyId` for any agent), the cross-product oracle proof reuse vector documented in the audit is unreachable today: `triggerPayout` would call `BlackSwanShield.verifyAndCalculate(policyId)` which reverts `PolicyNotFound` for any non-existent policy id. No code change required. Risk only re-emerges if BSS is later reactivated via Safe→Timelock and someone purchases a policy; this is gated by the same governance that we already trust for product registration. To fully eliminate the residual risk, a future UUPS upgrade of CoverRouter could add an `unregisterProduct()` admin function that wipes `_products[productId]` — currently no such function exists.
- **Audit M-4 (vetoed payout has no agent retry path) — FIXED in code, pending UUPS upgrade.** `CoverRouter.cancelScheduledPayout` previously left `_policyResolved[productId][policyId] = true` after vetoing a scheduled large payout, permanently blocking the agent from re-triggering even if the original event still fell within coverage. The cancel now: (a) sets `_policyResolved[...] = false`, restoring the policy to triggerable state; and (b) no longer calls `releaseAllocation` — collateral stays locked so a re-trigger has backing and `PolicyManager._policyAllocations` is not double-decremented. If the agent never re-triggers, `cleanupExpiredPolicy` releases the allocation at expiry (it requires `!_policyResolved`, which the cancel restored). DOS via repeated vetoes is bounded by `MAX_VETOES_PER_WEEK`. Requires CoverRouter UUPS upgrade (proxy `0xd5f8678A0F2149B6342F9014CCe6d743234Ca025`) — implementation change only, no storage layout impact, no shield redeploy.
### Known Issues
- **Audit M-2 (strike price uses spot Chainlink, not TWAP)** — `BTCCatastropheShield._doCreatePolicy` and `ETHApocalypseShield._doCreatePolicy` set the strike via `IOracle.getLatestPrice(asset)`, which is a single Chainlink read. The trigger path (`_doVerifyAndCalculate`) consumes a TWAP-verified proof signed off-chain, but the strike side has no TWAP enforcement on-chain. `LuminaOracle.sol` explicitly documents that "This contract does NOT compute TWAPs" — TWAP is computed off-chain by the Lumina backend at claim time only. Mitigations in place: (1) `WAITING_PERIOD = 1h` makes any same-block strike-inflation attack useless; (2) Chainlink `maxStaleness = 1200s` prevents reading values much older than 20 min; (3) the attacker pays premium upfront with no immediate cash-out path. Cannot be fixed without redeploying BCS and EAS (they are non-upgradeable) or modifying `LuminaOracle` to expose a TWAP read function and re-deploying shields to call it. Documented for the next major shield revision.

## [2.0.0] - 2026-04-04

### Security
- ILIndexCover WAD/BPS conversion fix (C-1)
- BSS waiting period 0 → 1 hour (C-3)
- Storage gaps added to PolicyManager + CoverRouter (C-2)
- Option E: targeted veto + unrestricted claimable payouts
- Two-phase allocation release
- EmergencyPause with cooldown on unpause
- Sequencer downtime extension for claims
- Irrevocable cooldown for LPs
- Oracle multisig support (1-of-1, expandable to N-of-M)
- Try/catch on Aave interactions

### Added
- EmergencyPause contract (global circuit breaker)
- Product freeze per product
- 6h fallback trigger for offline agents
- USDC depeg monitoring (checkUSDCDepeg)
- ExploitShield $150K lifetime cap per wallet
- Configurable Aave pool address in ExploitShield
- setCooldownDuration setter for vaults

### Documentation
- OpenAPI 3.0 specification
- Contract ABIs published
- Storage layout exports
- Access Control Matrix
- Anti-Fraud Playbook (Option E)
- Vault Guide for LPs
- Claim Scenarios guide
- Aave Pause Guide

## [1.0.0] - 2026-03-29

### Added
- Initial deployment on Base mainnet
- 4 insurance products: BSS, Depeg, IL Index, Exploit
- 4 ERC-4626 vaults with cooldown
- Waterfall allocation system
- Chainlink oracle integration with L2 sequencer check
- EIP-712 quote signing
- Phala TEE dual-trigger for Exploit Shield
- Correlation groups (BSS+IL 70% cap)
- TimelockController governance
- Gnosis Safe 2-of-3 multisig
