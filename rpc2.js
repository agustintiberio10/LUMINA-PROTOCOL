const https = require('https');
function rpc(method, params) {
  const body = JSON.stringify({ jsonrpc:'2.0', method, params, id:1 });
  return new Promise((res, rej) => {
    const req = https.request('https://mainnet.base.org', {
      method:'POST', headers:{'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>res(d)); });
    req.on('error', rej); req.write(body); req.end();
  });
}
function sleep(ms){return new Promise(r=>setTimeout(r,ms));}
async function call(to, data) {
  for (let i=0;i<6;i++) {
    const r = await rpc('eth_call', [{to, data}, 'latest']);
    if (!r.includes('over rate limit')) return r;
    await sleep(1500*(i+1));
  }
  return rpc('eth_call', [{to, data}, 'latest']);
}

// selectors (known)
const S = {
  totalAssets:   '0x01e1d114',
  owner:         '0x8da5cb5b',
  asset:         '0x38d52e0f',
  paused:        '0x5c975abb',
  cooldownDuration: '0xcbfccef5', // keccak("cooldownDuration()") precomputed
  aavePool:      '0xb90b9b29',    // keccak("aavePool()")
  aToken:        '0xf11b8188',    // keccak("aToken()")
  decimals:      '0x313ce567',
  description:   '0x7284e416',
};

// We need correct selectors. Let me compute them with noble-like inline keccak:
// Actually, reuse keccak from rpc.js — or just call contracts with multiple
// candidate selectors. Simpler: import from rpc.js? Easiest: use cast via forge.
// Since we can't run cast, compute here.

function keccak256(msgBytes) {
  const RC = [0x0000000000000001n,0x0000000000008082n,0x800000000000808an,0x8000000080008000n,0x000000000000808bn,0x0000000080000001n,0x8000000080008081n,0x8000000000008009n,0x000000000000008an,0x0000000000000088n,0x0000000080008009n,0x000000008000000an,0x000000008000808bn,0x800000000000008bn,0x8000000000008089n,0x8000000000008003n,0x8000000000008002n,0x8000000000000080n,0x000000000000800an,0x800000008000000an,0x8000000080008081n,0x8000000000008080n,0x0000000080000001n,0x8000000080008008n];
  const r = [[0,36,3,41,18],[1,44,10,45,2],[62,6,43,15,61],[28,55,25,21,56],[27,20,39,8,14]];
  const MASK = (1n<<64n)-1n;
  const rol=(x,n)=>{n=BigInt(n);return ((x<<n)|(x>>(64n-n)))&MASK;};
  const f=(st)=>{for(let rnd=0;rnd<24;rnd++){const C=new Array(5);for(let x=0;x<5;x++)C[x]=st[x][0]^st[x][1]^st[x][2]^st[x][3]^st[x][4];const D=new Array(5);for(let x=0;x<5;x++)D[x]=C[(x+4)%5]^rol(C[(x+1)%5],1);for(let x=0;x<5;x++)for(let y=0;y<5;y++)st[x][y]^=D[x];const B=Array.from({length:5},()=>Array(5).fill(0n));for(let x=0;x<5;x++)for(let y=0;y<5;y++)B[y][(2*x+3*y)%5]=rol(st[x][y],r[x][y]);for(let x=0;x<5;x++)for(let y=0;y<5;y++)st[x][y]=(B[x][y]^((~B[(x+1)%5][y])&B[(x+2)%5][y]))&MASK;st[0][0]^=RC[rnd];}return st;};
  const rate=136;const msg=Buffer.from(msgBytes);const padLen=rate-(msg.length%rate);const padded=Buffer.alloc(msg.length+padLen);msg.copy(padded,0);padded[msg.length]=0x01;padded[padded.length-1]|=0x80;
  const state=Array.from({length:5},()=>Array(5).fill(0n));
  for(let off=0;off<padded.length;off+=rate){const chunk=padded.subarray(off,off+rate);for(let i=0;i<rate/8;i++){let lane=0n;for(let b=0;b<8;b++)lane|=BigInt(chunk[i*8+b])<<BigInt(8*b);state[i%5][Math.floor(i/5)]^=lane;}f(state);}
  const out=Buffer.alloc(32);let p=0;for(let y=0;y<5&&p<32;y++)for(let x=0;x<5&&p<32;x++){let lane=state[x][y];for(let b=0;b<8&&p<32;b++)out[p++]=Number((lane>>BigInt(8*b))&0xffn);}
  return out;
}
const sel = sig => '0x'+keccak256(Buffer.from(sig)).toString('hex').slice(0,8);

S.cooldownDuration = sel('cooldownDuration()');
S.aavePool = sel('aavePool()');
S.aToken = sel('aToken()');
console.log('Selectors:', S);

const VAULTS = {
  VolatileShort: '0xbd44547581b92805aAECc40EB2809352b9b2880d',
  VolatileLong:  '0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904',
  StableShort:   '0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC',
  StableLong:    '0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c',
};

(async () => {
  console.log('\n=== VAULT CODE CHECK ===');
  for (const [n, a] of Object.entries(VAULTS)) {
    const r = await rpc('eth_getCode', [a, 'latest']);
    const p = JSON.parse(r).result || '';
    console.log(`${n.padEnd(14)} ${a} -> ${p && p !== '0x' ? `contract (${(p.length-2)/2} bytes)` : 'empty'}`);
  }

  console.log('\n=== VAULT STATE ===');
  for (const [n, addr] of Object.entries(VAULTS)) {
    console.log(`\n--- ${n} @ ${addr} ---`);
    console.log(`totalAssets():     ${await call(addr, S.totalAssets)}`);
    console.log(`owner():           ${await call(addr, S.owner)}`);
    console.log(`asset():           ${await call(addr, S.asset)}`);
    console.log(`paused():          ${await call(addr, S.paused)}`);
    console.log(`cooldownDuration():${await call(addr, S.cooldownDuration)}`);
    console.log(`aavePool():        ${await call(addr, S.aavePool)}`);
    console.log(`aToken():          ${await call(addr, S.aToken)}`);
  }
})().catch(e => console.error(e));
