LUMINA PROTOCOL — SKILL FILE FOR AI AGENTS
Version: 3.0 | Chain: Base Mainnet (8453) | Settlement: USDC | March 2026

════════════════════════════════════════════════════════════
1. WHAT IS LUMINA?
════════════════════════════════════════════════════════════

Lumina Protocol is parametric insurance built exclusively for AI agents on Base L2.
You buy insurance policies to protect portfolios against market crashes, stablecoin depegs, impermanent loss, and smart contract exploits.
You can also deposit USDC into vaults to earn yield from insurance premiums + Aave V3 lending.
All operations happen via HTTP API calls. No blockchain knowledge needed for insurance operations.

Settlement asset: USDC (Circle, 6 decimals) — 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
Chain: Base Mainnet (Chain ID: 8453)

════════════════════════════════════════════════════════════
2. QUICK START (5 minutes)
════════════════════════════════════════════════════════════

Step 1 — Check API is online:
  curl https://lumina-protocol-production.up.railway.app/api/v2/health
  Expected: {"status":"ok","chain":8453,"version":"2.0.0"}

Step 2 — Create your API key:
  curl -X POST https://lumina-protocol-production.up.railway.app/api/v2/keys/create \
    -H "Content-Type: application/json" \
    -d '{"wallet":"0xYOUR_WALLET","label":"my-agent"}'
  Response: {"apiKey":"lum_xxxxx","wallet":"0x...","label":"my-agent","warning":"Save this key securely. It cannot be retrieved again."}
  IMPORTANT: The API key is shown ONLY ONCE. Save it immediately.
  Maximum 3 keys per wallet.

Step 3 — Get a price quote:
  curl -X POST https://lumina-protocol-production.up.railway.app/api/v2/quote \
    -H "Content-Type: application/json" \
    -d '{"productId":"BSS","coverageAmount":1000000000,"durationSeconds":1209600,"buyer":"0xYOUR_WALLET"}'
  Note: Quotes expire in 5 minutes (300 seconds).

Step 4 — Buy a policy:
  curl -X POST https://lumina-protocol-production.up.railway.app/api/v2/purchase \
    -H "Content-Type: application/json" \
    -H "X-API-Key: lum_YOUR_KEY" \
    -d '{"productId":"BSS","coverageAmount":1000000000,"durationSeconds":1209600}'
  Requires: USDC balance + USDC approved to CoverRouter (0xd5f8678A0F2149B6342F9014CCe6d743234Ca025)

Step 5 — Check your policies:
  curl https://lumina-protocol-production.up.railway.app/api/v2/policies?buyer=0xYOUR_WALLET

════════════════════════════════════════════════════════════
3. API REFERENCE
════════════════════════════════════════════════════════════

Base URL: https://lumina-protocol-production.up.railway.app

All write operations require X-API-Key header.

--- GET /api/v2/health ---
No auth required.
Response: { "status": "ok", "chain": 8453, "version": "2.0.0" }
Status codes: 200

--- GET /api/v2/products ---
No auth required.
Response: { "products": [{ "name", "id", "productId", "shield", "riskType", "vaults", "pBase", "minDuration", "maxDuration", "deductible", "assets", "stablecoins" }] }
Status codes: 200, 500

--- GET /api/v2/vaults ---
No auth required.
Response: { "vaults": [{ "name", "address", "riskType", "totalAssets", "allocatedAssets", "freeAssets", "utilizationBps", "totalShares", "cooldownDuration", "estimatedAPY" }] }
Status codes: 200, 500

--- GET /api/v2/vaults/:address ---
No auth required.
Response: Same as single vault from above.
Status codes: 200, 404, 500

--- POST /api/v2/quote ---
No auth required.
Body: { "productId": "BSS", "coverageAmount": 1000000000, "durationSeconds": 1209600, "buyer": "0x..." }
Optional body fields: "asset" (for BSS: "ETH" or "BTC"), "stablecoin" (for DEPEG: "USDT" or "DAI"), "protocol" (for EXPLOIT: protocol address)
Response: { "quote": { "productId", "productName", "coverageAmount", "premiumAmount", "durationSeconds", "asset", "stablecoin", "protocol", "buyer", "deadline", "nonce", "utilizationAtQuote" }, "signature": "0x...", "signedQuote": {...} }
Quotes expire in 300 seconds (5 minutes). Get a fresh quote before each purchase.
Status codes: 200, 400, 500

--- POST /api/v2/purchase ---
Requires: X-API-Key header
Body: { "productId": "BSS", "coverageAmount": 1000000000, "durationSeconds": 1209600 }
  productId: "BSS" | "DEPEG" | "IL" | "EXPLOIT"
  coverageAmount: 6 decimals. Min $100 (100000000), Max $100,000 (100000000000)
  durationSeconds: Min 604800 (7 days), Max 31536000 (365 days) — varies by product
Response: { "success": true, "txHash": "0x...", "product": "Black Swan Shield", "productId": "BSS", "coverage": "1000000000", "premium": "...", "premiumUSD": "...", "durationDays": 14, "wallet": "0x...", "explorer": "https://basescan.org/tx/0x...", "message": "Policy purchased successfully." }
Status codes: 201, 400, 401, 409, 429, 500

--- GET /api/v2/policies ---
No auth required.
Query: ?buyer=0xWALLET_ADDRESS&page=1&limit=50
Response: { "buyer": "0x...", "policies": [{ "policyId", "productId", "productName", "shield", "coverageAmount", "premiumPaid", "maxPayout", "startTimestamp", "waitingEndsAt", "expiresAt", "status" }], "count", "total", "page", "limit", "hasMore" }
Status values: "NONEXISTENT", "WAITING", "ACTIVE", "EXPIRED", "SETTLEMENT", "PAID_OUT", "CANCELLED"
Pagination: page (default 1), limit (default 50, max 100)
Status codes: 200, 400, 500

--- POST /api/v2/renew ---
Requires: X-API-Key header
Body: { "productId": "BSS", "durationSeconds": 1209600 }
Response: { "message": "Use POST /purchase with these parameters to renew:", "suggestedParams": { "productId", "coverageAmount", "durationSeconds" }, "note": "Premium will be recalculated based on current vault utilization.", "previousPolicy": {...} }
This is a convenience endpoint. It finds your last policy for the product and suggests params for /purchase. It does NOT execute the purchase.
Status codes: 200, 400, 401, 404, 500

--- POST /api/v2/keys/create ---
No auth required.
Body: { "wallet": "0x...", "label": "my-agent" }
Response: { "apiKey": "lum_...", "wallet": "0x...", "label": "...", "warning": "Save this key securely. It cannot be retrieved again." }
Max 3 keys per wallet. The API key is shown ONLY ONCE.
Status codes: 201, 400, 500

--- GET /api/v2/keys/list ---
No auth required.
Query: ?wallet=0x...
Response: { "wallet": "0x...", "keys": [{ "label", "createdAt" }] }
Does NOT return the actual key values (they are hashed).
Status codes: 200, 400

--- DELETE /api/v2/keys/revoke ---
Body: { "apiKey": "lum_..." }
Response: { "revoked": true, "wallet": "0x..." }
Status codes: 200, 404

--- GET /api/v2/dashboard ---
No auth required. Returns cached data (refreshed every 60 seconds).
Query: ?wallet=0x... (optional, for user-specific data)
Response: { "vaults": [...], "policies": [...], "lastUpdated", "cacheAge" }
Status codes: 200, 500

RATE LIMITS:
  General: 100 requests per 15 minutes per IP
  Key creation: 5 per hour per IP
  Purchase: 30 per minute per API key
  Per-wallet: max 5 purchases per minute
  Concurrent: 1 purchase per wallet at a time (nonce lock)

════════════════════════════════════════════════════════════
4. INSURANCE PRODUCTS
════════════════════════════════════════════════════════════

--- BLACK SWAN SHIELD (BSS) ---
What it covers: ETH or BTC price crashes exceeding 30%
Product ID: "BSS"
Trigger: Price drops >30% from purchase price (TRIGGER_DROP_BPS = 3000)
Verification: Oracle-signed TWAP 15 min or 3 consecutive Chainlink rounds
Deductible: 20% — Payout: 80% of coverage (binary, all-or-nothing)
Duration: 7 to 30 days
Waiting period: 1 hour
Base rate: 6.5% annualized (650 bps)
Assets: ETH, BTC
Max proof age: 30 minutes
Fee: 3% on premium (purchase) + 3% on payout (claim)

Example: Buy $10,000 BSS coverage for 14 days
  Premium ≈ $10,000 × 0.065 × M(U) × (14/365) = ~$25-40 depending on utilization
  If trigger activates: payout = $10,000 × 80% = $8,000 gross, $7,760 net (after 3% fee)

--- DEPEG SHIELD ---
What it covers: Stablecoin losing its peg (dropping below $0.95)
Product ID: "DEPEG"
Trigger: Stablecoin TWAP 30 min < $0.95 (TRIGGER_PRICE = 95,000,000 in Chainlink 8-decimal format)
Verification: TWAP 30 min or 5 consecutive Chainlink rounds
Deductibles per stablecoin:
  DAI:  12% deductible → 88% payout
  USDT: 15% deductible → 85% payout
  USDC: EXCLUDED (circular — Lumina settles in USDC)
Duration: 14 to 365 days
Waiting period: 24 hours
Base rate: 2.5% annualized (250 bps)
Stablecoins: USDT, DAI (specify in quote with "stablecoin" field)
Fee: 3% on premium + 3% on payout

--- IL INDEX COVER ---
What it covers: Impermanent loss exceeding 2% at policy expiry
Product ID: "IL"
Trigger: IL% > 2% at expiry (European-style — can ONLY claim within 48h after expiry)
Formula: IL = 1 - (2 × sqrt(r)) / (1 + r), where r = priceAtExpiry / priceAtPurchase
Payout: Proportional — Coverage × max(0, IL% - 2%) × 90%
Payout cap: 11.7% of coverage (max IL 13% × 90% factor)
Duration: 14 to 90 days
Waiting period: None
Settlement window: 48 HOURS after expiry. If you miss this window, the claim is lost.
Base rate: 8.5% annualized (850 bps)
Asset: ETH
Fee: 3% on premium + 3% on payout

CRITICAL: IL Index uses European-style resolution. You can ONLY claim during the 48-hour window after policy expiry. Set a reminder.

--- EXPLOIT SHIELD ---
What it covers: Smart contract exploits/hacks on covered DeFi protocols
Product ID: "EXPLOIT"
Trigger: DUAL — BOTH conditions must be met:
  1. Governance token drops >25% in 24h (GOV_DROP_THRESHOLD_BPS = 2500)
  2. Receipt token drops >30% for 4+ hours OR protocol contract is paused
  Condition 1 verified by Chainlink oracle. Condition 2 verified by Phala TEE.
Deductible: 10% — Payout: 90% of coverage (binary)
Duration: 90 to 365 days
Waiting period: 14 days
Max coverage: $50,000 per wallet
Lifetime cap: $150,000 per wallet
Base rate: 4.0% annualized (400 bps)
Covered protocols: Compound III, Uniswap V3, MakerDAO (Tier 1), Curve, Morpho (Tier 2)
Excluded: Aave V3 (circular — Lumina deposits in Aave)
Fee: 3% on premium + 3% on payout

COVERAGE AMOUNT REFERENCE (6 decimals):
  $100     = 100000000
  $500     = 500000000
  $1,000   = 1000000000
  $5,000   = 5000000000
  $10,000  = 10000000000
  $50,000  = 50000000000
  $100,000 = 100000000000

DURATION REFERENCE (in seconds):
  7 days   = 604800
  14 days  = 1209600
  30 days  = 2592000
  90 days  = 7776000
  180 days = 15552000
  365 days = 31536000

════════════════════════════════════════════════════════════
5. VAULTS (for liquidity providers)
════════════════════════════════════════════════════════════

Four vaults, each with a different risk profile and cooldown period:

| Vault          | Cooldown | Products            | Est. APY  | Address                                    |
|----------------|----------|---------------------|-----------|--------------------------------------------|
| VolatileShort  | 30 days  | BSS + IL            | 12-16%    | 0xbd44547581b92805aAECc40EB2809352b9b2880d |
| VolatileLong   | 90 days  | IL long + BSS spill | 15-19%    | 0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904 |
| StableShort    | 90 days  | Depeg short         | 11-15%    | 0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC |
| StableLong     | 365 days | Depeg + Exploit     | 18-27%    | 0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c |

YIELD SOURCES:
  Layer 1: Aave V3 base yield (~3-5% APY) — USDC deposited automatically
  Layer 2: Insurance premium income — premiums from policy buyers flow to vaults

HOW TO DEPOSIT: On-chain transaction directly to the vault contract.
  Call deposit(amount, receiverAddress) on the vault. Min deposit: $100 USDC.
  The API provides read-only vault data (GET /api/v2/vaults). Deposits require on-chain interaction.

HOW TO WITHDRAW:
  1. Call requestWithdrawal(shares) on the vault — starts cooldown timer
  2. Wait for cooldown period (30 to 365 days depending on vault)
  3. Call completeWithdrawal(receiverAddress) — receive USDC + accumulated yield
  Partial withdrawals allowed (any number of shares). Up to 10 concurrent withdrawal requests.

PERFORMANCE FEE: 3% charged ONLY on positive yield (profit above your deposit cost).
  Example: Deposit $10,000 → Withdraw $10,500 → Profit $500 → Fee $15 → Net $10,485
  If no profit, no fee is charged.

SHARES ARE SOULBOUND: Vault shares cannot be transferred or sold. This prevents market manipulation. You can only deposit and withdraw through the vault contract.

NEW DEPOSITS: You can deposit more USDC at any time. Shares accumulate. New deposits do NOT affect existing withdrawal requests or cooldowns.

════════════════════════════════════════════════════════════
6. PRICING MODEL (Kink)
════════════════════════════════════════════════════════════

Premium = Coverage × P_base × RiskMult × DurationDiscount × M(U) × (Duration / 365 days)

Where M(U) is the utilization multiplier (from PremiumMath.sol):

  If U <= 80%:  M(U) = 1 + (U / 0.80) × 0.5
  If U > 80%:   M(U) = 1 + 0.5 + ((U - 0.80) / 0.20) × 3.0
  If U > 95%:   REJECTED — no new policies accepted

Multiplier table:
  0% = 1.00x | 20% = 1.13x | 40% = 1.25x | 60% = 1.38x
  80% = 1.50x (kink) | 85% = 2.25x | 90% = 3.00x | 95% = REJECTED

The model self-balances: high demand → scarce capital → premiums rise → LP yield rises → attracts LPs → more capital → premiums normalize.

Always GET /api/v2/quote before purchasing to see the current premium.

════════════════════════════════════════════════════════════
7. CLAIM RESOLUTION
════════════════════════════════════════════════════════════

Claims are AUTOMATIC. The oracle monitors conditions and triggers payouts when met. You do NOT need to submit a claim manually.

BSS:     Oracle detects >30% drop → verifies TWAP → triggers payout → 80% of coverage sent to your wallet
DEPEG:   Oracle detects stablecoin <$0.95 → verifies TWAP → triggers payout → 85-88% sent
IL:      At expiry, oracle calculates IL → if >2%, proportional payout → sent within 48h settlement window
EXPLOIT: Oracle detects gov token -25% AND TEE verifies receipt token → 90% of coverage sent

Payout = (Coverage × (100% - Deductible%)) × 97% (after 3% protocol fee)

Claim grace period: 24 hours after policy expiry for BSS, Depeg, Exploit.
IL settlement: ONLY within 48 hours after expiry (European-style). Do not miss this window.

Large payouts may be delayed (configurable by protocol governance) for security review.

════════════════════════════════════════════════════════════
8. RENEWAL STRATEGY
════════════════════════════════════════════════════════════

There is NO auto-renewal on-chain. Your agent must monitor expiresAt and buy a new policy before the current one expires.

Recommended repurchase windows (buy new policy this many seconds before expiry):
  BSS:     7,200 (2 hours before — accounts for 1h waiting period)
  DEPEG:   90,000 (25 hours before — accounts for 24h waiting period)
  IL:      3,600 (1 hour before)
  EXPLOIT: 1,296,000 (15 days before — accounts for 14d waiting period)

Agent loop pseudocode:
  1. GET /api/v2/policies?buyer=myWallet
  2. For each active policy: timeLeft = expiresAt - now
  3. If timeLeft < repurchaseWindow → GET /api/v2/quote → if acceptable → POST /api/v2/purchase
  4. Sleep 3600 seconds → repeat

You CAN have multiple policies of the same product active simultaneously.
Premium is RECALCULATED on each purchase based on current vault utilization (Kink Model).

Convenience: POST /api/v2/renew returns suggested params based on your last policy. Still requires POST /api/v2/purchase to execute.

════════════════════════════════════════════════════════════
9. ERROR HANDLING
════════════════════════════════════════════════════════════

HTTP STATUS CODES:
  200 — Success
  201 — Created (key created, policy purchased)
  400 — Bad request (invalid params, insufficient balance/allowance)
  401 — Unauthorized (missing or invalid API key)
  404 — Not found
  409 — Conflict (concurrent purchase in progress for this wallet)
  429 — Rate limit exceeded
  500 — Internal server error

COMMON ERRORS AND REMEDIES:
  "Invalid API key" → Create a new key with POST /api/v2/keys/create
  "Insufficient USDC balance" → Fund your wallet with USDC on Base L2
  "Insufficient USDC allowance" → Approve CoverRouter to spend your USDC
  "Rate limit exceeded" → Wait 60 seconds, retry
  "Concurrent purchase lock" → Wait for previous purchase to complete
  "Duration between 7 and 365 days" → Check product min/max duration
  "Coverage between $100 and $100,000" → Adjust coverageAmount
  "Daily payout limit reached" → Wait until next day
  "Product frozen" → Product temporarily halted due to extreme volatility
  Network error → Wait 10 seconds, retry up to 3 times
  Any other error → Log it, continue your loop (never crash)

════════════════════════════════════════════════════════════
10. SECURITY
════════════════════════════════════════════════════════════

Smart Contracts: 79 tests passing. Solidity 0.8.20. CEI pattern. SafeERC20. ReentrancyGuard.
Governance: TimelockController (48h delay) + Gnosis Safe (2-of-3 multisig). No instant admin changes.
Oracle: Multisig-capable (N-of-M). Chainlink TWAP verification. L2 sequencer uptime check (1h grace).
API: Rate limiting, CORS restrictions, Helmet headers, NonceManager, sanitized errors.

Collateral: Strict 1:1. Every $1 of coverage = $1 USDC locked in vault. Max utilization 95%.
Session approval: Buyers must authorize relayers before purchases can be made on their behalf.

NEVER share your private key with anyone — not even Lumina. The API only needs your wallet address and API key.

════════════════════════════════════════════════════════════
11. DEVELOPER INTEGRATION EXAMPLES
════════════════════════════════════════════════════════════

PYTHON (requests):

import requests

API = "https://lumina-protocol-production.up.railway.app/api/v2"

# 1. Create API key
key = requests.post(f"{API}/keys/create", json={
    "wallet": "0xYourAgentWallet",
    "label": "my-agent"
}).json()
api_key = key["apiKey"]  # Save this! Shown only once

# 2. Get quote
quote = requests.post(f"{API}/quote", json={
    "productId": "BSS",
    "coverageAmount": 10000000000,  # $10,000 (6 decimals)
    "durationSeconds": 1209600,     # 14 days
    "buyer": "0xYourAgentWallet"
}).json()
print(f"Premium: {quote['quote']['premiumAmount']}")

# 3. Purchase policy
policy = requests.post(f"{API}/purchase",
    headers={"X-API-Key": api_key},
    json={
        "productId": "BSS",
        "coverageAmount": 10000000000,
        "durationSeconds": 1209600
    }
).json()
print(f"TX: {policy.get('txHash', policy.get('error'))}")

# 4. Check policies
policies = requests.get(f"{API}/policies", params={
    "buyer": "0xYourAgentWallet"
}).json()


JAVASCRIPT (Node.js / fetch):

const API = "https://lumina-protocol-production.up.railway.app/api/v2";

// 1. Create API key
const keyRes = await fetch(`${API}/keys/create`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ wallet: "0xYourWallet", label: "my-agent" })
});
const { apiKey } = await keyRes.json();

// 2. Get quote
const quoteRes = await fetch(`${API}/quote`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    productId: "BSS",
    coverageAmount: 10000000000,
    durationSeconds: 1209600,
    buyer: "0xYourWallet"
  })
});
const quote = await quoteRes.json();

// 3. Purchase
const purchaseRes = await fetch(`${API}/purchase`, {
  method: "POST",
  headers: { "Content-Type": "application/json", "X-API-Key": apiKey },
  body: JSON.stringify({ productId: "BSS", coverageAmount: 10000000000, durationSeconds: 1209600 })
});
const policy = await purchaseRes.json();


VAULT INTERACTION (ethers.js — on-chain, not API):

const { ethers } = require("ethers");

const VAULT_ABI = [
  "function deposit(uint256 assets, address receiver) returns (uint256 shares)",
  "function requestWithdrawal(uint256 shares)",
  "function completeWithdrawal(address receiver) returns (uint256 assets)",
  "function balanceOf(address) view returns (uint256)",
  "function totalAssets() view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)"
];

const USDC_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)"
];

// Vault addresses (Base L2 production)
const VAULTS = {
  VolatileShort: "0xbd44547581b92805aAECc40EB2809352b9b2880d",
  VolatileLong:  "0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904",
  StableShort:   "0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC",
  StableLong:    "0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c"
};
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

const provider = new ethers.JsonRpcProvider("https://mainnet.base.org");
const signer = new ethers.Wallet("YOUR_PRIVATE_KEY", provider);

// Step 1: Approve USDC for vault
const usdc = new ethers.Contract(USDC, USDC_ABI, signer);
await usdc.approve(VAULTS.VolatileShort, ethers.parseUnits("10000", 6));

// Step 2: Deposit $10,000
const vault = new ethers.Contract(VAULTS.VolatileShort, VAULT_ABI, signer);
const shares = await vault.deposit(ethers.parseUnits("10000", 6), signer.address);

// Step 3: Request withdrawal (after earning yield)
await vault.requestWithdrawal(shares);

// Step 4: Complete withdrawal (after cooldown: 30 days for VolatileShort)
// Wait 30 days...
const assets = await vault.completeWithdrawal(signer.address);

NOTE: Vault function signatures verified from BaseVault.sol source code.

════════════════════════════════════════════════════════════
12. CONTRACT ADDRESSES (Production — Base L2, Chain 8453)
════════════════════════════════════════════════════════════

Core:
  CoverRouter:       0xd5f8678A0F2149B6342F9014CCe6d743234Ca025
  PolicyManager:     0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a
  LuminaOracle:      0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87
  PhalaVerifier:     0x468b9D2E9043c80467B610bC290b698ae23adb9B

Vaults:
  VolatileShort:     0xbd44547581b92805aAECc40EB2809352b9b2880d
  VolatileLong:      0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904
  StableShort:       0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC
  StableLong:        0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c

Shields:
  BSS:               0x2926202bbe3f25f71ef17b25a20ebe8be028af5f
  Depeg:             0x7578816a803d293bbb4dbea0efbed872842679d0
  ILIndex:           0x2ac0d2a9889a8a4143727a0240de3fed4650dd93
  Exploit:           0x9870830c615d1b9c53dfee4136c4792de395b7a1

Governance:
  TimelockController: 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a
  Gnosis Safe (2/3):  0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD

External:
  USDC (Circle):     0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
  Aave V3 Pool:      0xA238Dd80C259a72e81d7e4664a9801593F98d1c5

All contracts verified on BaseScan. Verify at https://basescan.org/address/[ADDRESS]

════════════════════════════════════════════════════════════
13. CONTACT & SUPPORT
════════════════════════════════════════════════════════════

Website: https://www.lumina-org.com
Dashboard: https://www.lumina-org.com/dashboard
Tutorial: https://www.lumina-org.com/tutorial.html
GitHub: https://github.com/org-lumina/LUMINA-PROTOCOL
Support: support@lumina-org.com
Sales: labs@lumina-org.com

════════════════════════════════════════════════════════════
VERIFICATION
════════════════════════════════════════════════════════════

Every data point in this SKILL was extracted from the source code on March 31, 2026.
Sources: api/src/index.js, src/libraries/PremiumMath.sol, src/core/CoverRouter.sol,
src/vaults/BaseVault.sol, src/products/*.sol, docs/PRODUCTION-ADDRESSES.md, lib/lumina-config.ts
