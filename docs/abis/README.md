# Contract ABIs

JSON ABI files for all Lumina Protocol contracts on Base mainnet (chain 8453).

| Contract | Proxy Address | ABI File |
|----------|--------------|----------|
| CoverRouter | 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025 | CoverRouter.json |
| PolicyManager | 0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a | PolicyManager.json |
| BaseVault (4 instances) | VS:0xbd44.../VL:0xFee5.../SS:0x429b.../SL:0x1778... | BaseVault.json |
| BlackSwanShield (deprecated) | 0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e | BlackSwanShield.json |
| DepegShield | 0x7578816a803d293bbb4dbea0efbed872842679d0 | DepegShield.json |
| ILIndexCover | 0x2ac0d2a9889a8a4143727a0240de3fed4650dd93 | ILIndexCover.json |
| ExploitShield | 0x9870830c615d1b9c53dfee4136c4792de395b7a1 | ExploitShield.json |
| LuminaOracle | 0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87 | LuminaOracle.json |
| EmergencyPause | 0xc7ac8c19c3f10f820d7e42f07e6e257bacc22876 | EmergencyPause.json |

## Usage
Import the JSON file in ethers.js/viem/web3.js to interact with the contracts.
