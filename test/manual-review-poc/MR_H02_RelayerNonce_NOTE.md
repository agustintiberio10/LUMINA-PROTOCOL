# MR-H02 — Relayer nonce/serialization gap (integration-level PoC note)

**Finding**: `lumina-api` `purchaseViaRelayer` (`src/services/policies.ts:272-392`) signs from a bare
`new Wallet(cfg.RELAYER_PRIVATE_KEY, provider)` (`src/utils/ethers.ts:50`) with **no** ethers
`NonceManager` and **no** in-process lock — unlike the faucet path, which added a global
`withLock(GLOBAL_LOCK_KEY, …)` (`src/routes/faucet.ts:70-95,114`) to close the same class of race
("audit HIGH-1"). The faucet and purchase paths share **one** relayer wallet / nonce space.

This is an off-chain concurrency defect, so there is no Solidity PoC. Reproduction is integration-level:

## Reproduction (against a local API + Anvil)

1. Start the API pointed at a local node with the relayer funded.
2. Fire N concurrent `POST /api/v1/policies` requests (valid productId/coverage/buyer), each WITHOUT
   an `Idempotency-Key`, within the same tick:

   ```bash
   for i in $(seq 1 8); do
     curl -s -XPOST "$API/api/v1/policies" \
       -H "Authorization: Bearer $KEY" -H "content-type: application/json" \
       -d '{"productId":"0x…","coverageAmount":"100000000","asset":"0x…","buyer":"0x…"}' &
   done; wait
   ```

3. Observe in the relayer/provider logs that two or more `purchasePolicyFor` sends are built with the
   **same** `pending` nonce. One tx replaces the other in the mempool (same nonce) or both stall; the
   losing request returns `tx_reverted`/timeout while, depending on timing, a buyer's premium pull may
   have landed in a tx that is then dropped.

## Expected (after fix)

Wrap the relayer in ethers v6 `NonceManager`, **or** serialize all relayer-signing sends through one
in-process queue using a shared lock key (e.g. `relayer-tx`) across BOTH faucet and purchase, since
they consume one nonce sequence. After the fix, the N concurrent purchases serialize to consecutive
nonces and all succeed (or fail deterministically on-chain), with no dropped premium-charged tx.

**Severity**: HIGH (CVSS 7.1, AV:N/AC:H/PR:L/UI:N/S:U/C:N/I:H/A:H) — DoS on the core revenue path +
potential premium-charged/dropped-tx inconsistency. Not a fund-theft vector (the API never custodies
user funds beyond the premium pull it itself initiates).
