# Flash Insurance — Deploy Checklist

## Pre-deploy (done)
- [x] FlashVault.sol compiles
- [x] 4 Flash shields compile
- [x] 282 tests passing
- [x] SKILL updated with Flash products
- [x] API updated with duration routing
- [x] Frontend config updated

## Deploy (done 2026-04-13)
- [x] Deploy FlashVault (UUPS proxy): `0x65D22E9BfE79306433Bf93Da9B0e5b626b8D021b`
- [x] Deploy FlashBTCShield24h: `0x1A6b379dA1C5F804aa0D89e57ce05424219ce933`
- [x] Deploy FlashBTCShield48h: `0xcEDe02A77F1708342a7225D41d2b18A70b5FDDc7`
- [x] Deploy FlashETHShield24h: `0x5304f6732a51995651f1B666525CFeC5Af74A541`
- [x] Deploy FlashETHShield48h: `0xA81FD43540679A39660960268585e876732ce19E`
- [x] All 6 contracts verified on BaseScan
- [x] FlashVault ownership transferred to TimelockController
- [x] On-chain params verified (triggers, durations, deductibles, cooldown)
- [x] SKILL + PRODUCTION-ADDRESSES updated with real addresses
- [x] Safe batch JSON generated: SAFE-BATCH-REGISTER-FLASH.json

## Safe multisig (pending — execute via app.safe.global)
- [ ] Register 4 shields in CoverRouter (registerProduct x 4)
- [ ] **CRITICAL: Create correlation group FLASH_CRASH cap 60% in PolicyManager**
- [ ] Add all 4 Flash products to FLASH_CRASH group
      Safe batch file: SAFE-BATCH-REGISTER-FLASH.json
      Contains: scheduleBatch + executeBatch (9 calls, minDelay=0)

## Post-registration
- [ ] Seed deposit USDC in FlashVault
- [ ] Update Railway env vars
- [ ] Test purchase: Flash BTC 24h for $100
- [ ] Test purchase: Flash ETH 48h for $100
- [ ] Verify correlation group active on-chain
