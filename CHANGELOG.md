# Changelog

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
