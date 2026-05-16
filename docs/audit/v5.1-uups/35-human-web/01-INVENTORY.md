# 01 — Frontend inventory

> ⚠️ OBSOLETO — Direcciones citadas blanked en Sprint Z.2 pre-redeploy (bug L476-477).
> Documento conservado como registro histórico. Direcciones se repoblarán post-redeploy.

Source: `org-lumina/v0-lumina-landing-page@main` (private). Deployed at <https://lumina-org.com> on Vercel. The repo is a hybrid landing-page + dapp dashboard for the human-facing surface of the Lumina Protocol.

## Stack

| Layer | Choice | Notes |
|---|---|---|
| Framework | **Next.js 16.1.6** (App Router, Turbo dev) | Edge runtime via Vercel |
| Web3 | **wagmi 3.5** (NOT v2 — audit spec was outdated) + **viem 2.46** | Through-out the dapp surface |
| Wallet UI | **@rainbow-me/rainbowkit 2.2.10** + custom `lib/wallet.ts` legacy flow | Dual wallet system, bridged via `lib/wallet-bridge.ts` |
| Wallet SDK | `@metamask/sdk 0.34.0` | Falls back to injected provider |
| Data fetching | `@tanstack/react-query 5.90.21` | Standard React Query |
| UI primitives | shadcn/ui (Radix + Tailwind) | 40+ Radix components in `components/ui/` |
| Form | `react-hook-form` + zod resolvers | |
| Misc | `firebase-admin` (server-side), `@dropbox/sign` | For agent registration / e-sign? |

Dependency `firebase-admin` is server-side only and used inside Next route handlers; not relevant to the dapp surface.

## App routes (Next App Router)

| Route | Purpose |
|---|---|
| `/` | Landing page — hero, calculator, pricing, addons, referrals, etc. |
| `/connect` | Wallet connect page (legacy flow) |
| `/dashboard` | Main dapp surface — Overview / My Vaults / My Policies / Agent Activity / Emergency tabs |
| `/terminos` | Terms of service |
| `/whitepaper/en`, `/whitepaper/es` | Whitepaper (multilingual) |
| `/api/rpc` | Server-side RPC proxy (read-only, rate-limited) |

## Key components

| File | Purpose |
|---|---|
| `components/lumina/web3-provider.tsx` | WagmiProvider + RainbowKitProvider; `chains: [base]`; `reconnectOnMount: false` |
| `components/lumina/vault-actions.tsx` | LP `requestWithdrawal`, `completeWithdrawal` write hooks |
| `components/lumina/deposit-lp-modal.tsx` | LP `approve` + `deposit` flow with exact-amount approval |
| `components/lumina/protocol-status.tsx` | Reads protocol KPIs (TVL, total bonds, etc.) |
| `components/lumina/product-grid.tsx` | Reads 9 shields and renders cards |
| `components/lumina/register-agent-modal.tsx` | Agent registration UX |
| `components/lumina/tx-status.tsx` | Wrong-network modal + tx status indicators |
| `components/chat-widget.tsx` | "Lumi" assistant chat (calls `/api/chat` which is **not implemented**) |
| `app/dashboard/page.tsx` | 1800-line dashboard — bulk of dapp surface |

## Hooks

| Hook | Returns |
|---|---|
| `use-lumina-wallet.ts` | `{ address, isConnected, isWagmiConnected, source }` — bridged dual-system wallet |
| `use-web3.ts` | `useSwitchChain()` wrapper to force `chainId = base.id` |
| `use-mobile.tsx` | Responsive helper |
| `use-toast.ts` | shadcn toast wrapper |

## Contract addresses in `lib/lumina-config.ts`

⚠️ The frontend is pinned to **Base Mainnet (chainId 8453)** with **V1/V2 contract addresses**:

```ts
export const CHAIN = { id: 8453, name: "Base Mainnet", ... }
export const CONTRACTS = {
  CoverRouter:   "0x0000000000000000000000000000000000000000",  // V1/V2 — OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025)
  PolicyManager: "0x0000000000000000000000000000000000000000",  // V1/V2 — OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a)
  ...
  vaults: { VolatileShort, VolatileLong, StableShort, StableLong, FlashVault },
  shields: { BCS, EAS, Depeg, ILIndex, Exploit, FlashBTC24h, FlashBTC48h, FlashETH24h, FlashETH48h },
}
```

The V5.1 Sepolia deploy that came online on 2026-04-27 is **at completely different addresses on chain 84532**. The frontend cannot interact with the V5.1 contracts as currently configured. See finding **CHAIN-1** in REPORT.md.

## API connections

Only `/api/rpc` (own server-route, mainnet-only). The frontend does **not** call the lumina-api at `https://lumina-api-production-ac85.up.railway.app` — humans buy nothing through the API; the API is for AI agents. This is intentional per the protocol spec.

## /api/rpc proxy — separate audit-quality

The proxy at `app/api/rpc/route.ts` is a small but well-designed read-only RPC gateway:

| Property | Value |
|---|---|
| Whitelist | 9 methods (`eth_call`, `eth_getBalance`, `eth_blockNumber`, `eth_chainId`, `eth_getTransactionReceipt`, `eth_getTransactionByHash`, `eth_getLogs`, `eth_getBlockByNumber`, `eth_getCode`) |
| Rate limit | 100 req/min per IP, in-memory `Map` |
| RPC fallback | 1rpc.io/base → base.llamarpc.com → mainnet.base.org |
| Status codes | 200 success, 400 invalid, 403 method-not-allowed, 429 rate-limited, 502 all-failed |

The whitelist excludes write methods (`eth_sendRawTransaction`, etc.) — write txs go through the user's wallet directly, never through this proxy. Safe.

## Test surface

**No test suite.** No `jest.config.*`, no `playwright.config.*`, no `cypress.config.*`, no `__tests__/`. Per audit rule (`Si web no tiene tests, NO crear suite completa`), this report covers manual review only and flags the absence as INFO.

## Tabs in the dashboard

```
TABS = ["Overview", "My Vaults", "My Policies", "Agent Activity", "Emergency"]
SIDEBAR_SECTIONS = [
  { label: "",          items: ["Overview"] },
  { label: "EARN",      items: ["My Vaults"] },     // LP deposits / yields
  { label: "PROTECT",   items: ["My Policies"] },   // policy monitoring (read-only)
  { label: "MONITOR",   items: ["Agent Activity", "Emergency"] },
]
```

The "Buy Policy" path is not present in the human dashboard — confirming the protocol's design that policy purchases happen only via the API. Search for `"Buy Policy"`/`buyPolicy`/`purchasePolicy` returned only one match: a code-block snippet in `agent-skills-section.tsx` documenting the API surface (not a UI button).
