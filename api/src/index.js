require("dotenv").config();
const express = require("express");
const cors = require("cors");
const helmet = require("helmet");
const rateLimit = require("express-rate-limit");
const { ethers } = require("ethers");
const crypto = require("crypto");
const owsSigner = require("./ows-signer");

const app = express();

// Security headers
app.use(helmet());

// CORS — restrict to known origins
app.use(cors({
  origin: [
    "https://www.lumina-org.com",
    "https://lumina-org.com",
    "https://lumina-app-965484649316.us-central1.run.app",
    "http://localhost:3000",
    "http://localhost:3001"
  ],
  methods: ["GET", "POST"],
  allowedHeaders: ["Content-Type", "X-API-Key"]
}));

// Body size limit
app.use(express.json({ limit: "1mb" }));

// General rate limit: 100 req / 15 min per IP
app.use(rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  message: { error: "Too many requests, try again later" }
}));

// Key creation: 5 per hour per IP
app.use("/api/v2/keys", rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 5,
  message: { error: "Too many key creation requests" }
}));

// Purchase: 30 per minute per API key
app.use("/api/v2/purchase", rateLimit({
  windowMs: 60 * 1000,
  max: 30,
  keyGenerator: (req) => req.headers["x-api-key"] || req.ip,
  message: { error: "Purchase rate limit exceeded" }
}));

// ═══════════════════════════════════════════════════════════
//  CONFIG
// ═══════════════════════════════════════════════════════════

const PORT = process.env.PORT || 3001;
const RPC_URL = process.env.RPC_URL;
if (!RPC_URL) {
  console.error("FATAL: RPC_URL environment variable not set");
  process.exit(1);
}
const CHAIN_ID = 8453;

// PRODUCTION DEPLOYMENT — Base L2 (real USDC + Aave V3)
const COVER_ROUTER = process.env.COVER_ROUTER || "0xd5f8678A0F2149B6342F9014CCe6d743234Ca025";
const POLICY_MANAGER = process.env.POLICY_MANAGER || "0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a";

const VAULTS = {
  VOLATILE_SHORT: process.env.VAULT_VOL_SHORT || "0xbd44547581b92805aAECc40EB2809352b9b2880d",
  VOLATILE_LONG:  process.env.VAULT_VOL_LONG  || "0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904",
  STABLE_SHORT:   process.env.VAULT_STABLE_SHORT || "0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC",
  STABLE_LONG:    process.env.VAULT_STABLE_LONG  || "0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c",
};

const SHIELDS = {
  BSS:     process.env.SHIELD_BSS     || "0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e", // DEPRECATED — registered in CoverRouter
  DEPEG:   process.env.SHIELD_DEPEG   || "0x7578816a803d293bbb4dbea0efbed872842679d0",
  IL_INDEX:process.env.SHIELD_IL      || "0x2ac0d2a9889a8a4143727a0240de3fed4650dd93",
  EXPLOIT: process.env.SHIELD_EXPLOIT || "0x9870830c615d1b9c53dfee4136c4792de395b7a1",
  BCS:     process.env.SHIELD_BCS     || "0x36e37899D9D89bf367FA66da6e3CebC726Df4ce8",
  EAS:     process.env.SHIELD_EAS     || "0xA755D134a0b2758E9b397E11E7132a243f672A3D",
};

// Product IDs (keccak256 of product name)
const PRODUCT_IDS = {
  "BLACKSWAN-001":   ethers.keccak256(ethers.toUtf8Bytes("BLACKSWAN-001")),
  "DEPEG-STABLE-001":ethers.keccak256(ethers.toUtf8Bytes("DEPEG-STABLE-001")),
  "ILPROT-001":      ethers.keccak256(ethers.toUtf8Bytes("ILPROT-001")),
  "EXPLOIT-001":     ethers.keccak256(ethers.toUtf8Bytes("EXPLOIT-001")),
  "BTCCAT-001":      ethers.keccak256(ethers.toUtf8Bytes("BTCCAT-001")),
  "ETHAPOC-001":     ethers.keccak256(ethers.toUtf8Bytes("ETHAPOC-001")),
};

// ═══════════════════════════════════════════════════════════
//  API KEY SYSTEM
// ═══════════════════════════════════════════════════════════

const API_KEY_SALT = process.env.HMAC_SALT || crypto.randomBytes(16).toString("hex");
if (!process.env.HMAC_SALT) {
  console.warn("WARNING: HMAC_SALT not set — API keys will be invalidated on restart. Set HMAC_SALT env var for persistence.");
}
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
    pBase: 650,           // 6.5% — market-calibrated for V2 Kink Model (March 2026)
    minDuration: 7 * 86400,
    maxDuration: 30 * 86400,
    deductible: 3000,     // 30% drop trigger
    assets: ["ETH", "BTC"],
    stablecoins: ["USDC", "USDT", "DAI"],
    deprecated: true,
  },
  {
    name: "Depeg Shield",
    id: "DEPEG-STABLE-001",
    productId: PRODUCT_IDS["DEPEG-STABLE-001"],
    shield: SHIELDS.DEPEG,
    riskType: "STABLE",
    vaults: [VAULTS.STABLE_SHORT, VAULTS.STABLE_LONG],
    pBase: 250,           // 2.5% — market-calibrated for V2 Kink Model (March 2026)
    minDuration: 14 * 86400,
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
    pBase: 850,           // 8.5% — market-calibrated for V2 Kink Model (March 2026)
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
    pBase: 400,           // 4.0% — market-calibrated for V2 Kink Model (March 2026)
    minDuration: 30 * 86400,
    maxDuration: 365 * 86400,
    deductible: 0,
    assets: [],
    stablecoins: ["USDC", "USDT", "DAI"],
  },
  {
    id: "BTCCAT-001",
    name: "BTC Catastrophe Shield",
    productId: ethers.keccak256(ethers.toUtf8Bytes("BTCCAT-001")),
    shield: SHIELDS.BCS,
    asset: "BTC",
    riskType: "VOLATILE",
    vaults: [VAULTS.VOLATILE_SHORT, VAULTS.VOLATILE_LONG],
    pBase: 1500,
    minDuration: 7 * 86400,
    maxDuration: 30 * 86400,
  },
  {
    id: "ETHAPOC-001",
    name: "ETH Apocalypse Shield",
    productId: ethers.keccak256(ethers.toUtf8Bytes("ETHAPOC-001")),
    shield: SHIELDS.EAS,
    asset: "ETH",
    riskType: "VOLATILE",
    vaults: [VAULTS.VOLATILE_SHORT, VAULTS.VOLATILE_LONG],
    pBase: 2000,
    minDuration: 7 * 86400,
    maxDuration: 30 * 86400,
  },
];

// Short-ID → config for /purchase endpoint
const PRODUCT_CONFIG = {
  "BSS":     { name: "Black Swan Shield", fullId: "BLACKSWAN-001",    vault: VAULTS.VOLATILE_SHORT, riskType: "VOLATILE", asset: "ETH",  shield: SHIELDS.BSS },
  "DEPEG":   { name: "Depeg Shield",      fullId: "DEPEG-STABLE-001", vault: VAULTS.STABLE_SHORT,   riskType: "STABLE",   asset: "USDC", shield: SHIELDS.DEPEG },
  "IL":      { name: "IL Index Cover",     fullId: "ILPROT-001",      vault: VAULTS.VOLATILE_SHORT, riskType: "VOLATILE", asset: "ETH",  shield: SHIELDS.IL_INDEX },
  "EXPLOIT": { name: "Exploit Shield",     fullId: "EXPLOIT-001",     vault: VAULTS.STABLE_SHORT,   riskType: "STABLE",   asset: "ETH",  shield: SHIELDS.EXPLOIT },
  "BCS":     { name: "BTC Catastrophe Shield", fullId: "BTCCAT-001",  vault: VAULTS.VOLATILE_SHORT, riskType: "VOLATILE", asset: "BTC",  shield: SHIELDS.BCS },
  "EAS":     { name: "ETH Apocalypse Shield",  fullId: "ETHAPOC-001", vault: VAULTS.VOLATILE_SHORT, riskType: "VOLATILE", asset: "ETH",  shield: SHIELDS.EAS },
};

// ═══════════════════════════════════════════════════════════
//  KINK MODEL — Premium Calculation (mirrors PremiumMath.sol)
// ═══════════════════════════════════════════════════════════

const U_KINK = 0.80;
const SLOPE_BELOW = 0.5;
const SLOPE_ABOVE = 3.0;

function calculatePremiumRate(utilization, pBase) {
  // Mirror of PremiumMath.sol kink model
  let multiplier;
  if (utilization <= U_KINK) {
    multiplier = 1 + (utilization / U_KINK) * SLOPE_BELOW;
  } else {
    multiplier = 1 + SLOPE_BELOW + ((utilization - U_KINK) / (1 - U_KINK)) * SLOPE_ABOVE;
  }

  return (pBase / 10000) * multiplier;
}

function calculatePremium(coverageAmount, durationSeconds, utilization, pBase) {
  const premiumRate = calculatePremiumRate(utilization, pBase);
  const durationDays = durationSeconds / 86400;
  const premium = coverageAmount * premiumRate * (durationDays / 365);
  return Math.ceil(premium); // Round up, 6 decimals
}

// ═══════════════════════════════════════════════════════════
//  PROVIDER & RELAYER
// ═══════════════════════════════════════════════════════════

const provider = new ethers.JsonRpcProvider(RPC_URL);
const baseWallet = new ethers.Wallet(process.env.RELAYER_PRIVATE_KEY || process.env.ORACLE_PRIVATE_KEY, provider);
const relayerWallet = new ethers.NonceManager(baseWallet);
console.log(`[Relayer] Address: ${baseWallet.address}`);

// Initialize OWS (non-blocking, falls back to ethers)
owsSigner.initOWS().then(ready => {
  if (ready) {
    console.log('[Lumina] OWS signing enabled — private key protected by policy engine');
  } else {
    console.log('[Lumina] Using ethers signing (OWS not configured)');
  }
});

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

const POLICY_MANAGER_ABI = [
  "function canAllocate(bytes32 productId, uint256 amount, uint32 policyDurationSeconds) view returns (bool allowed, address vault, bytes32 reason)",
  "function getCorrelationGroup(bytes32 groupId) view returns (tuple(bytes32 groupId, uint16 maxAllocationBps, uint256 currentAllocated, bytes32[] productIds))",
  "function getAllocationState(bytes32 productId) view returns (tuple(bytes32 productId, uint256 allocated, uint256 maxAllowed, uint256 available, uint16 utilizationBps))",
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

    // Reject deprecated products
    if (productEntry.deprecated) {
      return res.status(400).json({ error: "Product deprecated. Use BCS (BTCCAT-001) for BTC or EAS (ETHAPOC-001) for ETH." });
    }

    if (coverageAmount < 100000000 || coverageAmount > 100000000000) {
      return res.status(400).json({ error: "Coverage between $100 and $100,000 (6 decimals). Example: 1000000000 = $1,000" });
    }

    if (durationSeconds < 604800 || durationSeconds > 31536000) {
      return res.status(400).json({ error: "Duration between 7 and 365 days (in seconds). Example: 1209600 = 14 days" });
    }

    // Per-product duration limits
    const PURCHASE_DUR_LIMITS = {
      "BSS": { min: 7 * 86400, max: 30 * 86400 },
      "DEPEG": { min: 14 * 86400, max: 365 * 86400 },
      "IL": { min: 14 * 86400, max: 90 * 86400 },
      "EXPLOIT": { min: 90 * 86400, max: 365 * 86400 },
      "BCS": { min: 7 * 86400, max: 30 * 86400 },
      "EAS": { min: 7 * 86400, max: 30 * 86400 }
    };
    const pLimits = PURCHASE_DUR_LIMITS[productId];
    if (pLimits) {
      if (durationSeconds < pLimits.min) {
        return res.status(400).json({ error: `Duration too short for ${productId}. Minimum: ${pLimits.min / 86400} days` });
      }
      if (durationSeconds > pLimits.max) {
        return res.status(400).json({ error: `Duration too long for ${productId}. Maximum: ${pLimits.max / 86400} days` });
      }
    }

    // Check USDC balance and allowance BEFORE spending gas
    const usdcAddress = process.env.USDC_ADDRESS || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
    const coverRouterAddress = process.env.COVER_ROUTER || COVER_ROUTER;
    const usdcContract = new ethers.Contract(usdcAddress, [
      "function allowance(address,address) view returns (uint256)",
      "function balanceOf(address) view returns (uint256)",
    ], provider);

    // Get vault utilization for premium calculation
    const vaultContract = new ethers.Contract(product.vault, [
      "function totalAssets() view returns (uint256)",
      "function allocatedAssets() view returns (uint256)",
    ], provider);

    const [balance, allowance, totalAssets, allocatedAssets] = await Promise.all([
      usdcContract.balanceOf(wallet),
      usdcContract.allowance(wallet, coverRouterAddress),
      vaultContract.totalAssets(),
      vaultContract.allocatedAssets(),
    ]);

    // Calculate premium with Kink Model (mirrors PremiumMath.sol)
    const utilization = Number(totalAssets) > 0 ? Number(allocatedAssets) / Number(totalAssets) : 0;
    const premium = calculatePremium(coverageAmount, durationSeconds, utilization, productEntry.pBase);

    // Check balance and allowance
    if (Number(balance) < premium) {
      return res.status(400).json({
        error: "Insufficient USDC balance",
        required: premium.toString(),
        balance: balance.toString(),
        wallet,
      });
    }

    if (Number(allowance) < premium) {
      return res.status(400).json({
        error: "Insufficient USDC allowance. Approve the CoverRouter from your wallet first.",
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

    // Sign quote — multi-sig: sign with all available oracle keys, concatenate signatures
    // Contract uses verifyPackedMultisig: expects N×65-byte packed signatures
    let signature = await owsSigner.signTypedData(EIP712_DOMAIN, EIP712_TYPES, quoteData);
    if (!signature) {
      const signatures = [];
      const oracleKeys = [process.env.ORACLE_PRIVATE_KEY, process.env.ORACLE_PRIVATE_KEY_2].filter(Boolean);
      for (const key of oracleKeys) {
        const wallet = new ethers.Wallet(key);
        const sig = await wallet.signTypedData(EIP712_DOMAIN, EIP712_TYPES, quoteData);
        signatures.push(sig);
      }
      // Concatenate: remove 0x prefix from subsequent sigs
      signature = signatures[0];
      for (let i = 1; i < signatures.length; i++) {
        signature += signatures[i].slice(2); // append without 0x
      }
    }

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
    console.error("Purchase failed:", e);
    res.status(500).json({ error: "Purchase failed. Please try again." });
  } finally {
    purchaseNonces.delete(wallet);
  }
});

// GET /api/v2/health
app.get("/api/v2/health", (_req, res) => {
  res.json({ status: "ok", chain: CHAIN_ID, version: "2.0.0" });
});

// GET /api/v2/products
// Each product status reflects the on-chain CoverRouter registration:
//   ACTIVE       — registered + active in router (quotes + purchases work)
//   DEPRECATED   — explicitly deprecated (BSS replaced by BCS+EAS)
//   PENDING_REGISTRATION — shield deployed but NOT registered in router; quotes return PRODUCT_NOT_REGISTERED
//   UNKNOWN      — RPC read failed (rate-limited / transient)
//
// Caching strategy: 30-second in-memory cache + sequential on-chain reads
// on cache miss. Avoids hammering the upstream RPC (which rate-limits
// `Promise.all([6 calls])`) and keeps the endpoint fast (~ms when cached).
let _productsCache = null;
let _productsCacheAt = 0;
const PRODUCTS_CACHE_TTL_MS = 30_000;

app.get("/api/v2/products", async (_req, res) => {
  try {
    // Serve from cache if fresh
    if (_productsCache && (Date.now() - _productsCacheAt) < PRODUCTS_CACHE_TTL_MS) {
      return res.json(_productsCache);
    }

    const router = new ethers.Contract(
      COVER_ROUTER,
      ["function isProductAvailable(bytes32) view returns (bool)"],
      provider
    );

    // Check on-chain status for each product SEQUENTIALLY with a tiny gap
    // between calls. The Railway-side RPC throttles bursts even when they're
    // back-to-back awaits, so we add a 150ms breather between requests.
    // We also skip the on-chain read entirely for products marked
    // `deprecated: true` — their status is hard-coded to DEPRECATED below
    // and we already know on-chain isProductAvailable returns false for them.
    const statuses = [];
    for (let i = 0; i < PRODUCTS.length; i++) {
      const p = PRODUCTS[i];
      if (p.deprecated) {
        statuses.push(false); // deprecated → never on-chain-active
        continue;
      }
      try {
        const v = await router.isProductAvailable(p.productId);
        statuses.push(!!v);
      } catch {
        statuses.push(null);
      }
      // Small gap before the next call — only between non-final entries
      if (i < PRODUCTS.length - 1) {
        await new Promise((r) => setTimeout(r, 150));
      }
    }

    const products = PRODUCTS.map((p, i) => {
      const onChain = statuses[i];
      let status, registeredOnChain;
      if (p.deprecated) {
        status = "DEPRECATED";
        registeredOnChain = onChain === true;
      } else if (onChain === true) {
        status = "ACTIVE";
        registeredOnChain = true;
      } else if (onChain === false) {
        status = "PENDING_REGISTRATION";
        registeredOnChain = false;
      } else {
        status = "UNKNOWN";
        registeredOnChain = null;
      }
      return {
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
        status,
        registeredOnChain,
        deprecated: !!p.deprecated,
        ...(p.deprecated && { deprecatedMessage: "Replaced by BCS (BTCCAT-001) for BTC and EAS (ETHAPOC-001) for ETH. No new policies." }),
        ...(status === "PENDING_REGISTRATION" && {
          pendingMessage: `Shield ${p.shield} is deployed but not registered in CoverRouter. Quotes will fail with PRODUCT_NOT_REGISTERED until governance calls registerProduct().`,
        }),
      };
    });
    const payload = { products };
    _productsCache = payload;
    _productsCacheAt = Date.now();
    res.json(payload);
  } catch (err) {
    console.error("[Products] error:", err);
    res.status(500).json({ error: "Failed to load products", message: err.message });
  }
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
      // Use average pBase for vault-level APY estimate (VOLATILE=750, STABLE=325)
      const avgPBase = riskType === "VOLATILE" ? 750 : 325;
      const premiumRate = calculatePremiumRate(utilization, avgPBase);
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
    console.error("Internal error:", err);
    res.status(500).json({ error: "Internal server error" });
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
    // Use average pBase for vault-level APY estimate (VOLATILE=750, STABLE=325)
    const avgPBase = riskType === "VOLATILE" ? 750 : 325;
    const premiumRate = calculatePremiumRate(utilization, avgPBase);
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
    console.error("Internal error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

// POST /api/v2/quote
app.post("/api/v2/quote", async (req, res) => {
  try {
    const { productId, coverageAmount, durationSeconds, asset, stablecoin, protocol, buyer } = req.body;

    if (!productId || coverageAmount === undefined || coverageAmount === null || durationSeconds === undefined || durationSeconds === null || !buyer) {
      return res.status(400).json({ error: "Missing required fields: productId, coverageAmount, durationSeconds, buyer" });
    }

    // Input validation — reject invalid values with 400, not 500
    const covNum = Number(coverageAmount);
    const durNum = Number(durationSeconds);
    if (!Number.isFinite(covNum) || covNum <= 0) {
      return res.status(400).json({ error: "coverageAmount must be a positive number (USDC 6 decimals, e.g. 1000000000 = $1,000)" });
    }
    if (!Number.isFinite(durNum) || durNum <= 0) {
      return res.status(400).json({ error: "durationSeconds must be a positive number (e.g. 604800 = 7 days)" });
    }
    if (durNum > 31536000) {
      return res.status(400).json({ error: "durationSeconds cannot exceed 31536000 (365 days)" });
    }

    // Min coverage: $100 (100e6 in USDC 6 decimals)
    const MIN_COVERAGE = 100000000;
    if (covNum < MIN_COVERAGE) {
      return res.status(400).json({ error: `Minimum coverage is $100 (${MIN_COVERAGE} in USDC 6 decimals)` });
    }

    // Per-product duration limits
    const DURATION_LIMITS = {
      "BSS": { min: 7 * 86400, max: 30 * 86400 },
      "DEPEG": { min: 14 * 86400, max: 365 * 86400 },
      "IL": { min: 14 * 86400, max: 90 * 86400 },
      "EXPLOIT": { min: 90 * 86400, max: 365 * 86400 },
      "BCS": { min: 7 * 86400, max: 30 * 86400 },
      "EAS": { min: 7 * 86400, max: 30 * 86400 }
    };
    const durLimits = DURATION_LIMITS[productId];
    if (durLimits) {
      if (durNum < durLimits.min) {
        return res.status(400).json({ error: `Duration too short for ${productId}. Minimum: ${durLimits.min / 86400} days (${durLimits.min} seconds)` });
      }
      if (durNum > durLimits.max) {
        return res.status(400).json({ error: `Duration too long for ${productId}. Maximum: ${durLimits.max / 86400} days (${durLimits.max} seconds)` });
      }
    }

    // Alias map: short IDs (BSS, DEPEG, IL, EXPLOIT, BCS, EAS) → full IDs
    const PRODUCT_ALIASES = { "BSS": "BLACKSWAN-001", "DEPEG": "DEPEG-STABLE-001", "IL": "ILPROT-001", "EXPLOIT": "EXPLOIT-001", "BCS": "BTCCAT-001", "EAS": "ETHAPOC-001" };
    const resolvedId = PRODUCT_ALIASES[productId] || productId;

    // Find product config
    const product = PRODUCTS.find((p) => p.id === resolvedId || p.productId === resolvedId || p.id === productId || p.productId === productId);
    if (!product) {
      return res.status(400).json({ error: `Unknown product: ${productId}. Valid: BSS, DEPEG, IL, EXPLOIT, BCS, EAS (or BLACKSWAN-001, DEPEG-STABLE-001, ILPROT-001, EXPLOIT-001, BTCCAT-001, ETHAPOC-001)` });
    }

    // Reject deprecated products
    if (product.deprecated) {
      return res.status(400).json({ error: "Product deprecated. Use BCS (BTCCAT-001) for BTC or EAS (ETHAPOC-001) for ETH." });
    }

    // Verify product is actually registered+active in the on-chain CoverRouter
    // (Depeg/IL/Exploit are not currently registered → fail fast with descriptive error)
    try {
      const routerCheck = new ethers.Contract(
        COVER_ROUTER,
        ["function isProductAvailable(bytes32) view returns (bool)"],
        provider
      );
      const isAvailable = await routerCheck.isProductAvailable(product.productId);
      if (!isAvailable) {
        return res.status(200).json({
          error: "PRODUCT_NOT_REGISTERED",
          message: `Product ${product.id} is not currently registered in the on-chain CoverRouter. Quotes cannot be generated until it is registered. See /api/v2/products for current status.`,
          product: product.id,
        });
      }
    } catch (err) {
      console.warn("[Quote] isProductAvailable check failed (non-blocking):", err.message);
    }

    // Read current utilization from the first vault for this product
    const vaultAddr = product.vaults[0];
    const vault = new ethers.Contract(vaultAddr, VAULT_ABI, provider);
    let totalAssets = 0;
    let allocated = 0;
    let utilization = 0;
    try {
      const state = await vault.getVaultState();
      totalAssets = Number(state.totalAssets);
      allocated = Number(state.allocatedAssets);
      utilization = totalAssets > 0 ? allocated / totalAssets : 0;
    } catch (err) {
      console.warn("[Quote] getVaultState failed:", err.message);
      return res.status(200).json({
        error: "VAULT_READ_FAILED",
        message: `Could not read vault state for ${product.id}. Vault address: ${vaultAddr}. Underlying error: ${err.shortMessage || err.message}`,
        product: product.id,
        vault: vaultAddr,
      });
    }

    // Vault has no liquidity at all → no capacity to write any policy
    if (totalAssets === 0) {
      return res.status(200).json({
        error: "VAULT_EMPTY",
        message: `No liquidity available. Vault ${vaultAddr} has totalAssets = 0. Deposit USDC into the vault before quoting.`,
        product: product.id,
        vault: vaultAddr,
      });
    }

    // Check PolicyManager canAllocate (enforces correlation group caps + per-product max alloc)
    try {
      const pmContract = new ethers.Contract(POLICY_MANAGER, POLICY_MANAGER_ABI, provider);
      const [allowed, allocatedVault, reason] = await pmContract.canAllocate(
        product.productId,
        BigInt(coverageAmount),
        Number(durationSeconds)
      );
      if (!allowed) {
        let reasonStr;
        try { reasonStr = ethers.decodeBytes32String(reason).replace(/\0/g, ""); }
        catch { reasonStr = reason; }
        return res.status(200).json({
          error: reasonStr || "CAPACITY_CHECK_FAILED",
          message: reasonStr === "PRODUCT_CAP_EXCEEDED"
            ? `Coverage exceeds available capacity. Try a lower amount or wait for more liquidity. Vault TVL: ${totalAssets}, allocated: ${allocated}.`
            : reasonStr === "GROUP_CAP_EXCEEDED"
            ? "BCS and EAS share a combined 40% VOLATILE_CRASH correlation cap per vault. The combined usage would exceed this limit."
            : `Capacity check failed: ${reasonStr}`,
          product: product.id,
          vault: vaultAddr,
          totalAssets,
          allocated,
        });
      }
    } catch (err) {
      console.warn("[Quote] canAllocate check failed (non-blocking):", err.message);
    }

    // Calculate premium (coverageAmount in 6 decimals)
    const premiumAmount = calculatePremium(
      Number(coverageAmount),
      Number(durationSeconds),
      utilization,
      product.pBase
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

    // Sign with EIP-712 — multi-sig: sign with all available oracle keys
    let signature = await owsSigner.signTypedData(EIP712_DOMAIN, EIP712_TYPES, quoteValues);
    if (!signature) {
      const oracleKeys = [process.env.ORACLE_PRIVATE_KEY, process.env.ORACLE_PRIVATE_KEY_2].filter(Boolean);
      if (oracleKeys.length === 0) {
        return res.status(500).json({ error: "No ORACLE_PRIVATE_KEY configured and OWS not available" });
      }
      const signatures = [];
      for (const key of oracleKeys) {
        const wallet = new ethers.Wallet(key);
        const sig = await wallet.signTypedData(EIP712_DOMAIN, EIP712_TYPES, quoteValues);
        signatures.push(sig);
      }
      signature = signatures[0];
      for (let i = 1; i < signatures.length; i++) {
        signature += signatures[i].slice(2);
      }
    }

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
    console.error("[Quote] Unhandled error:", err);
    // Map common ethers errors to descriptive responses instead of opaque 500s
    const msg = err && (err.shortMessage || err.message) || String(err);
    const code = err && err.code;
    const isRevert = code === "CALL_EXCEPTION" || /revert|missing revert/i.test(msg);
    return res.status(200).json({
      error: isRevert ? "ON_CHAIN_REVERT" : "QUOTE_INTERNAL_ERROR",
      message: msg,
      hint: isRevert
        ? "An on-chain read reverted while preparing the quote. Common causes: vault paused, product not registered in router, oracle feed missing for the asset."
        : "Unexpected error in /quote handler. Check API logs for stack trace.",
    });
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

    // Pagination
    const page = parseInt(req.query.page) || 1;
    const limit = Math.min(parseInt(req.query.limit) || 50, 100);
    const offset = (page - 1) * limit;
    const total = policies.length;
    const paginated = policies.slice(offset, offset + limit);

    res.json({ buyer, policies: paginated, count: paginated.length, total, page, limit, hasMore: offset + limit < total });
  } catch (err) {
    console.error("Internal error:", err);
    res.status(500).json({ error: "Internal server error" });
  }
});

// POST /api/v2/renew — convenience endpoint for policy renewal
app.post("/api/v2/renew", async (req, res) => {
  try {
    const apiKey = req.headers["x-api-key"];
    if (!apiKey) return res.status(401).json({ error: "Missing X-API-Key header" });
    const keyHash = hashApiKey(apiKey);
    const keyData = apiKeys.get(keyHash);
    if (!keyData) return res.status(401).json({ error: "Invalid API key" });

    const { productId, durationSeconds } = req.body;
    if (!productId) return res.status(400).json({ error: "Missing productId (e.g. BSS, DEPEG, IL, EXPLOIT)" });

    // Find the last active policy for this wallet + product
    const wallet = keyData.wallet;
    const product = PRODUCT_CONFIG[productId];
    if (!product) return res.status(400).json({ error: "Unknown productId" });

    const shield = new ethers.Contract(product.shield, SHIELD_ABI, provider);
    let lastPolicy = null;
    const totalPolicies = Number(await shield.totalPolicies());

    for (let i = totalPolicies; i >= 1; i--) {
      try {
        const info = await shield.getPolicyInfo(i);
        if (info.insuredAgent.toLowerCase() === wallet.toLowerCase()) {
          lastPolicy = info;
          break;
        }
      } catch { continue; }
    }

    if (!lastPolicy) {
      return res.status(404).json({ error: "No existing policy found for this wallet and product. Use /purchase instead." });
    }

    // Renew = purchase same product with same coverage, optionally new duration
    const coverageAmount = Number(lastPolicy.coverageAmount);
    const duration = durationSeconds || (Number(lastPolicy.expiresAt) - Number(lastPolicy.startTimestamp));

    // Forward to purchase logic
    res.json({
      message: "Use POST /api/v2/purchase with these parameters to renew:",
      suggestedParams: {
        productId,
        coverageAmount,
        durationSeconds: duration,
      },
      note: "Premium will be recalculated based on current vault utilization (Kink Model).",
      previousPolicy: {
        policyId: Number(lastPolicy.policyId),
        coverageAmount: lastPolicy.coverageAmount.toString(),
        expiresAt: Number(lastPolicy.expiresAt),
        status: ["NONEXISTENT", "WAITING", "ACTIVE", "EXPIRED", "SETTLEMENT", "PAID_OUT", "CANCELLED"][Number(lastPolicy.status)] || "UNKNOWN",
      }
    });
  } catch (err) {
    console.error("Internal error:", err);
    res.status(500).json({ error: "Internal server error" });
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
  console.log(`  RPC: ${RPC_URL.replace(/\/v2\/.*$/, "/v2/***")}`);
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
  provider.getBalance(baseWallet.address).then(bal => {
    console.log(`[Relayer] Address: ${baseWallet.address}`);
    console.log(`[Relayer] ETH Balance: ${ethers.formatEther(bal)} ETH`);
  }).catch(() => {});

  // ═══ KEEPER: Auto-cleanup expired policies every 10 minutes ═══
  const KEEPER_INTERVAL = 10 * 60 * 1000; // 10 minutes
  const coverRouterKeeper = new ethers.Contract(
    process.env.COVER_ROUTER || COVER_ROUTER,
    [
      "function cleanupExpiredPolicy(bytes32 productId, uint256 policyId) external",
    ],
    relayerWallet
  );

  async function runKeeper() {
    try {
      console.log("[Keeper] Scanning for expired policies...");
      // Check each product's shield for expired policies
      for (const [key, entry] of Object.entries(PRODUCT_CONFIG)) {
        try {
          const shieldContract = new ethers.Contract(entry.shield, [
            "function totalPolicies() view returns (uint256)",
            "function getPolicyInfo(uint256) view returns (tuple(uint256 policyId, address insuredAgent, uint256 coverageAmount, uint256 premiumPaid, uint256 maxPayout, uint256 startTimestamp, uint256 waitingEndsAt, uint256 expiresAt, uint256 cleanupAt, uint8 status))",
          ], provider);

          const total = await shieldContract.totalPolicies();
          const now = Math.floor(Date.now() / 1000);

          for (let i = 1; i <= Number(total); i++) {
            try {
              const info = await shieldContract.getPolicyInfo(i);
              // Status 2 = ACTIVE, cleanupAt passed
              if (Number(info.status) <= 2 && Number(info.cleanupAt) > 0 && now > Number(info.cleanupAt)) {
                console.log(`[Keeper] Cleaning up policy ${i} of ${key}`);
                const productId = PRODUCT_IDS[entry.fullId];
                const tx = await coverRouterKeeper.cleanupExpiredPolicy(productId, i);
                await tx.wait();
                console.log(`[Keeper] Policy ${i} cleaned: ${tx.hash}`);
              }
            } catch (e) {
              // Skip individual policy errors
            }
          }
        } catch (e) {
          // Skip product errors
        }
      }
      console.log("[Keeper] Scan complete.");
    } catch (err) {
      console.error("[Keeper] Error:", err.message);
    }
  }

  // Run keeper after startup, then every 10 minutes
  setTimeout(runKeeper, 60 * 1000);
  setInterval(runKeeper, KEEPER_INTERVAL);
  console.log("[Keeper] Started — scanning every 10 minutes");
});
