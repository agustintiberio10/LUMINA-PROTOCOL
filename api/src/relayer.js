// api/src/relayer.js
// Lumina Relayer — auto-claim + maintenance service.
//
// Phases (run as separate scheduled loops, each isolated by try/catch):
//   1. AUTO-CLAIM      — every 60s, scan price-trigger products, build oracle proofs,
//                        staticCall triggerPayout, send tx if it would succeed.
//   2. CLEANUP         — every 60s, scan all shields for policies past cleanupAt,
//                        call cleanupExpiredPolicy to release locked collateral.
//   3. EXECUTE PENDING — every 60s, look at PayoutScheduled events from the last
//                        7 days, attempt executeScheduledPayout for any whose
//                        executeAfter has passed.
//   4. MONITOR VAULTS  — every 5 min, snapshot totalAssets/utilization for each
//                        vault. Warn at >90%, critical at >95%.
//
// All loops are best-effort. Per-policy/per-product errors are swallowed (most
// will be "TriggerNotMet" reverts which are normal). Phase-level errors land
// in state.errors so /api/v2/relayer/status surfaces them.

const { ethers } = require("ethers");

// ─── Constants ──────────────────────────────────────────────────────────────

const TICK_INTERVAL_MS = 60 * 1000;       // phases 1-3
const VAULT_TICK_INTERVAL_MS = 5 * 60 * 1000; // phase 4
// Each tick scans LOG_CHUNK_BLOCKS * LOG_MAX_CHUNKS blocks of new logs.
// Base L2 ~2s blocks, 6 chunks × 10 blocks = 120s of coverage per tick — safely
// larger than the 60s tick interval. We persist the last scanned block across
// ticks so we don't miss anything when the gap grows after restarts.
const LOG_CHUNK_BLOCKS = 10;                  // free-tier RPC ceiling
const LOG_MAX_CHUNKS_PER_TICK = 6;
const RPC_GAP_MS = 150;                       // small gap between sequential reads
const MAX_ERRORS = 20;                        // bounded ring buffer

// Status enum (mirrors IShield.PolicyStatus)
//   0 NONEXISTENT, 1 WAITING, 2 ACTIVE, 3 SETTLEMENT, 4 EXPIRED, 5 PAID_OUT
const STATUS = { NONEXISTENT: 0, WAITING: 1, ACTIVE: 2, SETTLEMENT: 3, EXPIRED: 4, PAID_OUT: 5 };

// Products that use the standard price-proof shape:
//   abi.encode(int256 verifiedPrice, bytes32 asset, uint256 verifiedAt, bytes signature)
// EXPLOIT-001 has a different proof shape and is intentionally excluded.
const PRICE_PRODUCTS = new Set([
  "BTCCAT-001", "ETHAPOC-001", "DEPEG-STABLE-001", "ILPROT-001", "BLACKSWAN-001",
]);

// ─── ABIs ───────────────────────────────────────────────────────────────────

const SHIELD_ABI = [
  "function totalPolicies() view returns (uint256)",
  "function activePolicies() view returns (uint256)",
  "function getPolicyInfo(uint256) view returns (tuple(uint256 policyId, address insuredAgent, uint256 coverageAmount, uint256 premiumPaid, uint256 maxPayout, uint256 startTimestamp, uint256 waitingEndsAt, uint256 expiresAt, uint256 cleanupAt, uint8 status))",
  "function oracle() view returns (address)",
];

const ROUTER_ABI = [
  "function triggerPayout(bytes32 productId, uint256 policyId, bytes oracleProof) external",
  "function cleanupExpiredPolicy(bytes32 productId, uint256 policyId) external",
  "function executeScheduledPayout(bytes32 payoutId) external",
  "function scheduledPayouts(bytes32) view returns (address beneficiary, uint256 amount, uint256 executeAfter, bool cancelled, bool executed, bytes32 productId, uint256 policyId, address vault, uint256 coverageAmount)",
  "function oracle() view returns (address)",
  "event PayoutScheduled(bytes32 indexed payoutId, address indexed beneficiary, uint256 amount, uint256 executeAfter)",
];

const ORACLE_ABI = [
  "function getLatestPrice(bytes32 asset) view returns (int256)",
  "function oracleKey() view returns (address)",
];

const VAULT_ABI = [
  "function totalAssets() view returns (uint256)",
  "function allocatedAssets() view returns (uint256)",
  "function utilizationBps() view returns (uint256)",
];

// ─── State ──────────────────────────────────────────────────────────────────

const state = {
  running: false,
  startedAt: null,
  ticks: 0,
  vaultTicks: 0,
  lastTickAt: null,
  lastVaultTickAt: null,
  errors: [], // ring buffer of recent phase-level errors
  phases: {
    autoClaim:     { runs: 0, payoutsTriggered: 0, lastError: null, lastErrorAt: null },
    cleanup:       { runs: 0, policiesCleaned: 0, lastError: null, lastErrorAt: null },
    executePending:{ runs: 0, payoutsExecuted: 0, lastError: null, lastErrorAt: null },
    monitorVaults: { runs: 0, lastSnapshot: null, warnings: [], lastError: null, lastErrorAt: null },
  },
  relayer: { address: null, ethBalance: null },
  oracle:  { address: null, oracleKey: null },
};

let _ctx = null;
let _timer = null;
let _vaultTimer = null;
let _initialTimers = [];
let _lastScannedBlock = null; // for phase 3 PayoutScheduled scanner

// ─── Helpers ────────────────────────────────────────────────────────────────

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function pushError(phase, err) {
  const entry = { phase, message: err.message || String(err), at: new Date().toISOString() };
  state.errors.unshift(entry);
  if (state.errors.length > MAX_ERRORS) state.errors.length = MAX_ERRORS;
  state.phases[phase].lastError = entry.message;
  state.phases[phase].lastErrorAt = entry.at;
}

function clearPhaseError(phase) {
  state.phases[phase].lastError = null;
  state.phases[phase].lastErrorAt = null;
}

// Base mainnet chain id — hardcoded (do not read from provider each tick).
// LuminaOracleV2 binds its EIP-712 domain to chainId=8453.
const LUMINA_ORACLE_CHAIN_ID = 8453;

// EIP-712 types for LuminaOracleV2 PriceProof.
const PRICE_PROOF_TYPES = {
  PriceProof: [
    { name: "price",      type: "int256"  },
    { name: "asset",      type: "bytes32" },
    { name: "verifiedAt", type: "uint256" },
  ],
};

// Build the standard oracle proof bytes used by BCS/EAS/DEPEG/IL/BSS shields:
//   abi.encode(int256 verifiedPrice, bytes32 asset, uint256 verifiedAt, bytes signature)
// The signature is EIP-712 domain-separated typed-data (LuminaOracleV2 PriceProof):
// chainId + verifyingContract are baked into the digest, preventing cross-chain
// and cross-contract replay. The on-chain proof byte-shape is unchanged.
async function buildPriceProof(verifiedPrice, assetBytes32, verifiedAt) {
  // EIP-712 signing for LuminaOracleV2: cross-chain and cross-contract replay are
  // prevented by chainId + verifyingContract being part of the digest.
  if (!state.oracle.address) {
    throw new Error("buildPriceProof: state.oracle.address not set — relayer.start() must run first");
  }

  const domain = {
    name: "LuminaOracle",
    version: "2",
    chainId: LUMINA_ORACLE_CHAIN_ID,
    verifyingContract: state.oracle.address,
  };
  const value = {
    price: verifiedPrice,
    asset: assetBytes32,
    verifiedAt,
  };

  // Sign — prefer OWS (typed-data path), fall back to local ORACLE_PRIVATE_KEY(s).
  // Multi-sig packed signatures are concatenated in ascending signer-address order.
  let signature = null;
  if (_ctx.owsSigner && typeof _ctx.owsSigner.signTypedData === "function") {
    try { signature = await _ctx.owsSigner.signTypedData(domain, PRICE_PROOF_TYPES, value); }
    catch { /* fall through to local signing */ }
  }
  if (!signature) {
    const keys = [process.env.ORACLE_PRIVATE_KEY, process.env.ORACLE_PRIVATE_KEY_2].filter(Boolean);
    if (keys.length === 0) throw new Error("No ORACLE_PRIVATE_KEY configured");
    const wallets = keys.map((k) => new ethers.Wallet(k));
    // Sort by address ascending (LuminaOracle.verifyPackedMultisig requires this)
    wallets.sort((a, b) => (BigInt(a.address) < BigInt(b.address) ? -1 : 1));
    const sigs = [];
    for (const w of wallets) {
      // ethers v6: Wallet.signTypedData(domain, types, value)
      const sig = await w.signTypedData(domain, PRICE_PROOF_TYPES, value);
      sigs.push(sig);
    }
    signature = sigs[0];
    for (let i = 1; i < sigs.length; i++) signature += sigs[i].slice(2);
  }

  return ethers.AbiCoder.defaultAbiCoder().encode(
    ["int256", "bytes32", "uint256", "bytes"],
    [verifiedPrice, assetBytes32, verifiedAt, signature]
  );
}

// ─── PHASE 1 — AUTO-CLAIM ───────────────────────────────────────────────────

async function runAutoClaim() {
  const phase = state.phases.autoClaim;
  phase.runs++;
  try {
    const router = new ethers.Contract(_ctx.coverRouter, ROUTER_ABI, _ctx.relayerWallet);
    const oracle = new ethers.Contract(state.oracle.address, ORACLE_ABI, _ctx.provider);

    for (const product of _ctx.products) {
      if (!PRICE_PRODUCTS.has(product.id)) continue;
      if (!product.asset) continue;
      if (!product.shield || product.shield === ethers.ZeroAddress) continue;

      const shield = new ethers.Contract(product.shield, SHIELD_ABI, _ctx.provider);

      let totalRaw;
      try { totalRaw = await shield.totalPolicies(); }
      catch { continue; }
      const total = Number(totalRaw);
      if (total === 0) continue;
      await sleep(RPC_GAP_MS);

      // Read current price for this product's asset (will revert if sequencer
      // is in grace period or feed isn't registered — that's a normal skip).
      const assetBytes32 = ethers.encodeBytes32String(product.asset);
      let currentPrice;
      try { currentPrice = await oracle.getLatestPrice(assetBytes32); }
      catch { continue; }
      await sleep(RPC_GAP_MS);

      const productIdHash = product.productId;

      for (let pid = 1; pid <= total; pid++) {
        try {
          const info = await shield.getPolicyInfo(pid);
          const status = Number(info.status);
          if (status !== STATUS.ACTIVE && status !== STATUS.SETTLEMENT) continue;

          // Build a fresh proof signed at "now" using the current Chainlink price.
          // The shield will reject the proof if (a) verifiedAt < waitingEndsAt,
          // (b) verifiedAt > expiresAt, (c) price is above the trigger threshold,
          // or (d) the policy is already resolved. Use staticCall as the filter.
          const verifiedAt = Math.floor(Date.now() / 1000);
          const proof = await buildPriceProof(currentPrice, assetBytes32, verifiedAt);

          try {
            await router.triggerPayout.staticCall(productIdHash, pid, proof);
          } catch {
            continue; // most policies — trigger not met, expected
          }

          const tx = await router.triggerPayout(productIdHash, pid, proof);
          const receipt = await tx.wait();
          phase.payoutsTriggered++;
          console.log(`[Relayer/AutoClaim] ${product.id} #${pid} → tx ${receipt.hash}`);
        } catch (e) {
          // policy-level error — swallow
        }
        await sleep(RPC_GAP_MS);
      }
    }
    clearPhaseError("autoClaim");
  } catch (e) {
    pushError("autoClaim", e);
    console.error("[Relayer/AutoClaim] phase error:", e.message);
  }
}

// ─── PHASE 2 — CLEANUP EXPIRED POLICIES ─────────────────────────────────────

async function runCleanup() {
  const phase = state.phases.cleanup;
  phase.runs++;
  try {
    const router = new ethers.Contract(_ctx.coverRouter, ROUTER_ABI, _ctx.relayerWallet);
    const now = Math.floor(Date.now() / 1000);

    for (const product of _ctx.products) {
      if (!product.shield || product.shield === ethers.ZeroAddress) continue;
      const shield = new ethers.Contract(product.shield, SHIELD_ABI, _ctx.provider);

      let totalRaw;
      try { totalRaw = await shield.totalPolicies(); }
      catch { continue; }
      const total = Number(totalRaw);
      if (total === 0) continue;
      await sleep(RPC_GAP_MS);

      for (let pid = 1; pid <= total; pid++) {
        try {
          const info = await shield.getPolicyInfo(pid);
          const status = Number(info.status);
          // ACTIVE/SETTLEMENT/EXPIRED + cleanupAt passed → eligible
          if (status > STATUS.EXPIRED) continue; // PAID_OUT
          const cleanupAt = Number(info.cleanupAt);
          if (cleanupAt === 0 || now <= cleanupAt) continue;

          try {
            await router.cleanupExpiredPolicy.staticCall(product.productId, pid);
          } catch {
            continue;
          }
          const tx = await router.cleanupExpiredPolicy(product.productId, pid);
          const receipt = await tx.wait();
          phase.policiesCleaned++;
          console.log(`[Relayer/Cleanup] ${product.id} #${pid} → tx ${receipt.hash}`);
        } catch (e) {
          // swallow per-policy errors
        }
        await sleep(RPC_GAP_MS);
      }
    }
    clearPhaseError("cleanup");
  } catch (e) {
    pushError("cleanup", e);
    console.error("[Relayer/Cleanup] phase error:", e.message);
  }
}

// ─── PHASE 3 — EXECUTE PENDING SCHEDULED PAYOUTS ────────────────────────────

async function runExecutePending() {
  const phase = state.phases.executePending;
  phase.runs++;
  try {
    const router = new ethers.Contract(_ctx.coverRouter, ROUTER_ABI, _ctx.relayerWallet);
    const head = await _ctx.provider.getBlockNumber();
    // Default starting point: just the last 60 blocks (~2 min) on first run.
    // Subsequent ticks resume from _lastScannedBlock so no events are missed.
    const maxTickWindow = LOG_CHUNK_BLOCKS * LOG_MAX_CHUNKS_PER_TICK;
    if (_lastScannedBlock === null) _lastScannedBlock = Math.max(0, head - maxTickWindow);
    let cursor = _lastScannedBlock + 1;
    if (cursor > head) cursor = head;
    // Bound the per-tick scan: at most LOG_MAX_CHUNKS_PER_TICK chunks
    const stopAt = Math.min(head, cursor + maxTickWindow - 1);

    const events = [];
    while (cursor <= stopAt) {
      const chunkEnd = Math.min(stopAt, cursor + LOG_CHUNK_BLOCKS - 1);
      try {
        const chunk = await router.queryFilter(router.filters.PayoutScheduled(), cursor, chunkEnd);
        for (const ev of chunk) events.push(ev);
      } catch (e) {
        // RPC error on this chunk — break, retry the same range next tick
        break;
      }
      _lastScannedBlock = chunkEnd;
      cursor = chunkEnd + 1;
      await sleep(RPC_GAP_MS);
    }

    const now = Math.floor(Date.now() / 1000);
    for (const ev of events) {
      const payoutId = ev.args.payoutId;
      const executeAfter = Number(ev.args.executeAfter);
      if (now < executeAfter) continue;

      try {
        const sp = await router.scheduledPayouts(payoutId);
        if (sp.executed || sp.cancelled) continue;
        if (Number(sp.executeAfter) === 0) continue;
        await router.executeScheduledPayout.staticCall(payoutId);
        const tx = await router.executeScheduledPayout(payoutId);
        const receipt = await tx.wait();
        phase.payoutsExecuted++;
        console.log(`[Relayer/ExecutePending] ${payoutId} → tx ${receipt.hash}`);
      } catch (e) {
        // swallow per-payout errors
      }
      await sleep(RPC_GAP_MS);
    }
    clearPhaseError("executePending");
  } catch (e) {
    pushError("executePending", e);
    console.error("[Relayer/ExecutePending] phase error:", e.message);
  }
}

// ─── PHASE 4 — MONITOR VAULTS ───────────────────────────────────────────────

async function runMonitorVaults() {
  const phase = state.phases.monitorVaults;
  phase.runs++;
  try {
    const snapshot = [];
    const warnings = [];
    for (const [name, address] of Object.entries(_ctx.vaults)) {
      try {
        const v = new ethers.Contract(address, VAULT_ABI, _ctx.provider);
        const totalAssets = await v.totalAssets();
        await sleep(RPC_GAP_MS);
        const allocated = await v.allocatedAssets();
        await sleep(RPC_GAP_MS);
        const utilBps = Number(await v.utilizationBps());
        const utilPct = utilBps / 100;
        const entry = {
          name,
          address,
          totalAssetsUSDC: Number(totalAssets) / 1e6,
          allocatedUSDC: Number(allocated) / 1e6,
          utilizationPct: utilPct,
        };
        snapshot.push(entry);
        if (utilPct >= 95) warnings.push({ level: "CRITICAL", vault: name, util: utilPct });
        else if (utilPct >= 90) warnings.push({ level: "WARN", vault: name, util: utilPct });
      } catch (e) {
        snapshot.push({ name, address, error: e.message });
      }
      await sleep(RPC_GAP_MS);
    }
    phase.lastSnapshot = { at: new Date().toISOString(), vaults: snapshot };
    phase.warnings = warnings;
    if (warnings.length > 0) {
      console.warn(`[Relayer/MonitorVaults] ${warnings.length} warning(s):`,
        warnings.map((w) => `${w.level} ${w.vault}=${w.util.toFixed(1)}%`).join(", "));
    }
    clearPhaseError("monitorVaults");
  } catch (e) {
    pushError("monitorVaults", e);
    console.error("[Relayer/MonitorVaults] phase error:", e.message);
  }
}

// ─── Tick orchestration ─────────────────────────────────────────────────────

async function tick() {
  if (!state.running) return;
  state.lastTickAt = new Date().toISOString();
  state.ticks++;
  try {
    const bal = await _ctx.provider.getBalance(state.relayer.address);
    state.relayer.ethBalance = ethers.formatEther(bal);
  } catch { /* ignore */ }
  await runAutoClaim();
  await runCleanup();
  await runExecutePending();
}

async function vaultTick() {
  if (!state.running) return;
  state.lastVaultTickAt = new Date().toISOString();
  state.vaultTicks++;
  await runMonitorVaults();
}

// ─── Lifecycle ──────────────────────────────────────────────────────────────

async function start(ctx) {
  if (state.running) return;
  if (!ctx || !ctx.provider || !ctx.relayerWallet || !ctx.coverRouter) {
    throw new Error("relayer.start: missing ctx fields");
  }
  _ctx = ctx;
  state.running = true;
  state.startedAt = new Date().toISOString();
  state.relayer.address = ctx.relayerWallet.address || (ctx.baseWallet && ctx.baseWallet.address) || null;

  // Resolve oracle address from CoverRouter (single source of truth)
  try {
    const router = new ethers.Contract(ctx.coverRouter, ROUTER_ABI, ctx.provider);
    state.oracle.address = await router.oracle();
    const oracle = new ethers.Contract(state.oracle.address, ORACLE_ABI, ctx.provider);
    state.oracle.oracleKey = await oracle.oracleKey();
  } catch (e) {
    console.error("[Relayer] Could not resolve oracle address:", e.message);
  }

  console.log("[Relayer] Started");
  console.log(`[Relayer]   address:    ${state.relayer.address}`);
  console.log(`[Relayer]   oracle:     ${state.oracle.address}`);
  console.log(`[Relayer]   oracleKey:  ${state.oracle.oracleKey}`);
  console.log(`[Relayer]   tick:       every ${TICK_INTERVAL_MS / 1000}s (auto-claim + cleanup + execute pending)`);
  console.log(`[Relayer]   vault tick: every ${VAULT_TICK_INTERVAL_MS / 1000}s (monitor vaults)`);

  // Stagger initial runs so we don't hammer RPC at startup
  _initialTimers.push(setTimeout(() => { tick().catch(() => {}); }, 5_000));
  _initialTimers.push(setTimeout(() => { vaultTick().catch(() => {}); }, 15_000));

  _timer = setInterval(() => { tick().catch(() => {}); }, TICK_INTERVAL_MS);
  _vaultTimer = setInterval(() => { vaultTick().catch(() => {}); }, VAULT_TICK_INTERVAL_MS);
}

function stop() {
  state.running = false;
  if (_timer) clearInterval(_timer);
  if (_vaultTimer) clearInterval(_vaultTimer);
  for (const t of _initialTimers) clearTimeout(t);
  _timer = null;
  _vaultTimer = null;
  _initialTimers = [];
  _lastScannedBlock = null;
}

function getState() {
  return {
    running: state.running,
    startedAt: state.startedAt,
    uptimeSec: state.startedAt ? Math.floor((Date.now() - new Date(state.startedAt).getTime()) / 1000) : 0,
    ticks: state.ticks,
    vaultTicks: state.vaultTicks,
    lastTickAt: state.lastTickAt,
    lastVaultTickAt: state.lastVaultTickAt,
    relayer: state.relayer,
    oracle: state.oracle,
    phases: state.phases,
    lastScannedBlock: _lastScannedBlock,
    recentErrors: state.errors,
  };
}

module.exports = { start, stop, getState };
