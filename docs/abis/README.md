# Contract ABIs

JSON ABI files for all Lumina Protocol contracts on Base mainnet (chain 8453).

## V2 Contracts (active — production)

| Contract | Address | ABI File |
|----------|---------|----------|
| CoverRouter | 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025 | CoverRouter.json |
| PolicyManager | 0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a | PolicyManager.json |
| BaseVault (4 instances) | VS:0xbd44.../VL:0xFee5.../SS:0x429b.../SL:0x1778... | BaseVault.json |
| LuminaOracleV2 | 0x87B576f688bE0E1d7d23A299f55b475658215105 | LuminaOracleV2.json |
| BTCCatastropheShieldV2 | 0x6E0A46B268e4aD9648CdAbD9A4b2B20B79E5ab21 | BTCCatastropheShieldV2.json |
| ETHApocalypseShieldV2 | 0x70f1c92EFcFe55e8d460aAa6d626779536b15128 | ETHApocalypseShieldV2.json |
| DepegShieldV2 | 0x881f683291122c3A72bdD504F71ddCAf47d9AE0e | DepegShieldV2.json |
| ILIndexCoverV2 | 0x01Df7f2953dce5be3afFb72CB9F059f3D3eE9e5a | ILIndexCoverV2.json |
| ExploitShieldV2 | 0x63D340AE7229BB464bC801f225651341ebcD3693 | ExploitShieldV2.json |
| EmergencyPause | 0xc7ac8c19c3f10f820d7e42f07e6e257bacc22876 | EmergencyPause.json |

## V1 Contracts (deprecated — in deprecated/ folder)

| Contract | Address | ABI File | Status |
|----------|---------|----------|--------|
| BlackSwanShield | 0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e | deprecated/BlackSwanShield.json | Replaced by BCS+EAS |
| LuminaOracle | 0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87 | deprecated/LuminaOracle.json | Replaced by LuminaOracleV2 |

V1 shield ABIs (DepegShield, ILIndexCover, ExploitShield) remain in the main folder
as the V2 ABIs are backward-compatible upgrades with the same core interface.

## Usage
Import the JSON file in ethers.js/viem/web3.js to interact with the contracts.
