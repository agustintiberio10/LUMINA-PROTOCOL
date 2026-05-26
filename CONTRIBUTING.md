# Contributing to LUMINA Protocol

Thanks for your interest in LUMINA. This guide covers local setup, the test
workflow, and how to propose changes.

> **Security issues are NOT handled here.** Do not open public issues/PRs for
> vulnerabilities — follow [`SECURITY.md`](./SECURITY.md) and email
> `security@lumina-org.com`.

## Repository layout

- `src/` — Solidity sources (`core/`, `bonds/`, `shields/`, `products/`,
  `oracles/`, `marketplace/`, `token/`, `treasury/`, `automation/`).
- `test/` — Foundry tests (`*.t.sol`), invariant/fuzz suites, Echidna configs.
- `script/` — deploy & ops scripts.
- `audit-pack/` — audit reports, sprint logs, ADRs, runbooks, deployed manifests.
- `docs/` — protocol documentation (the public docs site is a separate repo).

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) (`forge`/`cast`) — pinned in CI.
- A Base Sepolia RPC URL (chainId 84532) for fork tests / scripts.

## Local development

```bash
forge install          # fetch dependencies
forge build            # compile (uses via_ir; see foundry.toml)
forge fmt --check      # formatting gate (CI enforces this)
```

### Running tests

The full suite is large. On constrained machines, prefer scoping by path:

```bash
forge test --match-path "test/bonds/*"        # one folder
forge test --match-contract BondVaultTest     # one contract
FOUNDRY_OPTIMIZER_RUNS=1 forge test           # lower-memory build
```

> **Known environment caveat:** on some Windows setups a full `forge test` can
> hang; chunk by `--match-path`. When using `vm.warp`, capture a base timestamp
> (`t0`) and warp relative to it rather than `block.timestamp` — `via_ir=true`
> caches `block.timestamp` and breaks naive warps.

Static analysis (also run in CI): Slither, Aderyn, Mythril, Halmos, Echidna —
see `.github/workflows/`.

## Proposing changes

1. Branch from `main` using a descriptive name: `feat/...`, `fix/...`, `docs/...`.
2. Keep PRs focused; match the surrounding code style (CI runs `forge fmt --check`).
3. Add/adjust tests for any behavioral change. New behavior without tests will
   not be merged.
4. For storage-layout changes on upgradeable contracts, preserve append-only
   layout and note it in the PR (UUPS).
5. Open a **draft PR**; describe what changed, why, and how you verified it
   (paste relevant `forge test` output).
6. Reference any related ADR in `audit-pack/adrs/` for architectural changes.

## Commit / PR conventions

- Conventional-commit prefixes (`feat:`, `fix:`, `test:`, `docs:`, `chore:`).
- One logical change per PR where practical.
- Do not bypass CI hooks or signing.

## Code of conduct

Be respectful and constructive. Maintainers may close PRs/issues that are
off-topic, spam, or violate the security policy.
