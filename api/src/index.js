require("dotenv").config();
const express = require("express");
const cors = require("cors");
const { ethers } = require("ethers");
const crypto = require("crypto");

const app = express();
app.use(cors());
app.use(express.json());

// ═══════════════════════════════════════════════════════════
//  CONFIG
// ═══════════════════════════════════════════════════════════

const PORT = process.env.PORT || 3001;
const RPC_URL = process.env.RPC_URL || "https://base-mainnet.g.alchemy.com/v2/dm1oJK0wwWGvliEVxc2Bh";
const CHAIN_ID = 8453;

const COVER_ROUTER = process.env.COVER_ROUTER || "0x8407afBa100812bFb5f9f188b44379E4268eff94";
const POLICY_MANAGER = process.env.POLICY_MANAGER || "0x615e9c32c70350192fCa9BAC06Ba8ebA9dC4fEF4";

const VAULTS = {
  VOLATILE_SHORT: "0x2D7D735f71638730cbe9A143227A00Fa64E94E88",
  VOLATILE_LONG:  "0xDf30548d46e77015A4dDA82D3c263e81a60B075c",
  STABLE_SHORT:   "0x8F6e6a4Ee6aeD70757c16382eA7156AD4b33c078",
  STABLE_LONG:    "0x3e8dF8746c42Aa4B0CDb089174aBbBaf2C3aD46c",
};

const SHIELDS = {
  BSS:     "0xC01ED8eF52506B29545f08BBf9aAe5Fe59b15CF7",
  DEPEG:   "0xCdA417909d43F252f63034346db9121441BfE70F",
  IL_INDEX:"0x73fB5CB9Aa0BeBAf74a3a4b6Cfb09d3Fd66C9FB6",
  EXPLOIT: "0x05170F9Ca56026001064F5242c6F9F7f181c6baA",
};

// Product IDs (keccak256 of product name)
const PRODUCT_IDS = {
  "BLACKSWAN-001":   ethers.keccak256(ethers.toUtf8Bytes("BLACKSWAN-001")),
  "DEPEG-STABLE-001":ethers.keccak256(ethers.toUtf8Bytes("DEPEG-STABLE-001")),
  "ILPROT-001":      ethers.keccak256(ethers.toUtf8Bytes("ILPROT-001")),
  "EXPLOIT-001":     ethers.keccak256(ethers.toUtf8Bytes("EXPLOIT-001")),
};

// ═══════════════════════════════════════════════════════════
//  API KEY SYSTEM
// ═══════════════════════════════════════════════════════════

const API_KEY_SALT = crypto.randomBytes(16).toString("hex");
const apiKeys = new Map();           // hash → { wallet, createdAt, label }
const walletToKeys = new Map();      // wallet → [hashes]
const purchaseNonces = new Map();    // wallet → boolean (processing)
const purchaseRateLimits = new Map(); // wallet → [timestamps]

function hashApiKey(key) {
  return crypto.createHash("sha256").update(key + API_KEY_SALT).digest("hex");
}

function generateApiKey() {
  return "lum_" + crypto.randomBytes(24).toString("hex");
}

function authenticateApiKey(req, res, next) {
  const apiKey = req.headers["x-api-key"] || req.query.apiKey;
  if (!apiKey) return res.status(401).json({ error: "API key required. Pass via X-API-Key header." });

  const hashedKey = hashApiKey(apiKey);
  const keyData = apiKeys.get(hashedKey);
  if (!keyData) return res.status(401).json({ error: "Invalid API key" });

  // Rate limiting: max 5 purchases per minute
  const now = Date.now();
  const recentPurchases = (purchaseRateLimits.get(keyData.wallet) || []).filter(t => now - t < 60000);
  if (recentPurchases.length >= 5) {
    return res.status(429).json({ error: "Rate limit: max 5 purchases per minute" });
  }

  req.walletAddress = keyData.wallet;
  req.apiKeyHash = hashedKey;
  next();
}

// ═══════════════════════════════════════════════════════════
//  PRODUCTS CONFIG
// ═══════════════════════════════════════════════════════════

const PRODUCTS = [
  {
    name: "Black Swan Shield",
    id: "BLACKSWAN-001",
    productId: PRODUCT_IDS["BLACKSWAN-001"],
    shield: SHIELDS.BSS,
    riskType: "VOLATILE",
    vaults: [VAULTS.VOLATILE_SHORT, VAULTS.VOLATILE_LONG],
    pBase: 250,           // 2.50% base premium (BPS)
    minDuration: 7 * 86400,
    maxDuration: 30 * 86400,
    deductible: 3000,     // 30% drop trigger
    assets: ["ETH", "BTC"],
    stablecoins: ["USDC", "USDT", "DAI"],
  },
  {
    name: "Depeg Shield",
    id: "DEPEG-STABLE-001",
    productId: PRODUCT_IDS["DEPEG-STABLE-001"],
    shield: SHIELDS.DEPEG,
    riskType: "STABLE",
    vaults: [VAULTS.STABLE_SHORT, VAULTS.STABLE_LONG],
    pBase: 50,            // 0.50% base premium
    minDuration: 30 * 86400,
    maxDuration: 365 * 86400,
    deductible: 500,      // 5% depeg trigger
    assets: ["USDC", "USDT", "DAI"],
    stablecoins: ["USDC", "USDT", "DAI"],
  },
  {
    name: "IL Protection",
    id: "ILPROT-001",
    productId: PRODUCT_IDS["ILPROT-001"],
    shield: SHIELDS.IL_INDEX,
    riskType: "VOLATILE",
    vaults: [VAULTS.VOLATILE_SHORT, VAULTS.VOLATILE_LONG],
    pBase: 150,           // 1.50% base premium
    minDuration: 30 * 86400,
    maxDuration: 90 * 86400,
    deductible: 200,      // 2% IL trigger
    assets: ["ETH", "BTC"],
    stablecoins: ["USDC", "USDT", "DAI"],
  },
  {
    name: "Exploit Shield",
    id: "EXPLOIT-001",
    productId: PRODUCT_IDS["EXPLOIT-001"],
    shield: SHIELDS.EXPLOIT,
    riskType: "STABLE",
    vaults: [VAULTS.STABLE_SHORT, VAULTS.STABLE_LONG],
    pBase: 300,           // 3.00% base premium
    minDuration: 30 * 86400,
    maxDuration: 365 * 86400,
    deductible: 0,
    assets: [],
    stablecoins: ["USDC", "USDT", "DAI"],
  },
];

// Short-ID → config for /purchase endpoint
const PRODUCT_CONFIG = {
  "BSS":     { name: "Black Swan Shield", fullId: "BLACKSWAN-001",    vault: VAULTS.VOLATILE_SHORT, riskType: "VOLATILE", asset: "ETH",  shield: SHIELDS.BSS },
  "DEPEG":   { name: "Depeg Shield",      fullId: "DEPEG-STABLE-001", vault: VAULTS.STABLE_SHORT,   riskType: "STABLE",   asset: "USDC", shield: SHIELDS.DEPEG },
  "IL":      { name: "IL Index Cover",     fullId: "ILPROT-001",      vault: VAULTS.VOLATILE_SHORT, riskType: "VOLATILE", asset: "ETH",  shield: SHIELDS.IL_INDEX },
  "EXPLOIT": { name: "Exploit Shield",     fullId: "EXPLOIT-001",     vault: VAULTS.STABLE_SHORT,   riskType: "STABLE",   asset: "ETH",  shield: SHIELDS.EXPLOIT },
};

// ═══════════════════════════════════════════════════════════
//  KINK MODEL — Premium Calculation
// ═══════════════════════════════════════════════════════════

const KINK_PARAMS = {
  VOLATILE: { kinkPoint: 0.70, slopeBelow: 0.02, slopeAbove: 0.15, baseRate: 0.01 },
  STABLE:   { kinkPoint: 0.80, slopeBelow: 0.005, slopeAbove: 0.10, baseRate: 0.003 },
};

function calculatePremiumRate(utilization, riskType) {
  const params = KINK_PARAMS[riskType] || KINK_PARAMS.VOLATILE;
  let rate;
  if (utilization <= params.kinkPoint) {
    rate = params.baseRate + params.slopeBelow * utilization;
  } else {
    const rateAtKink = params.baseRate + params.slopeBelow * params.kinkPoint;
    rate = rateAtKink + params.slopeAbove * (utilization - params.kinkPoint);
  }
  return rate;
}

function calculatePremium(coverageAmount, durationSeconds, utilization, riskType) {
  const annualRate = calculatePremiumRate(utilization, riskType);
  const durationYears = durationSeconds / (365 * 86400);
  const premium = coverageAmount * annualRate * durationYears;
  return Math.ceil(premium); // Round up, 6 decimals
}

// ═══════════════════════════════════════════════════════════
//  PROVIDER & RELAYER
// ═══════════════════════════════════════════════════════════

const provider = new ethers.JsonRpcProvider(RPC_URL);
const relayerWallet = new ethers.Wallet(process.env.RELAYER_PRIVATE_KEY || process.env.ORACLE_PRIVATE_KEY, provider);
console.log(`[Relayer] Address: ${relayerWallet.address}`);

// ═══════════════════════════════════════════════════════════
//  COVER ROUTER ABI (for purchase)
// ═══════════════════════════════════════════════════════════

const COVER_ROUTER_ABI = [
  "function purchasePolicyFor(tuple(bytes32 productId, uint256 coverageAmount, uint256 premiumAmount, uint32 durationSeconds, bytes32 asset, bytes32 stablecoin, address protocol, address buyer, uint256 deadline, uint256 nonce) quote, bytes signature) external returns (tuple(uint256 policyId, bytes32 productId, address vault, uint256 coverageAmount, uint256 premiumPaid, uint256 startsAt, uint256 expiresAt))",
];

// ═══════════════════════════════════════════════════════════
//  VAULT & SHIELD ABIs
// ═══════════════════════════════════════════════════════════

const VAULT_ABI = [
  "function totalAssets() view returns (uint256)",
  "function allocatedAssets() view returns (uint256)",
  "function freeAssets() view returns (uint256)",
  "function utilizationBps() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function cooldownDuration() view returns (uint32)",
  "function getVaultState() view returns (tuple(uint256 totalAssets, uint256 allocatedAssets, uint256 freeAssets, uint256 totalShares, uint256 utilizationBps, uint32 cooldownDuration))",
];

const SHIELD_ABI = [
  "function totalPolicies() view returns (uint256)",
  "function activePolicies() view returns (uint256)",
  "function totalActiveCoverage() view returns (uint256)",
  "function getPolicyInfo(uint256 policyId) view returns (tuple(uint256 policyId, address insuredAgent, uint256 coverageAmount, uint256 premiumPaid, uint256 maxPayout, uint256 startTimestamp, uint256 waitingEndsAt, uint256 expiresAt, uint256 cleanupAt, uint8 status))",
];

// ═══════════════════════════════════════════════════════════
//  CACHE LAYER — refreshes on-chain data every 60 seconds
// ═══════════════════════════════════════════════════════════

let cachedData = {
  vaults: [],
  policies: [],
  lastUpdated: 0,
};

const CACHE_VAULT_ABI = [
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function allocatedAssets() view returns (uint256)",
  "function utilizationBps() view returns (uint256)",
];

const CACHE_SHIELD_ABI = [
  "function totalPolicies() view returns (uint256)",
  "function getPolicyInfo(uint256) view returns (uint256,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)",
];

async function refreshCache() {
  try {
    console.log("[Cache] Refreshing on-chain data...");

    // Read vaults
    const vaults = [];
    for (const [name, address] of Object.entries(VAULTS)) {
      try {
        const contract = new ethers.Contract(address, CACHE_VAULT_ABI, provider);
        const totalAssets = await contract.totalAssets();
        await new Promise(r => setTimeout(r, 300));
        const totalSupply = await contract.totalSupply();
        await new Promise(r => setTimeout(r, 300));
        const allocated = await contract.allocatedAssets();
        await new Promise(r => setTimeout(r, 300));
        const utilBps = await contract.utilizationBps();
        vaults.push({
          name,
          address,
          totalAssets: totalAssets.toString(),
          totalSupply: totalSupply.toString(),
          allocatedAssets: allocated.toString(),
          utilizationBps: Number(utilBps),
        });
      } catch (e) {
        console.error(`[Cache] Error reading vault ${name}:`, e.message);
        vaults.push({ name, address, error: true });
      }
      await new Promise(r => setTimeout(r, 1000));
    }

    // Read policies from all shields
    const policies = [];
    for (const [name, address] of Object.entries(SHIELDS)) {
      try {
        const contract = new ethers.Contract(address, CACHE_SHIELD_ABI, provider);
        const count = await contract.totalPolicies();

        for (let id = 1; id <= Number(count); id++) {
          try {
            const info = await contract.getPolicyInfo(id);
            policies.push({
              policyId: Number(info[0]),
              insuredAgent: info[1],
              coverageAmount: info[2].toString(),
              premiumPaid: info[3].toString(),
              maxPayout: info[4].toString(),
              startTimestamp: Number(info[5]),
              expiresAt: Number(info[7]),
              status: Number(info[9]),
              shieldName: name,
              shieldAddress: address,
            });
          } catch { break; }
          await new Promise(r => setTimeout(r, 500));
        }
      } catch (e) {
        console.error(`[Cache] Error reading shield ${name}:`, e.message);
      }
      await new Promise(r => setTimeout(r, 500));
    }

    cachedData = { vaults, policies, lastUpdated: Date.now() };
    console.log(`[Cache] Done: ${vaults.length} vaults, ${policies.length} policies`);
  } catch (e) {
    console.error("[Cache] Refresh failed:", e.message);
  }
}

// Refresh every 60 seconds
refreshCache();
setInterval(refreshCache, 60000);

// ═══════════════════════════════════════════════════════════
//  EIP-712 SIGNING
// ═══════════════════════════════════════════════════════════

const EIP712_DOMAIN = {
  name: "LuminaProtocol",
  version: "1",
  chainId: CHAIN_ID,
  verifyingContract: COVER_ROUTER,
};

const EIP712_TYPES = {
  SignedQuote: [
    { name: "productId", type: "bytes32" },
    { name: "coverageAmount", type: "uint256" },
    { name: "premiumAmount", type: "uint256" },
    { name: "durationSeconds", type: "uint32" },
    { name: "asset", type: "bytes32" },
    { name: "stablecoin", type: "bytes32" },
    { name: "protocol", type: "address" },
    { name: "buyer", type: "address" },
    { name: "deadline", type: "uint256" },
    { name: "nonce", type: "uint256" },
  ],
};

function toBytes32(str) {
  return ethers.encodeBytes32String(str);
}

// ═══════════════════════════════════════════════════════════
//  ENDPOINTS
// ═══════════════════════════════════════════════════════════

// POST /api/v2/keys/create — Create a new API key
app.post("/api/v2/keys/create", (req, res) => {
  const { wallet, label } = req.body;
  if (!wallet || !ethers.isAddress(wallet)) {
    return res.status(400).json({ error: "Valid wallet address required" });
  }

  const existingKeys = walletToKeys.get(wallet.toLowerCase()) || [];
  if (existingKeys.length >= 3) {
    return res.status(400).json({ error: "Maximum 3 API keys per wallet" });
  }

  const rawKey = generateApiKey();
  const hashedKey = hashApiKey(rawKey);

  apiKeys.set(hashedKey, {
    wallet: wallet.toLowerCase(),
    label: label || "default",
    createdAt: Date.now(),
  });

  existingKeys.push(hashedKey);
  walletToKeys.set(wallet.toLowerCase(), existingKeys);

  res.status(201).json({
    apiKey: rawKey,
    wallet: wallet.toLowerCase(),
    label: label || "default",
    warning: "Save this key securely. It cannot be retrieved again.",
  });
});

// GET /api/v2/keys/list — List keys for a wallet (without showing raw keys)
app.get("/api/v2/keys/list", (req, res) => {
  const wallet = (req.query.wallet || "").toLowerCase();
  if (!wallet) return res.status(400).json({ error: "wallet required" });

  const hashes = walletToKeys.get(wallet) || [];
  const keys = hashes.map(h => {
    const data = apiKeys.get(h);
    return data ? { label: data.label, createdAt: data.createdAt } : null;
  }).filter(Boolean);

  res.json({ wallet, keys });
});

// DELETE /api/v2/keys/revoke — Revoke an API key
app.delete("/api/v2/keys/revoke", (req, res) => {
  const { apiKey } = req.body;
  if (!apiKey) return res.status(400).json({ error: "apiKey required" });

  const hashedKey = hashApiKey(apiKey);
  const keyData = apiKeys.get(hashedKey);
  if (!keyData) return res.status(404).json({ error: "API key not found" });

  apiKeys.delete(hashedKey);
  const walletKeys = walletToKeys.get(keyData.wallet) || [];
  walletToKeys.set(keyData.wallet, walletKeys.filter(h => h !== hashedKey));

  res.json({ revoked: true, wallet: keyData.wallet });
});

// POST /api/v2/purchase — Buy a policy with API Key
// NOTE: CoverRouter requires buyer == msg.sender, so the buyer's wallet
// must submit the tx. The API returns a signed quote + calldata for the agent to send.
app.post("/api/v2/purchase", authenticateApiKey, async (req, res) => {
  const wallet = req.walletAddress;

  // Nonce lock: 1 tx at a time per wallet
  if (purchaseNonces.get(wallet)) {
    return res.status(409).json({ error: "Another purchase is being processed for this wallet. Wait a moment." });
  }
  purchaseNonces.set(wallet, true);

  try {
    const { productId, coverageAmount, durationSeconds } = req.body;

    // Validate inputs
    if (!productId || !coverageAmount || !durationSeconds) {
      return res.status(400).json({ error: "Required: productId, coverageAmount, durationSeconds" });
    }

    const product = PRODUCT_CONFIG[productId];
    if (!product) {
      return res.status(400).json({ error: "Unknown productId. Valid: " + Object.keys(PRODUCT_CONFIG).join(", ") });
    }

    // Resolve full product entry for keccak256 productId
    const productEntry = PRODUCTS.find(p => p.id === product.fullId);
    if (!productEntry) {
      return res.status(400).json({ error: "Product not configured: " + product.fullId });
    }

    if (coverageAmount < 100000000 || coverageAmount > 100000000000) {
      return res.status(400).json({ error: "Coverage between $100 and $100,000 (6 decimals). Example: 1000000000 = $1,000" });
    }

    if (durationSeconds < 604800 || durationSeconds > 31536000) {
      return res.status(400).json({ error: "Duration between 7 and 365 days (in seconds). Example: 1209600 = 14 days" });
    }

    // Check USDY balance and allowance BEFORE spending gas
    const usdyAddress = process.env.USDY_ADDRESS || "0x12cc5bd1ab02A50285834eaF6eBdc2d95FB42cC9";
    const coverRouterAddress = process.env.COVER_ROUTER || COVER_ROUTER;
    const usdyContract = new ethers.Contract(usdyAddress, [
      "function allowance(address,address) view returns (uint256)",
      "function balanceOf(address) view returns (uint256)",
    ], provider);

    // Get vault utilization for premium calculation
    const vaultContract = new ethers.Contract(product.vault, [
      "function totalAssets() view returns (uint256)",
      "function allocatedAssets() view returns (uint256)",
    ], provider);

    const [balance, allowance, totalAssets, allocatedAssets] = await Promise.all([
      usdyContract.balanceOf(wallet),
      usdyContract.allowance(wallet, coverRouterAddress),
      vaultContract.totalAssets(),
      vaultContract.allocatedAssets(),
    ]);

    // Calculate premium with Kink Model
    const utilization = Number(totalAssets) > 0 ? Number(allocatedAssets) / Number(totalAssets) : 0;
    const annualRate = calculatePremiumRate(utilization, product.riskType);
    const durationYears = durationSeconds / 31536000;
    const premium = Math.ceil(coverageAmount * annualRate * durationYears);

    // Check balance and allowance
    if (Number(balance) < premium) {
      return res.status(400).json({
        error: "Insufficient USDY balance",
        required: premium.toString(),
        balance: balance.toString(),
        wallet,
      });
    }

    if (Number(allowance) < premium) {
      return res.status(400).json({
        error: "Insufficient USDY allowance. Approve the CoverRouter from your wallet first.",
        required: premium.toString(),
        allowance: allowance.toString(),
        coverRouter: coverRouterAddress,
        wallet,
      });
    }

    // Generate and sign quote — SAME logic as /quote endpoint
    const deadline = Math.floor(Date.now() / 1000) + 300;
    const nonce = BigInt("0x" + crypto.randomBytes(32).toString("hex"));

    const quoteData = {
      productId: productEntry.productId,        // keccak256 hash, NOT encodeBytes32String
      coverageAmount: BigInt(coverageAmount),
      premiumAmount: BigInt(premium),            // premiumAmount, NOT premium
      durationSeconds: Number(durationSeconds),
      asset: toBytes32(product.asset),
      stablecoin: toBytes32("USDC"),
      protocol: ethers.ZeroAddress,              // required field
      buyer: wallet,
      deadline: BigInt(deadline),                // deadline, NOT expiry
      nonce: nonce,                              // required field
    };

    const oracleWallet = new ethers.Wallet(process.env.ORACLE_PRIVATE_KEY);
    const signature = await oracleWallet.signTypedData(EIP712_DOMAIN, EIP712_TYPES, quoteData);

    // Build the quote struct for the contract call
    const quoteStruct = {
      productId: quoteData.productId,
      coverageAmount: quoteData.coverageAmount,
      premiumAmount: quoteData.premiumAmount,
      durationSeconds: quoteData.durationSeconds,
      asset: quoteData.asset,
      stablecoin: quoteData.stablecoin,
      protocol: quoteData.protocol,
      buyer: quoteData.buyer,
      deadline: quoteData.deadline,
      nonce: quoteData.nonce,
    };

    // Execute via Relayer using purchasePolicyFor
    const routerContract = new ethers.Contract(coverRouterAddress, COVER_ROUTER_ABI, relayerWallet);

    console.log(`[Purchase] Executing for ${wallet}: ${product.name}, $${coverageAmount / 1e6} coverage, ${durationSeconds / 86400}d, premium $${premium / 1e6}`);

    // Static call first to catch reverts without spending gas
    try {
      await routerContract.purchasePolicyFor.staticCall(quoteStruct, signature);
    } catch (staticErr) {
      console.error(`[Purchase] Static call failed:`, staticErr.message);
      return res.status(400).json({ error: "Transaction would fail: " + staticErr.message });
    }

    const tx = await routerContract.purchasePolicyFor(quoteStruct, signature);
    const receipt = await tx.wait();

    // Record rate limit
    const timestamps = purchaseRateLimits.get(wallet) || [];
    timestamps.push(Date.now());
    purchaseRateLimits.set(wallet, timestamps);

    console.log(`[Purchase] Success: tx ${receipt.hash}`);

    res.status(201).json({
      success: true,
      txHash: receipt.hash,
      product: product.name,
      productId: productId,
      coverage: coverageAmount.toString(),
      premium: premium.toString(),
      premiumUSD: (premium / 1e6).toFixed(2),
      durationDays: durationSeconds / 86400,
      wallet,
      explorer: "https://basescan.org/tx/" + receipt.hash,
      message: "Policy purchased successfully.",
    });

  } catch (e) {
    console.error(`[Purchase] Error:`, e.message);
    res.status(500).json({ error: "Purchase failed: " + e.message });
  } finally {
    purchaseNonces.delete(wallet);
  }
});

// GET /api/v2/health
app.get("/api/v2/health", (_req, res) => {
  res.json({ status: "ok", chain: CHAIN_ID, version: "2.0.0" });
});

// GET /api/v2/products
app.get("/api/v2/products", (_req, res) => {
  const products = PRODUCTS.map((p) => ({
    name: p.name,
    id: p.id,
    productId: p.productId,
    shield: p.shield,
    riskType: p.riskType,
    vaults: p.vaults,
    pBase: p.pBase,
    minDuration: p.minDuration,
    maxDuration: p.maxDuration,
    deductible: p.deductible,
    assets: p.assets,
    stablecoins: p.stablecoins,
  }));
  res.json({ products });
});

// GET /api/v2/vaults
app.get("/api/v2/vaults", async (_req, res) => {
  try {
    const results = [];
    for (const [name, address] of Object.entries(VAULTS)) {
      const vault = new ethers.Contract(address, VAULT_ABI, provider);
      const state = await vault.getVaultState();

      const totalAssets = Number(state.totalAssets);
      const allocated = Number(state.allocatedAssets);
      const free = Number(state.freeAssets);
      const utilBps = Number(state.utilizationBps);
      const totalShares = state.totalShares.toString();
      const cooldown = Number(state.cooldownDuration);

      const utilization = totalAssets > 0 ? allocated / totalAssets : 0;
      const riskType = name.startsWith("STABLE") ? "STABLE" : "VOLATILE";
      const premiumRate = calculatePremiumRate(utilization, riskType);
      const usdyBaseAPY = 0.0355; // 3.55%
      const estimatedAPY = usdyBaseAPY + premiumRate * utilization;

      results.push({
        name,
        address,
        riskType,
        totalAssets,
        allocatedAssets: allocated,
        freeAssets: free,
        utilizationBps: utilBps,
        totalShares,
        cooldownDuration: cooldown,
        estimatedAPY: Math.round(estimatedAPY * 10000) / 100, // percentage
      });
    }
    res.json({ vaults: results });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/v2/vaults/:address
app.get("/api/v2/vaults/:address", async (req, res) => {
  try {
    const addr = req.params.address;
    const vaultEntry = Object.entries(VAULTS).find(
      ([, a]) => a.toLowerCase() === addr.toLowerCase()
    );
    if (!vaultEntry) {
      return res.status(404).json({ error: "Vault not found" });
    }

    const [name] = vaultEntry;
    const vault = new ethers.Contract(addr, VAULT_ABI, provider);
    const state = await vault.getVaultState();

    const totalAssets = Number(state.totalAssets);
    const allocated = Number(state.allocatedAssets);
    const utilization = totalAssets > 0 ? allocated / totalAssets : 0;
    const riskType = name.startsWith("STABLE") ? "STABLE" : "VOLATILE";
    const premiumRate = calculatePremiumRate(utilization, riskType);
    const estimatedAPY = 0.0355 + premiumRate * utilization;

    res.json({
      name,
      address: addr,
      riskType,
      totalAssets: Number(state.totalAssets),
      allocatedAssets: Number(state.allocatedAssets),
      freeAssets: Number(state.freeAssets),
      utilizationBps: Number(state.utilizationBps),
      totalShares: state.totalShares.toString(),
      cooldownDuration: Number(state.cooldownDuration),
      estimatedAPY: Math.round(estimatedAPY * 10000) / 100,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// POST /api/v2/quote
app.post("/api/v2/quote", async (req, res) => {
  try {
    const { productId, coverageAmount, durationSeconds, asset, stablecoin, protocol, buyer } = req.body;

    if (!productId || !coverageAmount || !durationSeconds || !buyer) {
      return res.status(400).json({ error: "Missing required fields: productId, coverageAmount, durationSeconds, buyer" });
    }

    // Find product config
    const product = PRODUCTS.find((p) => p.id === productId || p.productId === productId);
    if (!product) {
      return res.status(400).json({ error: `Unknown product: ${productId}` });
    }

    // Read current utilization from the first vault for this product
    const vaultAddr = product.vaults[0];
    const vault = new ethers.Contract(vaultAddr, VAULT_ABI, provider);
    const state = await vault.getVaultState();
    const totalAssets = Number(state.totalAssets);
    const allocated = Number(state.allocatedAssets);
    const utilization = totalAssets > 0 ? allocated / totalAssets : 0;

    // Calculate premium (coverageAmount in 6 decimals)
    const premiumAmount = calculatePremium(
      Number(coverageAmount),
      Number(durationSeconds),
      utilization,
      product.riskType
    );

    // Generate nonce and deadline
    const nonce = BigInt("0x" + crypto.randomBytes(32).toString("hex"));
    const deadline = Math.floor(Date.now() / 1000) + 300; // now + 5 min

    // Build the quote values
    const quoteValues = {
      productId: product.productId,
      coverageAmount: BigInt(coverageAmount),
      premiumAmount: BigInt(premiumAmount),
      durationSeconds: Number(durationSeconds),
      asset: asset ? toBytes32(asset) : ethers.ZeroHash,
      stablecoin: stablecoin ? toBytes32(stablecoin) : ethers.ZeroHash,
      protocol: protocol || ethers.ZeroAddress,
      buyer: buyer,
      deadline: BigInt(deadline),
      nonce: nonce,
    };

    // Sign with EIP-712
    const privateKey = process.env.ORACLE_PRIVATE_KEY;
    if (!privateKey) {
      return res.status(500).json({ error: "ORACLE_PRIVATE_KEY not configured" });
    }

    const signer = new ethers.Wallet(privateKey);
    const signature = await signer.signTypedData(EIP712_DOMAIN, EIP712_TYPES, quoteValues);

    // Serialize signedQuote with BigInt→string for JSON
    const signedQuoteSerialized = {};
    for (const [k, v] of Object.entries(quoteValues)) {
      signedQuoteSerialized[k] = typeof v === "bigint" ? v.toString() : v;
    }

    res.json({
      quote: {
        productId: product.productId,
        productName: product.name,
        coverageAmount: coverageAmount.toString(),
        premiumAmount: premiumAmount.toString(),
        durationSeconds: Number(durationSeconds),
        asset: asset || null,
        stablecoin: stablecoin || null,
        protocol: protocol || ethers.ZeroAddress,
        buyer,
        deadline,
        nonce: nonce.toString(),
        utilizationAtQuote: Math.round(utilization * 10000) / 100,
      },
      signature,
      signedQuote: signedQuoteSerialized,
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/v2/policies?buyer=0x...
app.get("/api/v2/policies", async (req, res) => {
  try {
    const buyer = req.query.buyer;
    if (!buyer) {
      return res.status(400).json({ error: "Missing query param: buyer" });
    }

    const buyerAddr = buyer.toLowerCase();
    const policies = [];

    // Scan all shields for policies belonging to buyer
    for (const product of PRODUCTS) {
      const shield = new ethers.Contract(product.shield, SHIELD_ABI, provider);
      let totalPolicies;
      try {
        totalPolicies = Number(await shield.totalPolicies());
      } catch {
        continue;
      }

      // Scan policies (1-indexed)
      for (let i = 1; i <= totalPolicies; i++) {
        try {
          const info = await shield.getPolicyInfo(i);
          if (info.insuredAgent.toLowerCase() === buyerAddr) {
            policies.push({
              policyId: Number(info.policyId),
              productId: product.productId,
              productName: product.name,
              shield: product.shield,
              coverageAmount: info.coverageAmount.toString(),
              premiumPaid: info.premiumPaid.toString(),
              maxPayout: info.maxPayout.toString(),
              startTimestamp: Number(info.startTimestamp),
              waitingEndsAt: Number(info.waitingEndsAt),
              expiresAt: Number(info.expiresAt),
              status: ["NONEXISTENT", "WAITING", "ACTIVE", "EXPIRED", "SETTLEMENT", "PAID_OUT", "CANCELLED"][Number(info.status)] || "UNKNOWN",
            });
          }
        } catch {
          // Policy might not exist or be deleted
          continue;
        }
      }
    }

    res.json({ buyer, policies, count: policies.length });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/v2/dashboard — cached data, instant response
app.get("/api/v2/dashboard", (req, res) => {
  const wallet = (req.query.wallet || "").toLowerCase();

  const userPolicies = wallet
    ? cachedData.policies.filter(p => p.insuredAgent.toLowerCase() === wallet)
    : cachedData.policies;

  res.json({
    vaults: cachedData.vaults,
    policies: userPolicies,
    lastUpdated: cachedData.lastUpdated,
    cacheAge: Date.now() - cachedData.lastUpdated,
  });
});

// ═══════════════════════════════════════════════════════════
//  START
// ═══════════════════════════════════════════════════════════

app.listen(PORT, () => {
  console.log(`Lumina API V2 running on port ${PORT}`);
  console.log(`  Chain: Base Mainnet (${CHAIN_ID})`);
  console.log(`  RPC: ${RPC_URL}`);
  console.log(`  CoverRouter: ${COVER_ROUTER}`);
  console.log(`  Endpoints:`);
  console.log(`    GET  /api/v2/health`);
  console.log(`    GET  /api/v2/products`);
  console.log(`    GET  /api/v2/vaults`);
  console.log(`    GET  /api/v2/vaults/:address`);
  console.log(`    POST /api/v2/quote`);
  console.log(`    POST /api/v2/purchase  [API Key required]`);
  console.log(`    GET  /api/v2/policies?buyer=0x...`);
  console.log(`    POST /api/v2/keys/create`);
  console.log(`    GET  /api/v2/keys/list`);
  console.log(`    DELETE /api/v2/keys/revoke`);

  // Log relayer balance
  provider.getBalance(relayerWallet.address).then(bal => {
    console.log(`[Relayer] Address: ${relayerWallet.address}`);
    console.log(`[Relayer] ETH Balance: ${ethers.formatEther(bal)} ETH`);
  }).catch(() => {});
});
