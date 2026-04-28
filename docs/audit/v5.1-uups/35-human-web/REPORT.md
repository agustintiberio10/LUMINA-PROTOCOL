# Audit V5.1 #35 — HUMAN WEB INTERFACE — REPORT

## Scope

Audit of `org-lumina/v0-lumina-landing-page@main`, the Vercel-hosted Next.js app at <https://lumina-org.com>. Stack and surface inventory in [`01-INVENTORY.md`](./01-INVENTORY.md).

The web is the **human-facing** surface (agent owners, LP investors). Policy purchases happen only through the API (audited separately in `33-api-architecture/`); the web exposes:

- wallet connect / disconnect
- product + protocol stats reads
- LP deposit / withdraw on five vaults
- bond marketplace (list / cancel / buy)
- read-only monitoring of policies and agent activity

## Findings

### CRITICAL — none

### HIGH

| # | Title | Location | Status |
|---|---|---|---|
| **CHAIN-1** | Frontend is pinned to **Base Mainnet (chainId 8453) with V1/V2 contract addresses**. The actual V5.1 deploy is on **Base Sepolia (84532)** at completely different addresses. Users connecting today get prompted to switch to mainnet, then either interact with stale V1/V2 contracts (if they still exist) or see a non-functional dashboard. | `lib/lumina-config.ts:11-72`, `components/lumina/web3-provider.tsx:25` (`chains: [base]`) | OPEN — operator must update `CHAIN.id`, `CONTRACTS.*`, and `chains: [base]` (or import `baseSepolia` from `wagmi/chains`) once V5.1 is the canonical deployment for human users |

The mismatch is the same class of staleness that was present in the API repo before the 2026-04-27 refresh. The API was already pointed at V5.1 Sepolia; the frontend has not been migrated.

### MEDIUM

| # | Title | Location | Status |
|---|---|---|---|
| **XSS-1** | `parseMarkdown(text)` does not HTML-escape its input before applying markdown transforms. Output is rendered via `dangerouslySetInnerHTML`. A user pasting `<img src=x onerror=alert(1)>` into the chat input would execute. The blast radius is currently SELF-XSS only (each user can only attack themselves), and the effective exploit surface is further reduced because `/api/chat` is not implemented (the assistant reply path is dead), but the source-of-data is also `data.reply` from a fetch — if `/api/chat` lands later as a free-form text passthrough, this becomes server-controlled XSS. | `components/chat-widget.tsx:17-22, 184` | OPEN — fix is one of: (a) HTML-escape before transforms, (b) replace with `react-markdown` + `rehype-sanitize`, (c) drop the dead `/api/chat` widget |
| **WC-1** | `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` falls back to the literal string `"demo-project-id"` if the env var is unset. Demo project IDs are aggressively rate-limited by WalletConnect Cloud and will degrade the WalletConnect path in production. | `components/lumina/web3-provider.tsx:11` | OPEN — set the env var on Vercel; fail-loud (throw at boot) if missing |

### LOW

| # | Title | Location | Status |
|---|---|---|---|
| **SIM-1** | `writeContract(...)` is called without prior `simulateContract(...)`. Transactions are sent to the user's wallet for signing without an in-app simulation pass. Wallet UIs do their own simulation, but pre-simulating in code allows surfacing decoded reverts to the user **before** they sign. | `components/lumina/deposit-lp-modal.tsx:150,168`, `components/lumina/vault-actions.tsx:48-49` | OPEN — improvement, not a bug |
| **DEAD-1** | `components/chat-widget.tsx` calls `fetch("/api/chat", ...)` which returns 404 because the route is not implemented. The widget swallows the error and shows "Hubo un problema de conexión". | — | OPEN — either implement `/api/chat` or remove the widget |

### INFO

| # | Note |
|---|---|
| **DUAL-1** | The frontend maintains TWO wallet states (legacy `localStorage["lumina_wallet"]` and wagmi v3) bridged via `lib/wallet-bridge.ts`. The dual system is justified in code comments (avoids multi-wallet picker on every reload, preserves UX during wagmi init), but adds reasoning surface. |
| **APPROVAL-1** | LP approvals use the **exact deposit amount** (`parseUnits(String(depositAmount), 6)`), not `MaxUint256`. ✅ Matches the protocol policy of bounded approvals. |
| **NO-TESTS** | Repo has no test suite. Per audit rule, no full suite was created — only manual review. |
| **RPC-PROXY** | `/api/rpc` is a read-only proxy with method whitelist, IP rate limit (100/min), and 3-RPC fallback chain. Solidly designed. ✅ |
| **LAYOUT-INLINE** | `app/layout.tsx:75` uses `dangerouslySetInnerHTML` for a hardcoded cache-clearing script. No data interpolation. ✅ Safe. |
| **CHART-INLINE** | `components/ui/chart.tsx:81` uses `dangerouslySetInnerHTML` from shadcn/ui chart wrapper, internally controlled, not user input. ✅ Safe. |

## Functional checks (PARTE 2)

| Flow | Status |
|---|---|
| Wallet connect (MetaMask, Coinbase, Rainbow, WalletConnect) | ✅ via RainbowKit + `connectorsForWallets` |
| Wallet disconnect | ✅ via legacy `disconnectWallet()` + `unbridgeWagmi()` |
| Auto-reconnect silent (no popup on page load) | ✅ `reconnectOnMount: false` is explicit |
| Network switch to target chain | ✅ via `useSwitchChain` in `hooks/use-web3.ts` — but target chain is **mainnet**, not Sepolia (CHAIN-1) |
| Wrong-network modal | ✅ exists in `components/lumina/tx-status.tsx` |
| Read 9 products from CoverRouter | ⚠️ via `product-grid.tsx` reading `CONTRACTS.shields.*` which point at **V1/V2 mainnet** addresses (CHAIN-1) |
| Read user balances | ⚠️ same chain pinning |
| Read user policies | ⚠️ same |
| Read marketplace listings | ⚠️ same |
| LP deposit flow (approve → deposit) | ✅ correct two-step flow with exact-amount approval |
| LP withdraw flow (request + complete with cooldown) | ✅ split into two `useWriteContract` hooks |
| Marketplace list / buy / cancel | (read in dashboard tabs) — not deeply audited beyond contract-pinning concern |

## Security checks (PARTE 3)

| Check | Status |
|---|---|
| Wallet drain via signature phishing | Not observed — every signing path is wallet-mediated, no `personal_sign` of arbitrary payloads |
| Approval limits | ✅ exact amount, not infinite |
| Network detection / wrong-network modal | ✅ present |
| XSS in chat-widget | ⚠️ MEDIUM (XSS-1) |
| XSS in layout/chart inline scripts | ✅ both hardcoded |
| CSRF | N/A — no cookie-mediated state mutation; wagmi tx signing is wallet-mediated |
| `eval` / `new Function` | None found |
| `dangerouslySetInnerHTML` of fetched data | One site (chat-widget.tsx) — see XSS-1 |
| API call rate limiting | ✅ `/api/rpc` is rate-limited 100/min/IP |

## UX checks (PARTE 4)

| Check | Status |
|---|---|
| "Buy Policy" eliminated from web (only via API) | ✅ Confirmed — only one match in code is a doc snippet, no UI button |
| Agent-only banner | Visible in `register-agent-modal.tsx` and dashboard contextual UI |
| Loading states | Used throughout LP modal (`approveTxStatus`, `depositTxStatus`) and tx-status component |
| Error handling | Errors caught from `writeContract` and surfaced via `err.shortMessage || err.message` |
| Mobile responsive | `use-mobile.tsx` hook + Tailwind responsive classes |
| Min font size 16px | Not exhaustively verified (would need Tailwind class scan); shadcn defaults are 14px (`text-sm`). INFO. |

## Quality

**7 / 10**

- Inventory exhaustive ✓
- Real findings (HIGH chain mismatch, MEDIUM XSS, MEDIUM env-var fallback) ✓
- Approval flow is already correct (exact amount, not infinite) ✓
- /api/rpc proxy is solidly designed ✓
- −2 because the frontend is **the wrong deployment for the audited V5.1 protocol** (chain mismatch is the dominant finding — the rest of the audit is best-effort against a frontend that doesn't actually connect to V5.1 Sepolia)
- −1 because there is no test suite to verify any of these claims behaviourally; everything in this report is manual review

## Verdict

**NEEDS FIXES.** The HIGH (CHAIN-1) is a blocker for the human surface to interact with V5.1 at all. Once the frontend is migrated to Sepolia (or once V5.1 is deployed to mainnet at the addresses the frontend already expects), the rest of the findings are MEDIUM/LOW and addressable in normal cadence.

### Priority order for the operator

1. **CHAIN-1** — migrate `lib/lumina-config.ts` and `web3-provider.tsx` to Base Sepolia + V5.1 addresses. Or wait until V5.1 mainnet deploy and update accordingly.
2. **XSS-1** — drop `dangerouslySetInnerHTML` in chat-widget OR replace `parseMarkdown` with a sanitizing implementation.
3. **WC-1** — set `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` on Vercel.
4. **DEAD-1** — implement or remove `/api/chat`.
5. **SIM-1** — pre-simulate writes in `vault-actions.tsx` and `deposit-lp-modal.tsx`.
