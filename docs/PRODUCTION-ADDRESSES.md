# Lumina Protocol - Production Addresses (Base L2, Chain 8453)

## Governance
- TimelockController: `0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a`
- Gnosis Safe (2-of-3): `0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD`

## Core
- CoverRouter: `0xd5f8678A0F2149B6342F9014CCe6d743234Ca025`
- PolicyManager: `0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a`
- LuminaOracle: `0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87`
- EmergencyPause: `0xc7ac8c19c3f10f820d7e42f07e6e257bacc22876`
- LuminaPhalaVerifier: `0x468b9D2E9043c80467B610bC290b698ae23adb9B`

## Vaults
- VolatileShort (37d cooldown): `0xbd44547581b92805aAECc40EB2809352b9b2880d`
- VolatileLong (97d cooldown): `0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904`
- StableShort (97d cooldown): `0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC`
- StableLong (372d cooldown): `0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c`

## Shields
- BlackSwanShield (BSS): `0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e` **(DEPRECATED — split into BCS+EAS)**
- BlackSwanShield (BSS, orphaned legacy deploy): `0x2926202bbe3f25f71ef17b25a20ebe8be028af5f` (NEVER registered in CoverRouter; superseded by 0x54CDc21D before launch)
- DepegShield: `0x7578816a803d293bbb4dbea0efbed872842679d0`
- ILIndexCover: `0x2ac0d2a9889a8a4143727a0240de3fed4650dd93`
- ExploitShield: `0x9870830c615d1b9c53dfee4136c4792de395b7a1`
- BTCCatastropheShield (BCS): `0x36e37899D9D89bf367FA66da6e3CebC726Df4ce8` (deployed 2026-04-06, verified on Blockscout)
- ETHApocalypseShield (EAS): `0xA755D134a0b2758E9b397E11E7132a243f672A3D` (deployed 2026-04-06, verified on Blockscout)

## External
- USDC: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- Aave V3 Pool: `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`
- aUSDC (Aave): `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB`
- Protocol Fee Receiver: `0x2b4D825417f568231e809E31B9332ED146760337`

## Keys
- Deployer/Owner: `0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8`
- Oracle Signer: `0x933b15dd4F42bd2EE2794C1D188882aBCCDa977E`
- Relayer: `0xEdA7774A071a8DDa0c8c98037Cb542A1ee6aC7Eb`

## Chainlink Feeds
- ETH/USD: `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` (1200s staleness)
- BTC/USD: `0xCCADC697c55bbB68dc5bCdf8d3CBe83CdD4E071E` (1200s staleness)
- USDC/USD: `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` (86400s staleness)
- USDT/USD: `0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9` (86400s staleness)
- DAI/USD: `0x591e79239a7d679378eC8c847e5038150364C78F` (86400s staleness)

## Implementation Addresses
- CoverRouter impl: `0x4125c61ca25970793cc44350ac414f291d0057fd`
- PolicyManager impl: `0xd55e61c0175696a76d2c494c6e9cc71b9bddb77f`
- VolatileShort impl: `0xce02076988c3b727d4c8063085e86a09e7b64010`
- VolatileLong impl: `0x747f9fe892181cf771ec7f961aaf546d053f1ade`
- StableShort impl: `0x73611a3022dd4ef8f27ff335687ea72d068e5271`
- StableLong impl: `0xd5f252279fef6db364e5089930fd183eba2a6871`

## Deployed
- Date: 2026-03-29
- Network: Base L2 (Chain 8453)
- USDC: Real (Circle)
- Aave: Real (V3)
- Oracle: Multisig-ready (1-of-1, expandable to N-of-M)
- Ownership: TimelockController (48h delay) via Gnosis Safe (2-of-3)

## V2 Oracle Migration (DEPLOYED 2026-04-09)

All V2 contracts are live on Base mainnet. The Safe batch `safe-tx-oracle-v2-via-timelock.json` was executed to swap all 5 productId→shield mappings and set circuit breakers. `safe-tx-coverrouter-set-oracle-v2.json` was executed to point CoverRouter.oracle() to LuminaOracleV2.

- LuminaOracleV2: `0x87B576f688bE0E1d7d23A299f55b475658215105` (owner: TimelockController)
- BTCCatastropheShieldV2: `0x6E0A46B268e4aD9648CdAbD9A4b2B20B79E5ab21`
- ETHApocalypseShieldV2: `0x70f1c92EFcFe55e8d460aAa6d626779536b15128`
- DepegShieldV2: `0x881f683291122c3A72bdD504F71ddCAf47d9AE0e`
- ILIndexCoverV2: `0x01Df7f2953dce5be3afFb72CB9F059f3D3eE9e5a`
- ExploitShieldV2: `0x63D340AE7229BB464bC801f225651341ebcD3693`

Circuit breakers (set via Safe batch):
- maxPayoutsPerDay: 10
- largePayoutThreshold: 50,000 USDC ($50K, 6 decimals = 50000000000)
- largePayoutDelay: 86400 seconds (24h)

V1 shields (DEPRECATED — no longer registered in CoverRouter):
- BTCCatastropheShield V1: `0x36e37899D9D89bf367FA66da6e3CebC726Df4ce8`
- ETHApocalypseShield V1: `0xA755D134a0b2758E9b397E11E7132a243f672A3D`
- DepegShield V1: `0x7578816a803d293bbb4dbea0efbed872842679d0`
- ILIndexCover V1: `0x2ac0d2a9889a8a4143727a0240de3fed4650dd93`
- ExploitShield V1: `0x9870830c615d1b9c53dfee4136c4792de395b7a1`
- LuminaOracle V1: `0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87` (deprecated — replaced by LuminaOracleV2)

Design notes:
- LuminaOracleV2 adds EIP-712 domain-separated proof verification. The domain pins each claim proof to (chainId 8453, the LuminaOracleV2 contract address) preventing cross-chain and cross-contract replay.
- The oracle is NOT upgradeable (Ownable). Replacement requires deploying a new oracle, calling `CoverRouter.setOracle(newOracle)`, AND redeploying every Shield (Shield.oracle is `immutable`).
- LuminaPhalaVerifier is NOT upgradeable (Ownable, admin-curated worker EOA list — not hardware attestation).
- Circuit breakers (`maxPayoutsPerDay`, `largePayoutThreshold`, `largePayoutDelay`) are deployment-time configured and adjustable via Safe batch.
