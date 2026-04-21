# LUMINA Protocol V5.0 -- Real Testnet Testing Guide

## Network: Base Sepolia (Chain ID: 84532)

---

## Prerequisites

1. **Base Sepolia ETH** in your wallet (for gas)
   - Get from: https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet
   - Or: https://faucet.quicknode.com/base/sepolia

2. **MockUSDC balance** -- the script auto-mints if needed, but you can also mint manually:
   ```bash
   cast send 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a \
     "mint(address,uint256)" YOUR_ADDRESS 1000000000000 \
     --rpc-url base-sepolia --private-key $PRIVATE_KEY
   ```

3. **Environment setup**:
   ```bash
   export PRIVATE_KEY=0xYourPrivateKeyHere
   export RPC_URL=https://sepolia.base.org  # or your Alchemy/Infura endpoint
   ```

4. **Foundry installed** (forge, cast):
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

---

## Deployed Contracts (Base Sepolia)

| Contract | Address |
|---|---|
| CoverRouterV2 | `0x71DBcE71AA36370f7357F6D8E0c8ba96343C8306` |
| MockUSDC | `0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a` |
| ClaimBond | `0xd5f8678A0F2149B6342F9014CCe6d743234Ca025` |
| MockBTCOracle | `0xB52BB8B09Df13dB2D244746688C14A720ceE4C09` |
| FlashBTCShield1h | `0xDcac6614E6d8CAB79bD655649B5cfdA497f80aeD` |
| PolicyManagerV2 | `0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e` |
| BondVault | `0x8b4B1E1985e105bb0b50A02F7d1AcD3efc950673` |
| MockShieldOracle | `0xF11DDa1e81eC766c98B673dFA7e26c75C9a1e453` |

---

## Step 1: Buy a Policy

```bash
forge script script/testnet-tests/01_BuyPolicy.s.sol \
  --rpc-url base-sepolia \
  --broadcast
```

**What it does:**
- Checks your MockUSDC balance (auto-mints if needed)
- Approves CoverRouterV2 to spend MockUSDC
- Calls `purchasePolicy(FLASHBTC1H-001, 1000e6, "BTC")`
- Logs the **Policy ID**

**Expected output:**
```
=== LUMINA Testnet: Buy FlashBTC1H Policy ===
Buyer:            0xYourAddress
Coverage (raw):   1000000000
Coverage (USD):   $1000
[1/2] Approved CoverRouter for mUSDC
[2/2] Policy purchased!
========================================
  POLICY ID:  1
========================================
```

**Save the policy ID:**
```bash
export POLICY_ID=1
```

**Optional:** Override coverage amount:
```bash
COVERAGE_AMOUNT=5000000000 forge script script/testnet-tests/01_BuyPolicy.s.sol \
  --rpc-url base-sepolia --broadcast
```

---

## Step 2: Simulate BTC Crash (Manipulate Oracle)

> **NOTE:** The deployed MockShieldOracle must have a `setPrice(bytes32,int256)` function.
> If it was deployed without one, you need to redeploy the mock with this function added,
> or use `cast send` with the storage slot directly.

```bash
forge script script/testnet-tests/02_TriggerPolicy.s.sol \
  --rpc-url base-sepolia \
  --broadcast
```

**What it does:**
- Reads current BTC price from MockShieldOracle
- Sets BTC price to $30,000 (>50% crash from $65K default)
- Updates BOTH key formats (`keccak256("BTC")` and `"BTC"`)

**Expected output:**
```
=== LUMINA Testnet: Trigger BTC Crash ===
Current price (keccak key): 6500000000000
Current price (direct key): 6500000000000
Setting crash price:        3000000000000
Drop percentage:            53%
[1/2] Set price for keccak256('BTC') key
[2/2] Set price for direct 'BTC' key
========================================
  BTC PRICE CRASHED TO: $30000
========================================
```

**To restore price after testing:**
```bash
CRASH_PRICE=6500000000000 forge script script/testnet-tests/02_TriggerPolicy.s.sol \
  --rpc-url base-sepolia --broadcast
```

---

## Step 3: Settle the Policy

> **IMPORTANT: 25-HOUR WAIT TIME**
>
> `checkAndSettlePolicy` requires:
> - 1 hour of coverage to expire
> - 24 hours of SAFETY_WINDOW to pass
> - Total: **25 hours minimum** from policy creation
>
> The transaction WILL REVERT with `SafetyWindowNotPassed` if called too early.

### Option A: Wait 25 hours (real testnet)

```bash
POLICY_ID=1 forge script script/testnet-tests/03_SettlePolicy.s.sol \
  --rpc-url base-sepolia \
  --broadcast
```

### Option B: Test immediately on a local fork

```bash
# Fork Base Sepolia and warp time forward
POLICY_ID=1 forge script script/testnet-tests/03_SettlePolicy.s.sol \
  --fork-url base-sepolia
```

> Note: On a local fork, Foundry's `vm.warp()` can be used in a custom test
> to advance time. The script itself does not warp time automatically.

**Expected output (success):**
```
=== LUMINA Testnet: Settle Policy ===
Policy ID:   1
--- Policy Details ---
Insured:         0xYourAddress
Coverage:        1000000000
Max Payout:      800000000
Status:          ACTIVE
Attempting checkAndSettlePolicy...
========================================
  SETTLEMENT COMPLETE
  New Status: PAID_OUT
  >> TRIGGERED: Payout bonds minted!
  >> Check ClaimBond balance with 04_VerifyNFT.s.sol
========================================
```

---

## Step 4: Verify ClaimBond NFT

```bash
HOLDER=0xYourAddress EPOCH_ID=202604 \
  forge script script/testnet-tests/04_VerifyNFT.s.sol \
  --rpc-url base-sepolia
```

> **No gas needed** -- this is a view-only script (no broadcast).

**What it does:**
- Queries `ClaimBond.balanceOf(holder, epochId)`
- Shows bond balance and USD value
- Prints instructions for MetaMask and BaseScan

**Expected output:**
```
=== LUMINA Testnet: Verify ClaimBond NFT ===
ClaimBond:    0xd5f8678A0F2149B6342F9014CCe6d743234Ca025
Holder:       0xYourAddress
Epoch ID:     202604
Epoch exists: true
Maturity:     1746057600
========================================
  BOND BALANCE: 800 tokens
  USD VALUE:    $800
========================================
```

**Epoch ID format:** `YYYYMM` (e.g., `202604` = April 2026). If unsure of epoch, try the current month.

---

## How to See NFT in MetaMask

1. Open MetaMask
2. Switch network to **Base Sepolia** (Chain ID: 84532)
3. Go to the **NFTs** tab
4. Click **Import NFT**
5. Enter:
   - **Contract Address:** `0xd5f8678A0F2149B6342F9014CCe6d743234Ca025`
   - **Token ID:** Your epoch ID (e.g., `202604`)
6. Click **Import**

MetaMask will show the ERC-1155 ClaimBond token. Each token represents $1 USD of claim at maturity.

---

## How to See NFT on BaseScan

**Contract page:**
```
https://sepolia.basescan.org/address/0xd5f8678A0F2149B6342F9014CCe6d743234Ca025
```

**Your token holdings:**
```
https://sepolia.basescan.org/token/0xd5f8678A0F2149B6342F9014CCe6d743234Ca025?a=YOUR_ADDRESS
```

**Specific token ID:**
```
https://sepolia.basescan.org/token/0xd5f8678A0F2149B6342F9014CCe6d743234Ca025?a=YOUR_ADDRESS#inventory
```

---

## Timeline Summary

```
T+0h        Buy policy (Step 1)
T+0h        Crash oracle price (Step 2)
T+1h        Coverage period ends
T+25h       Safety window passes -- settlement unlocked
T+25h+      Settle policy (Step 3)
T+25h+      Verify NFT bonds (Step 4)
```

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `SafetyWindowNotPassed` | Called Step 3 before 25h | Wait or use local fork |
| `Protocol auto-paused` | LUMINA price below threshold | CapacityOracle needs price update |
| `CoverageOutOfRange` | Coverage < $100 | Use at least `100000000` (100e6) |
| `DurationOutOfRange` | Wrong product | FlashBTC1H is fixed 1h duration |
| `Only BondVault` | Direct mint attempt | Bonds are auto-minted on trigger |
| `revert (no data)` on Step 2 | Mock has no `setPrice()` | Redeploy mock with setter function |

---

## Using `cast` for Quick Reads

```bash
# Check policy status
cast call 0xDcac6614E6d8CAB79bD655649B5cfdA497f80aeD \
  "getPolicyStatus(uint256)(uint8)" 1 --rpc-url base-sepolia

# Check bond balance
cast call 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025 \
  "balanceOf(address,uint256)(uint256)" YOUR_ADDRESS 202604 --rpc-url base-sepolia

# Check oracle price
cast call 0xF11DDa1e81eC766c98B673dFA7e26c75C9a1e453 \
  "getLatestPrice(bytes32)(int256)" $(cast --format-bytes32 "BTC") --rpc-url base-sepolia
```
