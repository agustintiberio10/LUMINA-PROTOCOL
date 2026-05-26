# Distribution Strategy — Fase 5 (Public Testnet)

**Date:** 2026-05-26 · **Scope:** audit of LUMINA's published agent `/skills`, gap
analysis across 9 popular agent frameworks, listing-venue analysis across 8
directories/marketplaces, and a prioritized go-to-market recommendation for the
public-testnet phase. **No contracts modified. No merge.**

**LUMINA profile (for venue/audit gating):** parametric crypto-insurance on **Base
Sepolia (84532)**, **no external Tier-1 audit**, single-EOA owner; public REST API
+ `@lumina-org/sdk@0.7.0` (TS) + 22 published agent skills + a no-wallet/no-gas
`/sandbox/try` endpoint.

---

## Phase A — Audit of `/skills` (lumina-org.com) — **7/10**

- `GET /skills` → **200**, renders **22 skill pages** covering the full V5.4
  lifecycle: `browse-shields`, `read-shield-specs`, `quote-policy`/`quote-via-api`,
  `connect-wallet`, `approve-usdc`, `generate-api-key`, `configure-api-client`,
  `buy-policy-agent`/`buy-policy-human`, `check-policy-detail`, `track-policies`,
  `watch-triggers`, `receive-claimbond`, `get-bonds`, `redeem-bond`/`redeem-via-api`,
  `list-bond`/`buy-listing`/`cancel-listing`, `health-check`, `check-protocol-status`.
- Each skill = LLM-readable prompt + copy-paste curl/TS/Python. IDE-assistant guides
  exist for **Cursor / Claude Code / Windsurf** (docs/ai-tools).
- **`GET /api/skills` returns the Next.js HTML shell, not JSON** — there is no
  machine-readable skills manifest for programmatic discovery.

**What's good:** broad, accurate, lifecycle-complete REST primitives; the
no-wallet/no-gas `/sandbox/try` is a genuinely best-in-class first-contact path.
**What's missing (the −3):**
1. **No framework-specific plugin** for *any* agent framework (verified: only
   `@lumina-org/sdk` exists on npm; 0 plugin repos).
2. **No MCP server** — the protocol IDE assistants (Cursor/Claude/Windsurf) and a
   growing share of frameworks consume **Model Context Protocol** servers; LUMINA
   ships none.
3. **No machine-readable `/api/skills`** (JSON/manifest) for agents to enumerate
   skills programmatically.

The skills are excellent *content* but distribution-limited to copy-paste + IDE.
Score reflects strong substance, weak packaged-distribution surface.

---

## Phase B — Framework gap analysis (9 frameworks)

**No LUMINA plugin exists for any framework** (verified: npm scope has only
`@lumina-org/sdk@0.7.0`; GitHub plugin search = 0). The 9 are not the same kind of
thing — agent-tool frameworks (clean plugin fit), on-chain commerce protocols
(provider-registration fit), and no-code/infra platforms (poor fit) — ranked
accordingly (relevance × low-effort × reach).

| # | Framework | Integration model | Lang | Effort | Relevance | Notes |
|---|---|---|---|--:|:--:|---|
| 1 | **ElizaOS** | npm `Plugin` (actions/providers) + registry PR | **TS (reuse SDK)** | **2–4 d** | 5 | Crypto-native, Base-aware, direct SDK reuse, registry distribution. **Best balance.** |
| 2 | **Virtuals ACP** | Register as on-chain **seller** in Service Registry; ACP SDK | **TS + Python** | 4–7 d | 5 | **Highest strategic fit** (agent-to-agent insurance commerce on Base = the ACP thesis). BUT ACP is **Base-mainnet-oriented** — testnet mismatch; defer full deploy to mainnet. |
| 3 | **LangChain / LangGraph** | `@tool`/`BaseTool` + toolkit; pip pkg / hub | **Python** (wrapper) | 2–3 d | 4 | Biggest reach; LUMINA is one generic tool among thousands; wrap the REST API in Python. |
| 4 | **CrewAI** | `BaseTool` + Pydantic schema; `crewai-tools` | **Python** | 2–3 d | 3 | Good reach; enterprise-orchestration focus, not crypto. |
| 5 | **Olas / Autonolas** | On-chain component/skill/service NFTs; Open Autonomy FSM | **Python (heavy)** | 8–15 d | 3 | Truly on-chain/autonomous (high concept fit) but steep, idiosyncratic stack + mainnet economics. |
| 6 | **AutoGen (MS)** | `FunctionTool`/`BaseTool`; `autogen-ext` | **Python** | 2–3 d | 2 | Easy build, weak crypto fit, framework migrating to MS Agent Framework. |
| 7 | **MyShell** | No-code Pro-Config JSON widget (external API) | JSON config | 3–5 d | 2 | Large consumer creator base but chatbot-focused, config-bound I/O. |
| 8 | **Glif** | No-code visual blocks + beta API | No-code/API | 3–5 d | 1 | Creative/generative-media platform; weakest fit. |
| 9 | **AIOZ (AI/DePIN)** | DePIN compute/storage infra — no agent-plugin surface | N/A | N/A | 1 | Out of category; LUMINA is not DePIN infra and isn't on AIOZ. Skip. |

**Reuse `@lumina-org/sdk` (TS) directly:** ElizaOS, Virtuals ACP (TS path).
**Need a Python wrapper over the REST API:** LangChain, CrewAI, AutoGen, Olas.

---

## Phase C — Listing venues (8 directories/marketplaces)

| Venue | Testnet OK? | No-audit OK? | Key requirements | Effort | Reach | Verdict |
|---|:--:|:--:|---|--:|:--:|---|
| **Virtuals ACP** (Base) | Yes (sandbox) | Yes | Service-Registry entry; `offering.json`+handlers; API-only seller path | Low-Med | 5 | **NOW (sandbox) → graduate at mainnet** |
| **ElizaOS plugin registry** | Yes | Yes | npm `@elizaos/plugin-*` + 1-file `index.json` PR + demo/tests | **Low** | 4 | **NOW** |
| **LangChain integrations dir** | Yes | Yes | `langchain-*` pkg via CLI + docs PR | Low-Med | 4 | **NOW** |
| **DappRadar ("upcoming")** | Yes (no contracts) | Yes | Free; account + email; visuals/desc. Released/ranked needs **mainnet** addrs | **Low** | 4 | **NOW as placeholder** → ranked at mainnet |
| **AutoGen community gallery** | Yes | Yes | Publish `autogen-*` pkg; self-serve gallery | Low | 3 | Optional (cheap once Python wrapper exists) |
| **DefiLlama** | **No** | de-facto No | Adapter PR; TVL from live chain; >$10k to display, >$1M+audit for strict pages | High | 5 | **Defer to mainnet** |
| **DappRadar (ranked)** | No | Yes | Mainnet contract addrs + real usage | Med | 4 | **Defer to mainnet** |
| **State of the DApps** | — | — | **Defunct** (301→CoinGecko since ~2022) | — | 0 | **Skip** |
| **AIOZ DePIN ecosystem** | — | — | Wrong vertical (DePIN infra) | — | 1 | **Skip** |

---

## Phase D — Prioritized recommendation for Fase 5

### Cross-cutting force-multiplier (do first)
**Build a LUMINA MCP server** wrapping the existing REST API/SDK (~2–3 d). MCP is
consumed natively by the assistants LUMINA already documents (Cursor, Claude Code,
Windsurf) and increasingly by frameworks — one MCP server yields multi-client
distribution and is the cheapest way to close the Phase-A "no packaged surface" gap.
Also expose a JSON `/api/skills` manifest (~0.5 d) so agents can enumerate skills.

### Top 3 frameworks to build NOW (testnet-viable, SDK-reusable, low effort)
1. **ElizaOS plugin** (`@elizaos/plugin-lumina`) — 2–4 d. Direct TS SDK reuse, crypto-native audience, registry distribution. **Highest ROI.**
2. **LangChain tool package** — 2–3 d (Python wrapper over REST). Largest reach in the dominant framework.
3. **Virtuals ACP seller (sandbox)** — 4–7 d. Highest strategic fit (insurance-as-a-service for agents on Base); start in sandbox now, **graduate at mainnet** (flag the Sepolia↔mainnet gap).

*(Defer Olas — high effort/mainnet economics. CrewAI/AutoGen are cheap follow-ons once the Python wrapper exists.)*

### Top 3 venues to list NOW (testnet + no-audit friendly)
1. **ElizaOS plugin registry** — ships with the plugin above; low effort, large builder audience.
2. **Virtuals ACP marketplace (sandbox)** — same-chain, agent-commerce-native; reserve presence now.
3. **DappRadar "upcoming dapp"** — free 5-minute placeholder; reserves the profile, upgrade to ranked at mainnet.
*(LangChain integrations directory rides on the LangChain package — effectively a 4th, near-free listing.)*

### Defer to mainnet (don't waste effort now)
- **DefiLlama** (needs real TVL; biggest credibility payoff but mainnet+audit-gated).
- **DappRadar ranked listing** (mainnet contracts + usage to populate metrics).
- **Virtuals ACP graduation / Olas deployment** (real on-chain economics).

### Don't pursue
- **State of the DApps** (defunct), **AIOZ DePIN** (wrong vertical).

### Total effort estimate (the "NOW" bundle)
| Item | Dev-days |
|---|--:|
| MCP server + JSON `/api/skills` manifest | 2.5–3.5 |
| ElizaOS plugin + registry PR | 2.5–4 |
| LangChain package + integrations-dir PR | 2.5–3.5 |
| Virtuals ACP sandbox seller (prep) | 4–7 |
| DappRadar "upcoming" listing | 0.5 |
| **Total** | **~12–18 dev-days** |

If ACP-sandbox is deferred to a mainnet sprint, the immediately-shippable testnet
bundle (MCP + ElizaOS + LangChain + DappRadar) is **~8–11 dev-days**.

### Strategic note
LUMINA's strongest near-term distribution asset is the **no-wallet/no-gas
`/sandbox/try`** path — every framework plugin/demo can show a real policy purchase
with zero on-chain risk regardless of testnet status. Lead all integrations with it.
The hard mainnet/audit gates (DefiLlama, ACP graduation, ranked directories) should
wait until after external audit + multisig (see the Tier-1 assessment).
