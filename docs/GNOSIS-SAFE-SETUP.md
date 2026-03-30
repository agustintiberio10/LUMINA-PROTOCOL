# Gnosis Safe Setup — Lumina Protocol

## What It Is
Gnosis Safe is a multisig wallet. Instead of one private key controlling the contracts, it requires N-of-M signatures to execute any action.

## Recommended Configuration
- **Signers:** 3
  - Signer 1: Deployer key — `0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8`
  - Signer 2: Oracle/GCP key — `0x933b15dd4F42bd2EE2794C1D188882aBCCDa977E`
  - Signer 3: Backup key (offline) — see docs/MULTISIG-KEYS.md
- **Threshold:** 2-of-3

## Steps

### Step 1: Create the Safe
1. Go to https://app.safe.global
2. Click "Create new Safe"
3. Select network: **Base**
4. Name: "Lumina Protocol Admin"
5. Add the 3 signers (addresses only, NOT private keys):
   - Signer 1: `0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8`
   - Signer 2: `0x933b15dd4F42bd2EE2794C1D188882aBCCDa977E`
   - Signer 3: (backup address from MULTISIG-KEYS.md)
6. Threshold: **2 of 3**
7. Click "Create" — sign with any of the 3 wallets
8. Copy the Safe address

### Step 2: Verify
- The Safe appears on app.safe.global
- It has 3 owners
- Threshold is 2-of-3
- It's on Base network (chain 8453)

### Step 3: Save the Address
- The Safe address is used as `GNOSIS_SAFE_ADDRESS` in the TimelockController deploy
- Save it in docs/PRODUCTION-ADDRESSES.md

## How It Works After Setup

1. To make any admin change (upgrade, pause, change oracle):
   - One signer proposes the action in Safe
   - Another signer confirms (2-of-3)
   - Safe sends the transaction to TimelockController
   - Waits 48 hours
   - After 48h, any signer executes from Safe
2. This gives 48 hours for the community/LPs to react if there's a malicious change

## Architecture

```
Gnosis Safe (2-of-3)
    |
    v
TimelockController (48h delay)
    |
    v
CoverRouter / PolicyManager / Vaults / Shields / Oracle
```

No single person can make instant changes. Every admin action requires 2 signatures + 48h waiting period.
