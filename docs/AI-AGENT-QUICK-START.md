# Lumina Protocol — AI Agent Integration Guide (Quick Start)

This is the minimum-viable path for an AI agent to discover, quote, purchase,
inspect, and (eventually) claim a Lumina insurance policy on Base mainnet.

**Network:** Base (chain id `8453`)
**API base:** `https://lumina-protocol-production.up.railway.app`
**Settlement token:** USDC at `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (6 decimals)

> **Operational status (2026-04-08):** All 5 products (BCS `BTCCAT-001`,
> EAS `ETHAPOC-001`, DEPEG `DEPEG-STABLE-001`, IL `ILPROT-001`, EXPLOIT
> `EXPLOIT-001`) are registered and ACTIVE in the on-chain CoverRouter.
> BSS (`BLACKSWAN-001`) is deprecated and `/quote` will reject it with
> the deprecated message. Vaults are still being seeded with USDC, so
> `/quote` may return `VAULT_EMPTY` for any product until liquidity is
> deposited — that is the expected response, not an error in the API.

---

## 1. Discover available products

```http
GET /api/v2/products
```

Response (truncated):

```json
{
  "products": [
    {
      "id": "BTCCAT-001",
      "name": "BTC Catastrophe Shield",
      "productId": "0x26933c71...",
      "shield":   "0x36e37899D9D89bf367FA66da6e3CebC726Df4ce8",
      "vaults":   ["0xbd445475...", "0xFee5d6DA..."],
      "pBase": 1500,
      "minDuration": 604800,
      "maxDuration": 2592000,
      "status": "ACTIVE",
      "registeredOnChain": true
    }
  ]
}
```

The fields you must check before quoting:

- `status === "ACTIVE"` — product is open for new policies.
- `registeredOnChain === true` — quotes will succeed.
- `status === "PENDING_REGISTRATION"` — shield exists but governance has not
  registered it in CoverRouter yet. Skip this product for now.
- `status === "DEPRECATED"` — never quote this product. The error response
  will tell you which product replaces it (e.g. BSS → BCS or EAS).

---

## 2. Get a signed quote

```http
POST /api/v2/quote
Content-Type: application/json

{
  "productId":      "BTCCAT-001",
  "coverageAmount": "10000000000",
  "durationSeconds": 2592000,
  "asset":          "BTC",
  "buyer":          "0xYOUR_AGENT_WALLET"
}
```

Field reference:

| Field            | Type        | Notes                                                                  |
|------------------|-------------|------------------------------------------------------------------------|
| `productId`      | string      | Full ID (`BTCCAT-001`/`ETHAPOC-001`/...) or short alias (`BCS`/`EAS`). |
| `coverageAmount` | uint256 str | USDC 6-decimals. Minimum $100 (`100000000`). Pass as a JSON string.    |
| `durationSeconds`| uint32      | Within the product's `minDuration`/`maxDuration` window.               |
| `asset`          | string      | `"BTC"` for BCS, `"ETH"` for EAS, etc. Sent on-chain as bytes32.       |
| `stablecoin`     | string      | Required for Depeg (`"USDT"` or `"DAI"`).                              |
| `protocol`       | address     | Required for Exploit (target protocol address).                        |
| `buyer`          | address     | The wallet that will own the policy.                                   |

**Successful response (HTTP 200):**

```json
{
  "quote": {
    "productId":     "0x26933c71...",
    "productName":   "BTC Catastrophe Shield",
    "coverageAmount":"10000000000",
    "premiumAmount": "12328767",
    "durationSeconds": 2592000,
    "asset":         "BTC",
    "buyer":         "0xYOUR_AGENT_WALLET",
    "deadline":      1715000000,
    "nonce":         "0x1234...",
    "utilizationAtQuote": 0.0
  },
  "signature":   "0xabcd... (130 hex chars per oracle signer)",
  "signedQuote": { ... }   // mirror of `quote`, serialized with strings for BigInts
}
```

**Error responses (also HTTP 200, with an `error` field — never throw on
HTTP code alone):**

| `error`                  | Meaning                                                          | Action                                                                 |
|--------------------------|------------------------------------------------------------------|------------------------------------------------------------------------|
| `VAULT_EMPTY`            | Vault has zero TVL. Cannot price a policy.                        | Wait for liquidity, or pick a different product.                        |
| `PRODUCT_CAP_EXCEEDED`   | Per-product cap reached for this vault.                           | Lower coverage or wait for capacity.                                    |
| `GROUP_CAP_EXCEEDED`     | Combined BCS+EAS correlation group cap reached on this vault.     | Lower coverage or wait for the other product to expire policies.        |
| `PRODUCT_NOT_REGISTERED` | productId is not in CoverRouter.                                  | Check `/products` for current status; do not retry.                     |
| `Product deprecated...`  | The product is deprecated.                                        | Use the replacement product mentioned in the message.                   |
| `ON_CHAIN_REVERT`        | An RPC read reverted while preparing the quote.                   | Retry once; if persistent, file an issue with the API logs.             |
| `QUOTE_INTERNAL_ERROR`   | Unexpected exception in the API handler.                          | Retry; if persistent, file an issue.                                    |

You **MUST** keep the entire `signature` and `signedQuote` blob and pass them
to `purchasePolicyFor` exactly as received. The signature is EIP-712 over the
quote tuple — re-encoding it on your side will fail verification.

---

## 3. Purchase the policy

You have two options.

### Option A — Submit on-chain yourself (recommended for AI agents)

1. Approve the CoverRouter to pull `premiumAmount` USDC from your wallet:

   ```solidity
   IERC20(USDC).approve(COVER_ROUTER, premiumAmount);
   ```

   `COVER_ROUTER = 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025`

2. Call `purchasePolicyFor` with the quote tuple and the signature:

   ```solidity
   ICoverRouter.QuoteTuple memory q = ICoverRouter.QuoteTuple({
       productId:       <bytes32 from signedQuote.productId>,
       coverageAmount:  <uint256 from signedQuote.coverageAmount>,
       premiumAmount:   <uint256 from signedQuote.premiumAmount>,
       durationSeconds: <uint32  from signedQuote.durationSeconds>,
       asset:           <bytes32 from signedQuote.asset>,
       stablecoin:      <bytes32 from signedQuote.stablecoin>,
       protocol:        <address from signedQuote.protocol>,
       buyer:           <address from signedQuote.buyer>,
       deadline:        <uint256 from signedQuote.deadline>,
       nonce:           <uint256 from signedQuote.nonce>
   });
   ICoverRouter(COVER_ROUTER).purchasePolicyFor(q, signature);
   ```

   Returns:
   ```solidity
   struct PolicyResult {
       uint256 policyId;
       bytes32 productId;
       address vault;
       uint256 coverageAmount;
       uint256 premiumPaid;
       uint256 startsAt;
       uint256 expiresAt;
   }
   ```

   The wallet calling this transaction must equal `signedQuote.buyer`.

### Option B — Use the API relayer (simpler, no gas needed)

```http
POST /api/v2/purchase
Content-Type: application/json
X-API-Key: <key created via /api/v2/keys/create>

{ "productId": "BTCCAT-001", "coverageAmount": 1000000000, "durationSeconds": 1209600 }
```

The API relayer generates its own signed quote internally, pays the gas, and
submits `purchasePolicyFor` for you. You do NOT need to pass the `signedQuote`
or `signature` from `/quote` — the relayer produces a fresh one. You only need
your API key, the product ID, the coverage amount (USDC 6 decimals), and the
duration in seconds.

**Note:** Your wallet must have sufficient USDC balance AND must have approved
the CoverRouter (`0xd5f8678A0F2149B6342F9014CCe6d743234Ca025`) for at least
`premiumAmount` before calling `/purchase`. Check the `/quote` response to see
the exact premium.

---

## 4. Inspect your policies

```http
GET /api/v2/policies?buyer=0xYOUR_AGENT_WALLET
```

Response:

```json
{
  "policies": [
    {
      "policyId": 1,
      "productId": "0x26933c71...",
      "productName": "BTC Catastrophe Shield",
      "shield": "0x36e37899...",
      "coverageAmount": "10000000000",
      "premiumPaid": "12328767",
      "maxPayout": "8000000000",
      "startsAt": 1714000000,
      "expiresAt": 1716592000,
      "status": "ACTIVE"
    }
  ]
}
```

`maxPayout` is `coverage × (1 - deductibleBps/10000)` — i.e. 80% of coverage
for BCS/EAS (20% deductible).

---

## 5. Claim if triggered

For BCS/EAS the trigger is automatic: if the price of the insured asset drops
below `strikePrice × (1 - TRIGGER_DROP_BPS/10000)` and the LuminaOracle TWAP
confirms it (or 3 consecutive Chainlink rounds), anyone — typically a relayer
operated by Lumina — can call `CoverRouter.triggerPayout(productId, policyId, oracleProof)`.

You don't need to do anything yourself, but if you want to monitor:

1. Read the current price from the oracle:

   ```bash
   cast call 0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87 \
     "getLatestPrice(bytes32)(int256)" \
     $(cast --format-bytes32-string "BTC") \
     --rpc-url https://mainnet.base.org
   ```

2. Compare to your policy's strike price (recorded at purchase, see
   `Shield.getPolicyInfo(policyId)`).

3. If the trigger fires, the payout is sent to the buyer wallet within one
   block (minus the 3% protocol fee on the payout). Watch the
   `PayoutTriggered(policyId, productId, recipient, amount)` event on
   `CoverRouter`.

4. Large payouts are queued through the vault `claimPendingPayout()` flow;
   see `BaseVault.claimPendingPayout()`.

---

## Operational notes for autonomous agents

- **Always handle the `error` field on a 200 response.** The fixed
  `/api/v2/quote` returns descriptive error codes with HTTP 200 — relying on
  HTTP status alone will treat structured errors as success.
- **Never re-sign quotes locally.** The signature is an EIP-712 attestation
  by the LuminaOracle multisig. Pass it through unchanged.
- **Quote `deadline` is `now + 5 minutes`.** If you cannot submit the
  purchase within that window, fetch a new quote.
- **Stick to ACTIVE products.** Filter `/products` for `status === "ACTIVE"
  && registeredOnChain === true` before quoting.
- **Watch the correlation group.** BCS and EAS share a 40% combined cap
  per vault. If the API returns `GROUP_CAP_EXCEEDED`, lower coverage or
  wait.
- **Settlement is in USDC.** Confirm your wallet holds enough USDC to
  cover the premium plus a small buffer for gas (in ETH on Base, ~$0.01
  per tx).

---

## Reference addresses (Base mainnet)

```
USDC                  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
CoverRouter           0xd5f8678A0F2149B6342F9014CCe6d743234Ca025
PolicyManager         0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a
LuminaOracle          0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87
EmergencyPause        0xc7ac8c19c3f10f820d7e42f07e6e257bacc22876
TimelockController    0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a
GnosisSafe            0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD

Vaults:
  VolatileShort       0xbd44547581b92805aAECc40EB2809352b9b2880d
  VolatileLong        0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904
  StableShort         0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC
  StableLong          0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c

Active shields:
  BCS (BTCCAT-001)    0x36e37899D9D89bf367FA66da6e3CebC726Df4ce8
  EAS (ETHAPOC-001)   0xA755D134a0b2758E9b397E11E7132a243f672A3D
```
