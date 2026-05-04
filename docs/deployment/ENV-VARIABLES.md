# LUMINA Protocol V5.0 -- Environment Variables

> All variables needed for deployment scripts.
> Copy this template into your `.env` file and fill in the values.

---

## Security Warning

> **NEVER commit `.env` to version control.**
> Ensure `.gitignore` includes `.env`, `.env.*`, and `*.env`.
> Use a secrets manager (1Password, Vault, etc.) for production keys.

---

## Variable Reference

```bash
# ======================================================================
# MULTISIG & RECIPIENTS
# ======================================================================

# Gnosis Safe 2-of-3 multisig deployed on Base.
# This address becomes the final owner of all protocol contracts.
# REQUIRED
MULTISIG_OWNER=0x...

# Recipient address for the FounderVesting contract (8M LUMINA).
# Typically an EOA controlled by the founder or a separate multisig.
# REQUIRED
FOUNDER_BENEFICIARY=0x...

# Beneficiary for TreasuryVesting (3M LUMINA).
# Usually the same as MULTISIG_OWNER, but can be a dedicated treasury address.
# REQUIRED
TREASURY_BENEFICIARY=0x...

# Fjord Foundry LBP contract address that will receive 5M LUMINA for the
# Liquidity Bootstrapping Pool event.
# REQUIRED
LBP_DEPOSIT_ADDRESS=0x...

# ======================================================================
# BASE MAINNET ADDRESSES
# ======================================================================

# Native USDC on Base (Circle-issued, NOT bridged).
# This is a well-known address -- verify on Basescan before deploying.
# REQUIRED -- default provided
USDC_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913

# Uniswap V3 SwapRouter02 on Base.
# Used by TWAPBurner for buy-and-burn operations.
# REQUIRED -- default provided
UNISWAP_V3_ROUTER=0x2626664c2603336E57B271c5C0b26F421741e481

# LUMINA/USDC Uniswap V3 pool address.
# Set to address(0) if the pool has not been created yet.
# The CapacityOracle will use emergencyPrice until a pool is available.
# OPTIONAL -- use 0x0000000000000000000000000000000000000000 if not yet created
UNISWAP_V3_POOL=0x...

# ======================================================================
# CHAINLINK ORACLES (BASE)
# ======================================================================
# Price feed addresses on Base mainnet.
# Verify each address on the Chainlink documentation for Base:
# https://docs.chain.link/data-feeds/price-feeds/addresses?network=base

# BTC/USD price feed -- used by FlashBTC shields (1h, 4h, 24h, 48h).
# REQUIRED
CHAINLINK_BTC_USD=0x...

# ETH/USD price feed -- used by FlashETH shields (1h, 24h, 48h).
# REQUIRED
CHAINLINK_ETH_USD=0x...

# USDT/USD price feed -- used by MicroDepeg shield.
# REQUIRED
CHAINLINK_USDT_USD=0x...

# ======================================================================
# AAVE V3 (BASE)
# ======================================================================

# Aave V3 lending pool on Base.
# Used as a READ-ONLY oracle source: RateShockShield reads borrow rate as
# trigger condition; FounderVesting reads borrow rate as Condition C of the
# AltSeason 2-of-3 unlock. Lumina does NOT deposit funds into Aave.
# REQUIRED
AAVE_V3_POOL=0x...

# ======================================================================
# DEPLOYMENT CREDENTIALS
# ======================================================================

# Private key of the deployer EOA.
# This account pays gas for all deployment transactions.
# After deploy, ownership is transferred to MULTISIG_OWNER.
#
# SECURITY:
#   - NEVER commit this value to git.
#   - NEVER share this key.
#   - Use hardware wallet + cast wallet for production deploys if possible.
#   - Fund with ~0.1 ETH on Base (gas is cheap on L2, but budget for 36+ txs).
#
# REQUIRED
DEPLOYER_PRIVATE_KEY=...

# Base mainnet RPC endpoint.
# Use a private RPC (Alchemy, Infura, QuickNode) for reliability.
# Public RPCs may rate-limit during multi-tx deployments.
# REQUIRED
BASE_RPC_URL=...

# Basescan API key for automatic contract verification.
# Obtain from https://basescan.org/myapikey
# REQUIRED for verification; deploy works without it
BASESCAN_API_KEY=...

# ======================================================================
# TESTNET (BASE SEPOLIA)
# ======================================================================
# Used for staging deployments before mainnet.

# Base Sepolia RPC endpoint.
# OPTIONAL -- only needed for testnet deployments
BASE_SEPOLIA_RPC_URL=...
```

---

## Variable Summary Table

| Variable                | Required | Default / Known Value                              | Used By                         |
|-------------------------|----------|----------------------------------------------------|---------------------------------|
| `MULTISIG_OWNER`        | Yes      | --                                                 | All contracts (final owner)     |
| `FOUNDER_BENEFICIARY`   | Yes      | --                                                 | FounderVesting                  |
| `TREASURY_BENEFICIARY`  | Yes      | --                                                 | TreasuryVesting                 |
| `LBP_DEPOSIT_ADDRESS`   | Yes      | --                                                 | LuminaTokenV2 (mint recipient)  |
| `USDC_ADDRESS`          | Yes      | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`       | Multiple contracts              |
| `UNISWAP_V3_ROUTER`    | Yes      | `0x2626664c2603336E57B271c5C0b26F421741e481`       | TWAPBurner                      |
| `UNISWAP_V3_POOL`      | No       | `address(0)`                                       | CapacityOracle                  |
| `CHAINLINK_BTC_USD`     | Yes      | --                                                 | FlashBTC shields, FounderVesting|
| `CHAINLINK_ETH_USD`     | Yes      | --                                                 | FlashETH shields                |
| `CHAINLINK_USDT_USD`    | Yes      | --                                                 | MicroDepeg shield               |
| `AAVE_V3_POOL`          | Yes      | --                                                 | FounderVesting                  |
| `DEPLOYER_PRIVATE_KEY`  | Yes      | --                                                 | Forge scripts                   |
| `BASE_RPC_URL`          | Yes      | --                                                 | Forge scripts                   |
| `BASESCAN_API_KEY`      | Yes*     | --                                                 | Contract verification           |
| `BASE_SEPOLIA_RPC_URL`  | No       | --                                                 | Testnet deploys only            |

*`BASESCAN_API_KEY` is required for contract verification but not for deployment itself.

---

## Security Considerations

1. **Private key handling:** Use `cast wallet` with a hardware wallet for mainnet deploys. If using a raw private key, ensure the `.env` file has strict permissions (`chmod 600 .env` on Unix).

2. **RPC endpoints:** Use authenticated RPC endpoints. Public RPCs may expose your pending transactions to MEV bots or fail under load during multi-transaction deploys.

3. **Git safety:** Verify your `.gitignore` contains:
   ```
   .env
   .env.*
   *.env
   broadcast/
   ```
   The `broadcast/` directory created by Forge contains transaction data including the deployer address.

4. **Post-deploy key rotation:** After ownership transfer to the multisig (Phase 9), the deployer key no longer has protocol authority. However, rotate it anyway -- it may hold residual ETH and its transaction history reveals protocol addresses.

5. **Testnet vs. mainnet:** Use separate `.env` files (e.g., `.env.sepolia`, `.env.base`) and load them explicitly:
   ```bash
   source .env.base && forge script DeployLuminaV5.s.sol ...
   ```
