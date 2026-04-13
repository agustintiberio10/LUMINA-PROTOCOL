#!/usr/bin/env python
"""Audit script: compute selectors and perform eth_calls via urllib."""
import json
import sys
import urllib.request

# Keccak256 via pycryptodome if available, else fallback
try:
    from Crypto.Hash import keccak
    def kec(data: bytes) -> bytes:
        k = keccak.new(digest_bits=256)
        k.update(data)
        return k.digest()
except ImportError:
    # Pure python keccak256
    def kec(data: bytes) -> bytes:
        # SHA3 standard vs Keccak - use sha3 module / hashlib if keccak
        # Python's hashlib has sha3_256 (NIST), not keccak. Need custom.
        return _keccak256(data)

def _keccak256(msg: bytes) -> bytes:
    # Minimal Keccak-f[1600] implementation
    RC = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    r = [
        [0, 36, 3, 41, 18],
        [1, 44, 10, 45, 2],
        [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56],
        [27, 20, 39, 8, 14],
    ]
    def rol(x, n):
        return ((x << n) | (x >> (64 - n))) & ((1 << 64) - 1)

    def keccak_f(st):
        for rnd in range(24):
            # theta
            C = [st[x][0] ^ st[x][1] ^ st[x][2] ^ st[x][3] ^ st[x][4] for x in range(5)]
            D = [C[(x - 1) % 5] ^ rol(C[(x + 1) % 5], 1) for x in range(5)]
            for x in range(5):
                for y in range(5):
                    st[x][y] ^= D[x]
            # rho + pi
            B = [[0]*5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    B[y][(2 * x + 3 * y) % 5] = rol(st[x][y], r[x][y])
            # chi
            for x in range(5):
                for y in range(5):
                    st[x][y] = B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y]) & ((1 << 64) - 1)
            # iota
            st[0][0] ^= RC[rnd]
        return st

    rate = 136  # 1088 bits
    # pad
    msg = bytearray(msg)
    msg.append(0x01)  # keccak pad
    while len(msg) % rate != 0:
        msg.append(0x00)
    msg[-1] |= 0x80

    state = [[0]*5 for _ in range(5)]
    for chunk_start in range(0, len(msg), rate):
        chunk = msg[chunk_start:chunk_start + rate]
        for i in range(rate // 8):
            lane = int.from_bytes(chunk[i*8:(i+1)*8], 'little')
            x = i % 5
            y = i // 5
            state[x][y] ^= lane
        state = keccak_f(state)

    out = bytearray()
    for y in range(5):
        for x in range(5):
            if len(out) >= 32:
                break
            out += state[x][y].to_bytes(8, 'little')
    return bytes(out[:32])

def sel(sig: str) -> str:
    return '0x' + kec(sig.encode()).hex()[:8]

def kec_text(s: str) -> str:
    return '0x' + kec(s.encode()).hex()

def b32(s: str) -> str:
    b = s.encode()
    return '0x' + b.hex() + '00' * (32 - len(b))

def eth_call(to: str, data: str):
    req = {
        "jsonrpc": "2.0",
        "method": "eth_call",
        "params": [{"to": to, "data": data}, "latest"],
        "id": 1,
    }
    body = json.dumps(req).encode()
    r = urllib.request.Request(
        "https://mainnet.base.org",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read())

def call(to, sig, args_encoded=""):
    data = sel(sig) + args_encoded
    res = eth_call(to, data)
    return res

def pad32(hexstr):
    hexstr = hexstr.replace("0x", "")
    return hexstr.rjust(64, '0')

ORACLE = "0x87B576f688bE0E1d7d23A299f55b475658215105"
ROUTER = "0xd5f8678A0F2149B6342F9014CCe6d743234Ca025"
POLICYMGR = "0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a"
VAULTS = {
    "VolatileShort": "0xbd44AbDD61a2A6EeA98935f7a66f98fB49FA1C0a",
    "VolatileLong":  "0xFee5eE6D81c1E3D9Ea2106cE05Ca12bEa2BE88c5",
    "StableShort":   "0x429bd85D8CfB3B3B34e0A29b7DE07e62EA7C16F4",
    "StableLong":    "0x17781f3A01f6b5C5099D32e65CFaf08a4f1cC6Ce",
}

def log(s):
    print(s, flush=True)

log("# Selector sanity check")
log("DOMAIN_SEPARATOR()        = " + sel("DOMAIN_SEPARATOR()"))
log("oracleKey()               = " + sel("oracleKey()"))
log("owner()                   = " + sel("owner()"))

# === ORACLE ===
log("\n=== 1.2.1 DOMAIN_SEPARATOR (on-chain) ===")
log(json.dumps(call(ORACLE, "DOMAIN_SEPARATOR()")))

log("\n=== 1.2.4 oracleKey() ===")
log(json.dumps(call(ORACLE, "oracleKey()")))
log("\n=== 1.2.4 requiredSignatures() ===")
log(json.dumps(call(ORACLE, "requiredSignatures()")))
log("\n=== 1.2.4 totalSigners() ===")
log(json.dumps(call(ORACLE, "totalSigners()")))
log("\n=== 1.2.4 owner() ===")
log(json.dumps(call(ORACLE, "owner()")))
log("\n=== 1.2.7 sequencerUptimeFeed() ===")
log(json.dumps(call(ORACLE, "sequencerUptimeFeed()")))
log("\n=== 1.2.7 SEQUENCER_GRACE_PERIOD() ===")
log(json.dumps(call(ORACLE, "SEQUENCER_GRACE_PERIOD()")))

# === Feed Config per asset ===
log("\n=== 1.2.5 getFeedConfig per asset ===")
assets = ["BTC", "ETH", "USDC", "USDT", "DAI"]
feed_results = {}
for a in assets:
    arg = pad32(b32(a))
    r = call(ORACLE, "getFeedConfig(bytes32)", arg)
    log(f"asset={a} bytes32={b32(a)}")
    log(json.dumps(r))
    feed_results[a] = r

# Parse feed addr from each, and query feed directly
log("\n=== 1.2.5 Feed metadata ===")
parsed_feeds = {}
for a, r in feed_results.items():
    raw = r.get("result", "")
    if raw and len(raw) >= 2 + 64 * 3:
        hx = raw[2:]
        feed_addr = "0x" + hx[24:64]
        max_stale = int(hx[64:128], 16)
        active = int(hx[128:192], 16)
        parsed_feeds[a] = (feed_addr, max_stale, active)
        log(f"{a}: feed={feed_addr} maxStaleness={max_stale}s active={active}")

for a, (fa, _, active) in parsed_feeds.items():
    if active == 0 or int(fa, 16) == 0:
        continue
    log(f"\n--- {a} feed {fa} ---")
    log("description: " + json.dumps(call(fa, "description()")))
    log("decimals:    " + json.dumps(call(fa, "decimals()")))
    log("latestRoundData: " + json.dumps(call(fa, "latestRoundData()")))

# === ROUTER ===
log("\n=== 1.3.1 CoverRouter.oracle() ===")
log(json.dumps(call(ROUTER, "oracle()")))

log("\n=== 1.3.2 getProductShield per productId ===")
pids = ["BTCCAT-001","ETHAPOC-001","DEPEG-STABLE-001","ILPROT-001","EXPLOIT-001"]
for p in pids:
    h = kec_text(p)
    arg = pad32(h)
    r = call(ROUTER, "getProductShield(bytes32)", arg)
    log(f"productId={p} keccak={h}")
    log(json.dumps(r))

log("\n=== 1.3.3 Router circuit breakers ===")
log("maxPayoutsPerDay: " + json.dumps(call(ROUTER, "maxPayoutsPerDay()")))
log("largePayoutThreshold: " + json.dumps(call(ROUTER, "largePayoutThreshold()")))
log("largePayoutDelay: " + json.dumps(call(ROUTER, "largePayoutDelay()")))

log("\n=== 1.3.6 PolicyManager.getCorrelationGroup(VOLATILE_CRASH) ===")
h = kec_text("VOLATILE_CRASH")
arg = pad32(h)
log(f"keccak(VOLATILE_CRASH)={h}")
try:
    log(json.dumps(call(POLICYMGR, "getCorrelationGroup(bytes32)", arg)))
except Exception as e:
    log("err: " + str(e))

# === VAULTS ===
log("\n=== 1.4 VAULT STATE ===")
for name, addr in VAULTS.items():
    log(f"\n--- {name} @ {addr} ---")
    log("totalAssets: " + json.dumps(call(addr, "totalAssets()")))
    log("owner:       " + json.dumps(call(addr, "owner()")))
    log("asset:       " + json.dumps(call(addr, "asset()")))
    log("paused:      " + json.dumps(call(addr, "paused()")))
    log("cooldownDuration: " + json.dumps(call(addr, "cooldownDuration()")))
    log("aavePool:    " + json.dumps(call(addr, "aavePool()")))
    log("aToken:      " + json.dumps(call(addr, "aToken()")))

log("\n=== DONE ===")
