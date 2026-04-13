const https = require('https');
function rpc(method, params) {
  const body = JSON.stringify({ jsonrpc: '2.0', method, params, id: 1 });
  return new Promise((resolve, reject) => {
    const req = https.request('https://mainnet.base.org', {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => { let d=''; res.on('data',c=>d+=c); res.on('end',()=>resolve(d)); });
    req.on('error', reject); req.write(body); req.end();
  });
}
function sleep(ms){return new Promise(r=>setTimeout(r,ms));}
async function call(method, params) {
  for (let i = 0; i < 6; i++) {
    const r = await rpc(method, params);
    if (!r.includes('over rate limit')) return r;
    await sleep(1500 * (i + 1));
  }
  return rpc(method, params);
}

const VAULTS = {
  VolatileShort: '0xbd44AbDD61a2A6EeA98935f7a66f98fB49FA1C0a',
  VolatileLong:  '0xFee5eE6D81c1E3D9Ea2106cE05Ca12bEa2BE88c5',
  StableShort:   '0x429bd85D8CfB3B3B34e0A29b7DE07e62EA7C16F4',
  StableLong:    '0x17781f3A01f6b5C5099D32e65CFaf08a4f1cC6Ce',
};
const SHIELDS_V2 = {
  BCS:     '0x6E0A46B268e4ad9648CDABd9A4B2B20B79E5aB21',
  EAS:     '0x70f1c92eFCFe55e8d460AAA6D626779536b15128',
  DEPEG:   '0x881f683291122c3A72bDD504f71DDcAf47d9aE0e',
  IL:      '0x01Df7F2953DcE5be3aFfb72cB9f059f3D3Ee9E5a',
  EXPLOIT: '0x63d340aE7229Bb464Bc801f225651341ebcD3693',
};
const OTHERS = {
  Oracle: '0x87B576f688bE0E1d7d23A299f55b475658215105',
  Router: '0xd5f8678A0F2149B6342F9014CCe6d743234Ca025',
  PolicyMgr: '0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a',
  USDC: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
};

(async () => {
  console.log('=== eth_getCode for vaults ===');
  for (const [n, a] of Object.entries({...VAULTS, ...SHIELDS_V2, ...OTHERS})) {
    const r = await call('eth_getCode', [a, 'latest']);
    const parsed = JSON.parse(r);
    const code = parsed.result || '';
    const hasCode = code && code !== '0x';
    const len = hasCode ? (code.length - 2) / 2 : 0;
    console.log(`${n.padEnd(15)} ${a} -> ${hasCode ? `contract (${len} bytes)` : 'EOA/empty'}`);
  }
})().catch(e => console.error(e));
