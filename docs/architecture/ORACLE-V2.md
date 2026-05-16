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
  chainId: block.chainid, // captured in constructor — Base Sepolia: 84532
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

### Base Sepolia (84532)

> ⚠️ OBSOLETO — La dirección Oracle SET A citada abajo fue invalidada por el bug L476-477
> (multisig grant+revoke) que bricked LuminaTokenV2 0x7D3E…Aff02. Direcciones se reemplazarán
> en el redeploy post-Sprint Z.2. Sección conservada como registro histórico.

- Oracle: `0x0000000000000000000000000000000000000000` <!-- SPRINT_Z2: was 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194 (Oracle SET A) -->
- Signer (off-chain key): `0x0622340c847bBd8028700b3345021DbD1849a885` — the
  address whose private key sits in `lumina-api`'s `ORACLE_PRIVATE_KEY` env.
- Sequencer uptime feed: `address(0)` — Base Sepolia has no sequencer feed.
- Owner: `0x0000000000000000000000000000000000000000` <!-- SPRINT_Z2: cleared pre-redeploy -->
- All 9 V5.1 shields rebound on the same deploy; manifest file
  `deployments/sepolia/shields-upgrade-2026-05-05.json` is no longer authoritative
  (Sprint Z.2 cleanup).

### Base mainnet (8453)

Not deployed yet. See "Mainnet roadmap" below.

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

## Mainnet roadmap

- [ ] Rotate the deployer key (the current one is tainted from this session
      because it was passed to a non-ops process).
- [ ] Generate fresh `ORACLE_PRIVATE_KEY` from an HSM. Its address feeds the
      `oracleKey_` constructor argument of the mainnet oracle.
- [ ] Re-deploy `LuminaOracleV2` on Base mainnet (chainId 8453) with the
      fresh keys. The DOMAIN_SEPARATOR will be different from Sepolia's by
      construction, so no cross-network replay risk.
- [ ] Repoint `BTC_PRICE_FEED` / `ETH_PRICE_FEED` to real Chainlink Base
      mainnet feeds. Validate `latestRoundData()` returns sensible answers
      and `decimals()` matches the price unit shields expect.
- [ ] If a sequencer-uptime feed is required for sequencer-aware shields
      on Base mainnet, pass its address to the constructor; on Base Sepolia
      we deploy with `address(0)` because no such feed exists on testnet.
- [ ] Run UUPS upgrade + `setOracle(mainnetOracle)` against the 9 mainnet
      shields once they exist.
