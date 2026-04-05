# Storage Layouts

Storage layout files for UUPS upgradeable contracts. Used by auditors to verify storage compatibility between implementations.

Generated with: `forge inspect <Contract> storage-layout`

| Contract | File |
|----------|------|
| CoverRouter | CoverRouter-storage.json |
| PolicyManager | PolicyManager-storage.json |
| BaseVault | BaseVault-storage.json |

## Purpose
Before any UUPS upgrade, compare the new implementation's storage layout against the deployed version to ensure no storage collisions.
