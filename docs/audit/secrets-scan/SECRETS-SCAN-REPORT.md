# LUMINA V5.0 -- Secrets Scan Report

**Date:** 2026-04-20
**Scope:** Full repository scan for exposed secrets

## Summary

Repository is **CLEAN** for public sharing. No secrets are committed to git.

## Findings

### Critical (exposed secrets in git)
**0 findings.**

### High (potential exposure)
**0 findings.**

### Medium (review needed)
**1 finding:**
- `.env` file exists locally with real secrets (private key, API keys, RPC URL). However, it is NOT tracked by git (`git ls-files .env` returns empty). The `.gitignore` correctly excludes `.env`. **Local-only, not exposed.**

### Low (informational)
- `broadcast/` directory exists locally with old V1 deployment artifacts. NOT tracked by git (in `.gitignore`).
- `archive/v1-vault-model/docs/abis/` contains event topic hashes (64 hex chars) -- these are public ABI data, not secrets.
- Git history contains placeholder references like `DEPLOYER_PRIVATE_KEY=...` and `<secure-key>` -- these are documentation examples, not real keys.

## Scan Details

### Private Keys (0x + 64 hex)
- **In tracked files:** 0 real private keys found
- **In .env (untracked):** 1 private key (`AGENT_PRIVATE_KEY`) -- local only, not in git
- **In git history:** 0 real keys (only placeholders)

### Mnemonics / Seed Phrases
- **Found:** 0

### API Keys
- **In tracked files:** 0 exposed
- **In .env (untracked):** 3 keys (MOLTBOOK, MOLTX, Alchemy RPC) -- local only
- **In foundry.toml:** `${BASESCAN_API_KEY}` uses env var reference (safe)

### Passwords
- **Found:** 0

### Personal Data (emails, phones)
- **Found:** 0

### RPC URLs with embedded tokens
- **In tracked files:** 0
- **In .env (untracked):** 1 Alchemy URL -- local only

### Deployer Wallet Addresses
- **In tracked files:** Only placeholder references in docs (`0x...`)
- **Real addresses:** Not committed

### Multisig Addresses
- **Hardcoded in contracts:** 0 (all loaded from env vars or constructor params)

## Protections in Place

| Protection | Status |
|---|---|
| `.env` in `.gitignore` | YES |
| `.env.local` in `.gitignore` | YES (covered by `.env` pattern) |
| `broadcast/` in `.gitignore` | YES |
| `cache/` in `.gitignore` | YES |
| `out/` in `.gitignore` | YES |
| `.env.example` exists | YES (with placeholders) |
| Secrets in git history | NO (only placeholders) |
| Hardcoded secrets in contracts | NO |
| Real addresses in contracts | NO (loaded from env/constructor) |

## Recommendations

### Immediate
None required -- repository is clean.

### Before Public Repo
1. Add pre-commit hook for secret detection (gitleaks or truffleHog)
2. Rotate `AGENT_PRIVATE_KEY` in local `.env` if it controls any funds
3. Rotate Alchemy API key if the free tier has been exhausted
4. Consider rotating `MOLTBOOK_API_KEY` and `MOLTX_API_KEY`

### Best Practices
1. Never commit `.env` files
2. Use hardware wallets for mainnet deploys
3. Use `cast wallet` instead of raw private keys where possible
4. Rotate API keys periodically
5. Use environment-specific `.env` files (`.env.sepolia`, `.env.mainnet`)

## Verdict

**Repository secrets status: CLEAN**

**Ready for public/open source: YES**

No secrets are committed to git. Local `.env` file is properly gitignored. All contract addresses in source code are either well-known public addresses (USDC, Chainlink, Uniswap) or loaded from environment variables.
