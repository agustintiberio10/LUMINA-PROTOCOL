# UUPS Upgrade Procedure - Lumina Protocol

## Contracts to Upgrade

| Proxy | Address | Fixes Included |
|-------|---------|---------------|
| **CoverRouter** | `0xd5f8678A0F2149B6342F9014CCe6d743234Ca025` | Session approval, coverageAmount>0, cancelPayout releases collateral, DRAIN-8.1 (collateral timing), largePayoutDelay validation |
| **VolatileShort** | `0xbd44547581b92805aAECc40EB2809352b9b2880d` | Performance fee (3% on positive yield) |
| **VolatileLong** | `0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904` | Performance fee |
| **StableShort** | `0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC` | Performance fee |
| **StableLong** | `0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c` | Performance fee |

**NOT upgradeable (no proxy):**
- LuminaOracle (`0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87`) - requires new deploy + Router.setOracle()
- Shields (BSS, Depeg, IL, Exploit) - immutable, require redeploy if changed

## Governance

- **TimelockController:** `0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a` (48h delay)
- **Gnosis Safe (2-of-3):** `0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD`

## Step-by-Step Procedure

### Step 1: Deploy new implementations

```bash
DEPLOYER_PRIVATE_KEY=0x... forge script script/UpgradeProduction.s.sol --rpc-url https://mainnet.base.org --broadcast
```

This deploys 5 new implementation contracts and outputs the upgrade calldata.

### Step 2: Propose upgrades via Gnosis Safe

For EACH proxy that needs upgrading:

1. Go to https://app.safe.global
2. Connect with one of the 3 Safe signers
3. Click "New Transaction" -> "Transaction Builder"
4. Configure the transaction:
   - **To:** TimelockController (`0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a`)
   - **Value:** 0
   - **Function:** `schedule(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt, uint256 delay)`
   - **Parameters:**
     - `target`: proxy address (e.g., `0xd5f8678A...` for CoverRouter)
     - `value`: 0
     - `data`: upgradeToAndCall calldata (output from Step 1)
     - `predecessor`: `0x0000000000000000000000000000000000000000000000000000000000000000`
     - `salt`: unique per upgrade (e.g., `0x0000000000000000000000000000000000000000000000000000000000000001`)
     - `delay`: 172800 (48 hours in seconds)
5. Submit and get second signature (2-of-3 required)

### Step 3: Wait 48 hours

The TimelockController enforces a 48-hour delay. No one can bypass this.

### Step 4: Execute upgrades

After 48 hours, for EACH proxy:

1. Go to Gnosis Safe
2. "New Transaction" -> "Transaction Builder"
3. Configure:
   - **To:** TimelockController
   - **Function:** `execute(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt)`
   - Same parameters as Step 2 (without delay)
4. Submit and get second signature

### Step 5: Verify

```bash
forge script script/VerifyUpgrade.s.sol --rpc-url https://mainnet.base.org
```

Or manually with cast:

```bash
CAST="cast"
RPC="--rpc-url https://mainnet.base.org"

# Check implementation changed (ERC-1967 slot)
$CAST storage 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc $RPC

# Check owner still TimelockController
$CAST call 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025 "owner()" $RPC

# Check new vault features
$CAST call 0xbd44547581b92805aAECc40EB2809352b9b2880d "performanceFeeBps()" $RPC
# Should return 300

# Check totalAssets unchanged
$CAST call 0xbd44547581b92805aAECc40EB2809352b9b2880d "totalAssets()" $RPC
```

## Rollback

If an upgrade fails or corrupts storage:
1. Deploy the PREVIOUS implementation version
2. Propose another upgrade back to the old implementation via TimelockController
3. Wait 48h and execute

UUPS proxies cannot be "unupgraded" instantly - every change requires the 48h delay.

## Storage Safety

All new storage variables were added AFTER existing ones (append-only pattern). No storage slots were reordered. The `__gap` array provides buffer space for future variables.

New storage added:
- **CoverRouter:** `RelayerSession` mapping (after existing `authorizedRelayers`)
- **BaseVault:** `performanceFeeBps`, `feeReceiver`, `userCostBasisPerShare` (after `payoutsPaused`)
