# Oracle V2 — Architecture

## Why V2

The V1 oracle (`archive/v1-deprecated/oracles/LuminaOracleV1.sol`) verifies a
signed claim digest with a single `ecrecover` against a pre-shared signer key.
Two limitations motivated V2:

1. **No domain separation.** A signed proof for chain X / oracle Y could be
   replayed against any other chain/oracle pair that trusted the same signer.
2. **Opaque digest.** Off-chain tooling had to reconstruct an internal hash
   layout; not compatible with hardware wallets or `signTypedData` UX.

V2 (`src/oracles/LuminaOracleV2.sol`) keeps the V1 surface for backward
compatibility (so older shields can call `verifySignature(bytes32, bytes)`)
and adds an EIP-712-typed `verifyPriceProofEIP712(int256, bytes32, uint256, bytes)`
path used by V5.1 shields.

## EIP-712 domain (pinned at deploy time)

```
DOMAIN = {
  name: "LuminaOracle",   // literal in the contract — NOT "LuminaOracleV2"
  version: "2",
  chainId: block.chainid, // captured in constructor — Base mainnet: 8453 (Sepolia sandbox: 84532)
  verifyingContract: address(this),
}
```

The off-chain signer (`lumina-api/src/services/oracleSigner.ts`) reproduces
this domain exactly. Mismatching any field (name, version, chainId,
verifyingContract) yields a different `DOMAIN_SEPARATOR`, which causes
`verifyPriceProofEIP712` to recover the wrong signer and revert with
`InvalidSignature`. This gives us the cross-chain and cross-deployment
replay protection V1 lacked.

## PriceProof typed-data

```
PriceProof {
  int256  price        // signed feed answer (no decimals scaling)
  bytes32 asset        // e.g. ethers.encodeBytes32String("BTC")
  uint256 verifiedAt   // unix seconds at which the API observed the feed
}
```

The shield calls `IOracleV2(oracle).verifyPriceProofEIP712(price, asset, verifiedAt, signature)`
inside `_doVerifyAndCalculate(...)`; the returned signer is matched against
`oracleKey()` (the trusted off-chain signer's address).

## Off-chain flow (lumina-api)

```
agent ──POST /api/v1/oracle/sign-proof { asset } ──▶ lumina-api
                                                     ├─ getCurrentPrice(asset)   ← Chainlink AggregatorV3
                                                     ├─ verifiedAt = now()
                                                     └─ signTypedData(DOMAIN, TYPES, proof)
                                                     ◀─ { price, asset, verifiedAt, signature }
agent ──shield.verifyAndCalculate(policyId, oracleProof) ──▶ chain
                                                     └─ IOracleV2.verifyPriceProofEIP712(...)
                                                        └─ ecrecover(EIP-712 digest, sig) == oracleKey()
```

Encoding of `oracleProof` is `abi.encode(price, asset, verifiedAt, signature)`,
matching the destructuring inside `BaseShield._doVerifyAndCalculate`.

## Deployments

### Base mainnet (8453) — LIVE

> 🟢 Production. Deployed 2026-05-28 via `script/deploy/DeployLuminaV5Mainnet.s.sol`
> (PR #187 / ADR-027). All 6 Phase C Flash shields are bound to this oracle via
> the FlashShieldAdapter UUPS proxies registered on PolicyManagerV2. The
> DOMAIN_SEPARATOR is pinned to chainId 8453 + this oracle address, so a Sepolia
> proof can never be replayed against mainnet.

- **Oracle (LuminaOracleV2)**: `0x191Be3f976CC7471aE2cc4001e92611BA0De1bef`
- **Signer (off-chain key, EOA)**: `0xA0963323D6FA2b721E4D5bf7001C82B460f41456` — the
  address whose private key sits in `lumina-api`'s `ORACLE_PRIVATE_KEY` env (Railway
  service). Rotation requires `setOracleKey(newKey)` from the MULTISIG (Safe).
- **Sequencer uptime feed (Chainlink Base mainnet)**:
  `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` — passed to the oracle constructor;
  shields read it to fail-silent during L2 sequencer outages.
- **Owner**: MULTISIG `0xa9aE612fD97f5e33B5829d16B6408ebD8422C783` (Gnosis Safe).
- **Chainlink data feeds** wired into each shield at Phase C deploy:
  - BTC/USD: `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F`
  - ETH/USD: `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70`
- **Mainnet runbook**: `docs/runbooks/DEPLOY-MAINNET-RUNBOOK.md`. The full deploy +
  Phase C + handoff lives in the audited atomic wrapper; see ADR-027 for the
  inheritance pattern that prevented the original `new Complete() + .run()` bug.

### Base Sepolia (84532) — Legacy testnet (for reference)

> ⚠️ Sepolia is the **sandbox** for `lumina-api`'s `/sandbox/*` endpoints. The
> protocol's production state lives on Base mainnet (above). Addresses below are
> historical / informational only; do NOT integrate against them for production
> flows.

- Oracle: `0x0000000000000000000000000000000000000000` <!-- SPRINT_Z2: was 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194 (Oracle SET A), retired Sprint Z.2 cleanup -->
- Signer (off-chain key): `0x0622340c847bBd8028700b3345021DbD1849a885` — sandbox-only.
- Sequencer uptime feed: `address(0)` — Base Sepolia has no sequencer feed.
- Owner: `0x0000000000000000000000000000000000000000`.
- Historical context: Sprint T-30c V5.3 deploy bound 9 shields on Sepolia; later
  retired down to 6 (Flash BTC/ETH × 1h/24h/48h) before mainnet launch.

## Security implications

1. **Single signer key.** The current oracle accepts only one signer
   (`oracleKey_`). Compromise of `ORACLE_PRIVATE_KEY` lets an attacker craft
   payouts at will. Mitigated by:
   - Owner-only rotation on the oracle (`rotateOracleKey`-equivalent path
     pre-existing in V2).
   - Owner-only `setOracle(newOracle)` on each shield (added in this PR) so
     a compromised oracle can be replaced without redeploying shields.
2. **Replay protection.** EIP-712 chainId+verifyingContract pinning prevents
   cross-chain and cross-oracle replay. Within a single oracle, replay of
   the same `(price, asset, verifiedAt)` tuple is bounded by the shield's
   `MAX_PROOF_AGE` window (per memory: 86,400 s after fix M-8 instead of
   the original 900 s).
3. **Mock fallback on Sepolia.** The Chainlink feeds wired in
   `chainlinkPrices.ts` are pointed at the V5.1 `MockBTCOracle` /
   `MockETHOracle` addresses for testnet only. Mainnet must repoint to
   real Chainlink Base mainnet feeds — see roadmap.

## Sprint timeline (this branch)

- 2026-05-05: deploy LuminaOracleV2 on Base Sepolia, UUPS-upgrade 9
  V5.1 shields to add `setOracle(...)`, rebind all 9 to the new oracle.
- Tracked in `ops/oracle-v2-and-shield-rebind` (LUMINA-PROTOCOL) and
  `feat/oracle-signer-service` (lumina-api).

## Mainnet roadmap — DONE (2026-05-28)

All checklist items below were completed in the mainnet deploy. Kept for
historical reference of what each step required.

- [x] Rotate the deployer key. Done — production deployer is
      `0x130377f9dE9f0134Fa82e24273C0225fB23B9040`, the pre-mainnet keys
      were burned.
- [x] Generate fresh `ORACLE_PRIVATE_KEY` whose address became `oracleKey_`
      at constructor — current mainnet signer EOA:
      `0xA0963323D6FA2b721E4D5bf7001C82B460f41456`.
- [x] Deploy `LuminaOracleV2` on Base mainnet (chainId 8453): live at
      `0x191Be3f976CC7471aE2cc4001e92611BA0De1bef`. DOMAIN_SEPARATOR is
      distinct from any Sepolia oracle's by construction (different
      chainId + verifyingContract).
- [x] Repoint `BTC_PRICE_FEED` / `ETH_PRICE_FEED` to real Chainlink Base
      mainnet feeds — see "Base mainnet (8453) — LIVE" above for the
      exact addresses.
- [x] Sequencer-uptime feed: passed Chainlink Base mainnet feed
      `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` to the constructor.
- [x] Bind shields: 6 FlashShieldAdapter UUPS proxies register the oracle
      via Phase C in the wrapper. See `script/deploy/DeployPhaseC.s.sol`
      and ADR-027.
