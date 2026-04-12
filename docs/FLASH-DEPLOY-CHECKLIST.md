# Flash Insurance — Deploy Checklist

## Pre-deploy (done)
- [x] FlashVault.sol compiles
- [x] 4 Flash shields compile
- [x] 273+ tests passing
- [x] SKILL updated with Flash products
- [x] API updated with duration routing
- [x] Frontend config updated

## Deploy (sequential, order matters)
- [ ] Deploy FlashVault (UUPS proxy)
- [ ] Deploy FlashBTCShield24h
- [ ] Deploy FlashBTCShield48h
- [ ] Deploy FlashETHShield24h
- [ ] Deploy FlashETHShield48h
- [ ] Register 4 shields in CoverRouter (registerProduct x 4)
- [ ] **CRITICAL: Create correlation group FLASH_CRASH cap 60% in PolicyManager**
      Without this, the 4 shields can use up to 120% of vault = INSOLVENCY RISK
      ```
      PolicyManager.createCorrelationGroup("FLASH_CRASH", 6000)
      PolicyManager.addProductToGroup("FLASH_CRASH", keccak256("FLASHBTC24-001"))
      PolicyManager.addProductToGroup("FLASH_CRASH", keccak256("FLASHBTC48-001"))
      PolicyManager.addProductToGroup("FLASH_CRASH", keccak256("FLASHETH24-001"))
      PolicyManager.addProductToGroup("FLASH_CRASH", keccak256("FLASHETH48-001"))
      ```
- [ ] Transfer FlashVault ownership to TimelockController
- [ ] Seed deposit USDC in FlashVault

## Post-deploy verification
- [ ] Verify FlashVault totalAssets()
- [ ] Verify each shield points to FlashVault
- [ ] Verify correlation group is active (getCorrelationGroup)
- [ ] Test purchase: Flash BTC 24h for $100
- [ ] Test purchase: Flash ETH 48h for $100
- [ ] Update Railway env vars (FLASH_VAULT, FLASH_BTC_24H_SHIELD, etc.)
- [ ] Update SKILL with real addresses (replace TBD)
- [ ] Sync SKILL to frontend (3 copies identical)
- [ ] Verify on lumina-org.com/LUMINA-SKILL.txt
