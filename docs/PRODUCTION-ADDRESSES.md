# Lumina Protocol - Production Addresses (Base L2, Chain 8453)

## Governance
- TimelockController: `0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a`
- Gnosis Safe (2-of-3): `0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD`

## Core
- CoverRouter: `0xd5f8678A0F2149B6342F9014CCe6d743234Ca025`
- PolicyManager: `0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a`
- LuminaOracle: `0xB52BB8B09Df13dB2D244746688C14A720ceE4C09`
- LuminaPhalaVerifier: `0x468b9D2E9043c80467B610bC290b698ae23adb9B`

## Vaults
- VolatileShort (37d cooldown): `0xbd44547581b92805aAECc40EB2809352b9b2880d`
- VolatileLong (97d cooldown): `0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904`
- StableShort (97d cooldown): `0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC`
- StableLong (372d cooldown): `0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c`

## Shields
- BlackSwanShield (BSS): `0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e`
- DepegShield: `0x71DBcE71AA36370f7357F6D8E0c8ba96343C8306`
- ILIndexCover: `0x4196f2Cc92C5c4141a34f9a28f23236446E3C4E0`
- ExploitShield: `0xaE29Fc3e5f0DedC968cE2dA2A2F3ccB98397b38C`

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

## Deployed
- Date: 2026-03-29
- Network: Base L2 (Chain 8453)
- USDC: Real (Circle)
- Aave: Real (V3)
- Oracle: Multisig-ready (1-of-1, expandable to N-of-M)
- Ownership: TimelockController (48h delay) via Gnosis Safe (2-of-3)
