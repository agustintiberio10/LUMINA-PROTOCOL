# Deploy Scripts

V2 ClaimBond deploy scripts will go here.

V1 vault model scripts are in `archive/v1-vault-model/script/`.

## Deprecated scripts

Scripts under `script/deprecated/` reference V1 / intermediate contract
addresses that pre-date the V5.1 redeploy on 2026-04-27 (and the
LuminaOracleV2 / CoverRouterV2 upgrades that followed). They compile (so
`forge build` keeps working) but **must not be executed against the
current Sepolia deployment** — running them would broadcast transactions
to contracts that no longer exist or are no longer in the canonical
registry.

Kept for historical reference only:

| Script | Reason |
|---|---|
| `script/deprecated/UpgradeShieldsAndRebind.s.sol` | Already executed (V1→V5.1 shield upgrade) |
| `script/deprecated/upgrade/UpgradeCoverRouterV2.s.sol` | Targets the V1 CoverRouter proxy `0x60447F88…`; the active V5.1 proxy is `0xebC3A78347…` |
| `script/deprecated/testnet-tests/00_ConfigureProducts.s.sol` | CoverRouter `0x71DBcE71AA…` (intermediate), no longer in registry |
| `script/deprecated/testnet-tests/01_BuyPolicy.s.sol` | Same CoverRouter + MockUSDC `0xd0De5D53…` (V1) |
| `script/deprecated/testnet-tests/02_TriggerPolicy.s.sol` | Uses `MockShieldOracle` (deprecated; replaced by `LuminaOracleV2`) |
| `script/deprecated/testnet-tests/03_SettlePolicy.s.sol` | FlashBTC1H `0xDcac6614E6…` (intermediate) |
| `script/deprecated/testnet-tests/04_VerifyNFT.s.sol` | ClaimBond V1 `0xd5f8678A0F…` |

For live testnet operations, fetch addresses from
`https://lumina-api-production-ac85.up.railway.app/health` (or read
`docs.lumina-org.com/contracts/deployed`). The current relayer
authorisation script (`script/ops/AuthorizeRelayer.s.sol`) keeps its
LIVE addresses and is **not** deprecated.
