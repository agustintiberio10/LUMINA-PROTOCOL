# Lumina Protocol V1 — Vault Model (Archived)

This directory contains the complete V1 codebase of Lumina Protocol,
which used a vault-based insurance model with LP deposits.

**This model has been replaced by the ClaimBond model (V2).**

The V1 contracts were deployed on Base mainnet and operated with real USDC.
They are preserved here for:
- Transparency and audit trail
- Reference for V2 development
- Historical documentation

## V1 → V2 Changes
- Vaults eliminated (no more LP deposits)
- 6 old products eliminated, 9 new products created
- ClaimBond (ERC-1155) replaces USDC payouts
- 100% premium burn (was vault-based yield)
- New token (LuminaTokenV2) with 82/10/5/3 distribution
- BondVault (immutable, no owner, no withdraw)

## V2 Source of Truth
See `docs/SKILL.md` in the repo root.
