// Read-only JSON-RPC audit script
const https = require('https');
const crypto = require('crypto');

// Keccak256 via noble hashes? Not installed. Use manual implementation.
// Pure JS keccak256 - minimal.
function keccak256(msgBytes) {
  // Implementation of Keccak-f[1600]
  const RC = [
    0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
    0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
    0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
    0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
    0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
    0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
  ];
  const r = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
  ];
  const MASK = (1n << 64n) - 1n;
  function rol(x, n) {
    n = BigInt(n);
    return ((x << n) | (x >> (64n - n))) & MASK;
  }
  function f(st) {
    for (let rnd = 0; rnd < 24; rnd++) {
      // theta
      const C = new Array(5);
      for (let x = 0; x < 5; x++) {
        C[x] = st[x][0] ^ st[x][1] ^ st[x][2] ^ st[x][3] ^ st[x][4];
      }
      const D = new Array(5);
      for (let x = 0; x < 5; x++) {
        D[x] = C[(x + 4) % 5] ^ rol(C[(x + 1) % 5], 1);
      }
      for (let x = 0; x < 5; x++)
        for (let y = 0; y < 5; y++)
          st[x][y] ^= D[x];
      // rho + pi
      const B = [[0n,0n,0n,0n,0n],[0n,0n,0n,0n,0n],[0n,0n,0n,0n,0n],[0n,0n,0n,0n,0n],[0n,0n,0n,0n,0n]];
      for (let x = 0; x < 5; x++)
        for (let y = 0; y < 5; y++)
          B[y][(2 * x + 3 * y) % 5] = rol(st[x][y], r[x][y]);
      // chi
      for (let x = 0; x < 5; x++)
        for (let y = 0; y < 5; y++)
          st[x][y] = (B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y])) & MASK;
      // iota
      st[0][0] ^= RC[rnd];
    }
    return st;
  }
  const rate = 136;
  const msg = Buffer.from(msgBytes);
  const padLen = rate - (msg.length % rate);
  const padded = Buffer.alloc(msg.length + padLen);
  msg.copy(padded, 0);
  padded[msg.length] = 0x01;
  padded[padded.length - 1] |= 0x80;

  const state = [[0n,0n,0n,0n,0n],[0n,0n,0n,0n,0n],[0n,0n,0n,0n,0n],[0n,0n,0n,0n,0n],[0n,0n,0n,0n,0n]];
  for (let off = 0; off < padded.length; off += rate) {
    const chunk = padded.subarray(off, off + rate);
    for (let i = 0; i < rate / 8; i++) {
      let lane = 0n;
      for (let b = 0; b < 8; b++) {
        lane |= BigInt(chunk[i * 8 + b]) << BigInt(8 * b);
      }
      const x = i % 5;
      const y = Math.floor(i / 5);
      state[x][y] ^= lane;
    }
    f(state);
  }
  // Squeeze 32 bytes
  const out = Buffer.alloc(32);
  let p = 0;
  for (let y = 0; y < 5 && p < 32; y++) {
    for (let x = 0; x < 5 && p < 32; x++) {
      let lane = state[x][y];
      for (let b = 0; b < 8 && p < 32; b++) {
        out[p++] = Number((lane >> BigInt(8 * b)) & 0xffn);
      }
    }
  }
  return out;
}

function sel(sig) { return '0x' + keccak256(Buffer.from(sig)).toString('hex').slice(0, 8); }
function kecText(s) { return '0x' + keccak256(Buffer.from(s)).toString('hex'); }
function b32String(s) {
  const b = Buffer.from(s);
  const out = Buffer.alloc(32);
  b.copy(out, 0);
  return '0x' + out.toString('hex');
}
function pad32(hex) { return hex.replace('0x','').padStart(64, '0'); }

function rpcRaw(method, params) {
  const body = JSON.stringify({ jsonrpc: '2.0', method, params, id: 1 });
  return new Promise((resolve, reject) => {
    const req = https.request('https://mainnet.base.org', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => resolve(d));
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}
function rpc(to, data) {
  const body = JSON.stringify({ jsonrpc: '2.0', method: 'eth_call', params: [{ to, data }, 'latest'], id: 1 });
  return new Promise((resolve, reject) => {
    const req = https.request('https://mainnet.base.org', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => resolve(d));
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function sleep(ms){return new Promise(r=>setTimeout(r,ms));}
async function call(to, sig, args = '') {
  const data = sel(sig) + args;
  for (let attempt = 0; attempt < 6; attempt++) {
    const r = await rpc(to, data);
    if (!r.includes('over rate limit')) return r;
    await sleep(1500 * (attempt + 1));
  }
  return await rpc(to, data);
}

const ORACLE = '0x87B576f688bE0E1d7d23A299f55b475658215105';
const ROUTER = '0xd5f8678A0F2149B6342F9014CCe6d743234Ca025';
const POLICYMGR = '0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a';
const VAULTS = {
  VolatileShort: '0xbd44AbDD61a2A6EeA98935f7a66f98fB49FA1C0a',
  VolatileLong:  '0xFee5eE6D81c1E3D9Ea2106cE05Ca12bEa2BE88c5',
  StableShort:   '0x429bd85D8CfB3B3B34e0A29b7DE07e62EA7C16F4',
  StableLong:    '0x17781f3A01f6b5C5099D32e65CFaf08a4f1cC6Ce',
};

(async () => {
  console.log('# Selector self-test');
  console.log('owner() =', sel('owner()'));
  console.log('totalAssets() =', sel('totalAssets()'));
  console.log('DOMAIN_SEPARATOR() =', sel('DOMAIN_SEPARATOR()'));

  console.log('\n=== 1.2.1 ORACLE.DOMAIN_SEPARATOR() ===');
  console.log(await call(ORACLE, 'DOMAIN_SEPARATOR()'));

  console.log('\n=== 1.2.4 ORACLE state ===');
  console.log('oracleKey():', await call(ORACLE, 'oracleKey()'));
  console.log('requiredSignatures():', await call(ORACLE, 'requiredSignatures()'));
  console.log('totalSigners():', await call(ORACLE, 'totalSigners()'));
  console.log('owner():', await call(ORACLE, 'owner()'));

  console.log('\n=== 1.2.7 Sequencer ===');
  console.log('sequencerUptimeFeed():', await call(ORACLE, 'sequencerUptimeFeed()'));
  console.log('SEQUENCER_GRACE_PERIOD():', await call(ORACLE, 'SEQUENCER_GRACE_PERIOD()'));

  console.log('\n=== 1.2.5 getFeedConfig per asset ===');
  const assets = ['BTC', 'ETH', 'USDC', 'USDT', 'DAI'];
  const feedMap = {};
  for (const a of assets) {
    const arg = pad32(b32String(a));
    const res = await call(ORACLE, 'getFeedConfig(bytes32)', arg);
    console.log(`asset=${a} bytes32=${b32String(a)}`);
    console.log('  result:', res);
    try {
      const parsed = JSON.parse(res);
      if (parsed.result && parsed.result.length >= 2 + 64*3) {
        const hx = parsed.result.slice(2);
        const feed = '0x' + hx.slice(24, 64);
        const stale = BigInt('0x' + hx.slice(64, 128));
        const active = BigInt('0x' + hx.slice(128, 192));
        feedMap[a] = { feed, stale, active };
        console.log(`  parsed: feed=${feed} maxStaleness=${stale}s active=${active}`);
      }
    } catch(e) {}
  }

  console.log('\n=== 1.2.5 Feed metadata ===');
  for (const [a, {feed, active}] of Object.entries(feedMap)) {
    if (active === 0n || BigInt(feed) === 0n) continue;
    console.log(`\n--- ${a} feed ${feed} ---`);
    console.log('description():', await call(feed, 'description()'));
    console.log('decimals():', await call(feed, 'decimals()'));
    console.log('latestRoundData():', await call(feed, 'latestRoundData()'));
  }

  console.log('\n=== 1.3.1 Router.oracle() ===');
  console.log(await call(ROUTER, 'oracle()'));

  console.log('\n=== 1.3.2 getProductShield per productId ===');
  const pids = ['BTCCAT-001','ETHAPOC-001','DEPEG-STABLE-001','ILPROT-001','EXPLOIT-001'];
  for (const p of pids) {
    const h = kecText(p);
    const arg = pad32(h);
    console.log(`pid=${p} keccak=${h}`);
    console.log('  result:', await call(ROUTER, 'getProductShield(bytes32)', arg));
  }

  console.log('\n=== 1.3.3 Router circuit breakers ===');
  console.log('maxPayoutsPerDay():', await call(ROUTER, 'maxPayoutsPerDay()'));
  console.log('largePayoutThreshold():', await call(ROUTER, 'largePayoutThreshold()'));
  console.log('largePayoutDelay():', await call(ROUTER, 'largePayoutDelay()'));
  console.log('owner():', await call(ROUTER, 'owner()'));
  console.log('maxPayoutsPerDay selector:', sel('maxPayoutsPerDay()'));

  console.log('\n=== 1.3.6 PolicyManager.getCorrelationGroup(VOLATILE_CRASH) ===');
  const h = kecText('VOLATILE_CRASH');
  const arg = pad32(h);
  console.log('keccak=', h);
  console.log(await call(POLICYMGR, 'getCorrelationGroup(bytes32)', arg));

  console.log('\n=== 1.4 VAULTS ===');
  for (const [name, addr] of Object.entries(VAULTS)) {
    console.log(`\n--- ${name} @ ${addr} ---`);
    console.log('totalAssets():', await call(addr, 'totalAssets()'));
    console.log('owner():', await call(addr, 'owner()'));
    console.log('asset():', await call(addr, 'asset()'));
    console.log('paused():', await call(addr, 'paused()'));
    console.log('cooldownDuration():', await call(addr, 'cooldownDuration()'));
    console.log('aavePool():', await call(addr, 'aavePool()'));
    console.log('aToken():', await call(addr, 'aToken()'));
  }
  console.log('\n=== DONE ===');
})().catch(e => { console.error('ERR', e); process.exit(1); });
