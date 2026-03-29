# Multisig Oracle — Signer Registry

## Signer Table (addresses only — NEVER store private keys here)

| # | Role | Address | Location |
|---|------|---------|----------|
| 1 | Primary (Railway) | *See Railway env `ORACLE_PRIVATE_KEY`* | Railway — MOLTAGENTINSURANCE project |
| 2 | GCP | `0x9F95c55CE9613D855E255d11f9B68F664a5A573b` | Google Cloud Run — `ORACLE_SIGNER_2_KEY` env var |
| 3 | Backup (Offline) | `0x063637E9331c5977C789040f35b40a6bEF669f83` | Offline storage (password manager / encrypted file) |
| 4 | Reserved | — | Not yet generated |
| 5 | Reserved | — | Not yet generated |

## Configuration

- **Current mode:** 1-of-1 (single signer, backwards compatible)
- **Target mode:** 3-of-3 (activate when all signers are deployed and tested)
- **Max capacity:** 5 signers (can add 2 more later for 3-of-5)

## Contract Functions

```solidity
// Add signers (onlyOwner)
addSigner(address signer)

// Set quorum (onlyOwner)
setRequiredSignatures(uint256 required)

// Query
getSignerInfo() → (uint256 required, uint256 total)
isSigner(address addr) → bool
authorizedSigners(address) → bool
```

## Registration Steps (when ready to activate)

```bash
# Step 1: Add Signer 2
cast send ORACLE_CONTRACT_ADDRESS "addSigner(address)" 0x9F95c55CE9613D855E255d11f9B68F664a5A573b \
  --rpc-url https://mainnet.base.org --private-key OWNER_PRIVATE_KEY

# Step 2: Add Signer 3
cast send ORACLE_CONTRACT_ADDRESS "addSigner(address)" 0x063637E9331c5977C789040f35b40a6bEF669f83 \
  --rpc-url https://mainnet.base.org --private-key OWNER_PRIVATE_KEY

# Step 3: Activate multisig (3-of-3)
cast send ORACLE_CONTRACT_ADDRESS "setRequiredSignatures(uint256)" 3 \
  --rpc-url https://mainnet.base.org --private-key OWNER_PRIVATE_KEY

# Step 4: Verify
cast call ORACLE_CONTRACT_ADDRESS "totalSigners()" --rpc-url https://mainnet.base.org
cast call ORACLE_CONTRACT_ADDRESS "requiredSignatures()" --rpc-url https://mainnet.base.org
cast call ORACLE_CONTRACT_ADDRESS "isSigner(address)" 0x9F95c55CE9613D855E255d11f9B68F664a5A573b --rpc-url https://mainnet.base.org
cast call ORACLE_CONTRACT_ADDRESS "isSigner(address)" 0x063637E9331c5977C789040f35b40a6bEF669f83 --rpc-url https://mainnet.base.org
```

Replace `ORACLE_CONTRACT_ADDRESS` and `OWNER_PRIVATE_KEY` with actual values.

## Security Notes

- Private keys are NEVER stored in this file or any git-tracked file
- Signer 1 key lives in Railway environment variables
- Signer 2 key lives in Google Cloud Run environment variables
- Signer 3 key is stored offline only (password manager or encrypted file)
- Registration on-chain is a separate step — do NOT activate until all signers are tested
