# Key Rotation Plan — Lumina Protocol

## Current State (INSECURE — must fix before production)

All three roles use the SAME private key. This must be separated.

| Role | Current Key | Where Stored | Risk |
|------|------------|--------------|------|
| Deployer/Owner | 0x2b4D...0337 | .env (local) | Controls upgrades, admin functions |
| Oracle Signer | Same as deployer | Railway env `ORACLE_PRIVATE_KEY` | Signs quotes and claim proofs |
| API Relayer | Same as deployer | Railway env (fallback from ORACLE_PRIVATE_KEY) | Sends transactions, pays gas |

## Target State

| Role | Key | Where Stored |
|------|-----|--------------|
| Deployer/Owner | New key → Gnosis Safe multisig | Hardware wallet / cold storage |
| Oracle Signer 1 | Dedicated key | Railway env `ORACLE_PRIVATE_KEY` |
| Oracle Signer 2 | Dedicated key | GCP env `ORACLE_SIGNER_2_KEY` |
| Oracle Signer 3 | Dedicated key | Offline backup |
| API Relayer | Dedicated key (low balance, gas only) | Railway env `RELAYER_PRIVATE_KEY` |

## Rotation Steps

### Step 1: Generate new keys
```bash
cast wallet new  # Relayer
cast wallet new  # Oracle Signer (new, dedicated)
```

### Step 2: Fund relayer
Transfer small amount of ETH (0.01) to new relayer address for gas.

### Step 3: Update Railway env vars
- `RELAYER_PRIVATE_KEY` = new relayer key
- `ORACLE_PRIVATE_KEY` = new oracle signer key
- Remove old key

### Step 4: Update on-chain (oracle key rotation)
```bash
cast send ORACLE_ADDRESS "setOracleKey(address)" NEW_ORACLE_ADDRESS --rpc-url https://mainnet.base.org --private-key OWNER_KEY
```

### Step 5: Transfer contract ownership to Gnosis Safe
```bash
cast send CONTRACT_ADDRESS "transferOwnership(address)" GNOSIS_SAFE_ADDRESS --rpc-url https://mainnet.base.org --private-key OWNER_KEY
```

### Step 6: Verify old key has no remaining privileges
```bash
cast call CONTRACT_ADDRESS "owner()" --rpc-url https://mainnet.base.org
# Should return Gnosis Safe address, NOT old deployer
```

## Timeline
- [ ] Generate keys
- [ ] Fund relayer
- [ ] Update Railway
- [ ] Rotate oracle key on-chain
- [ ] Transfer ownership
- [ ] Verify
