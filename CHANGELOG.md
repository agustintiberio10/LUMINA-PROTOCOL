# Changelog

## [Unreleased]
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
### Known Issues
- **CRITICAL — Oracle key format mismatch (BCS/EAS/BSS)**: All three Volatile-asset shields call `IOracle.getLatestPrice(params.asset)` where `params.asset = bytes32("BTC")` or `bytes32("ETH")` (left-padded literal), but `LuminaOracle._feeds` is keyed by `keccak256("BTC")`/`keccak256("ETH")`. The on-chain Oracle reverts with `FeedNotRegistered` for the literal-bytes32 form. As a result, `createPolicy` on BCS, EAS, and the legacy BSS will revert before reaching `_doVerifyAndCalculate`. Fix path: either (a) re-deploy shields hashing the asset before calling the oracle, or (b) admin (Safe→Timelock) calls `oracle.registerFeed(bytes32("ETH"), ...)` and `bytes32("BTC")` to add the literal-bytes32 keys alongside the existing keccak ones. Verified via on-chain `isFeedActive` checks.

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
