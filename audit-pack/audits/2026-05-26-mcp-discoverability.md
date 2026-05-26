# MCP Discoverability Audit — user-facing surfaces

**Date:** 2026-05-26 · **Scope:** verify the official MCP server
(`@lumina-org/mcp-server`, repo `org-lumina/lumina-mcp`) is discoverable and
actionable across the public surfaces (/skills, docs, /tutorial, llms.txt).
**Read-only — nothing modified, nothing merged.**

## TL;DR

`@lumina-org/mcp-server@0.1.0` is **live on npm** (resolves; installable). The
landing `/skills` MCP card is **live**. But the docs surfaces (`/mcp/quickstart`,
`llms.txt`) are **merged yet not served** — `docs.lumina-org.com/mcp/quickstart`
returns **404** despite PR #22 being MERGED. Root cause: **Mintlify deploy/cache
lag** (the recurring docs-staleness issue), not missing content. Net effect today:
the live `/skills` card **links to a 404**.

| Surface | MCP info score (LIVE) | State |
|---|:--:|---|
| A — `/skills` (landing) | **8/10** | MCP card live (PR #46 deployed) |
| B — `/docs/mcp/quickstart` | **0/10 live** (page 404s) · ~6/10 as-merged | merged (PR #22) but **not deployed** (Mintlify lag) |
| C — `/tutorial` | **0/10** | no MCP mention at all |
| D — `llms.txt` | **0/10 live** · ~8/10 as-merged | merged but docs site serves stale llms.txt |
| **Overall (live, weighted)** | **~4/10** | content largely exists; **deploy + 2 content gaps** block it |

## Phase A — `/skills` (landing) — 8/10

Verified live at `https://www.lumina-org.com/skills`:
- ✅ **Prominent MCP card** present (accent-bordered, above the SDK quick-start).
- ✅ **Copy-paste config JSON** (`mcpServers` → `npx -y @lumina-org/mcp-server`).
- ✅ **Docs link** → `docs.lumina-org.com/mcp/quickstart` (but that URL currently 404s — see B).
- ✅ **Repo link** → `github.com/org-lumina/lumina-mcp`.
- ✅ Sandbox / no-key / unsigned-tx model described.
- ⚠️ **Apps listed:** Claude Desktop, Cursor, Windsurf, Continue. **Missing: Claude Code (CLI)** — required by the audit checklist (item 4).
- ⚠️ **Install instructions:** the `npx` config is the de-facto install; no explicit `npm i -g` / per-app variants.

## Phase B — `/docs/mcp/quickstart` — 0/10 live (404), ~6/10 as-merged

- ❌ **Live: HTTP 404** at `docs.lumina-org.com/mcp/quickstart` even though PR #22
  (which adds `mcp/quickstart.mdx` + nav) is **MERGED**. The Mintlify site has not
  re-rendered the new page — consistent with the project's known docs deploy/cache lag.
- The **merged content** (the `.mdx` itself) covers: what MCP is (non-tech), why
  Lumina ships it, Claude Desktop config, Cursor/Windsurf/Continue config, env vars,
  tool/resource/prompt inventory, use cases, links. Against the audit checklist it is
  **incomplete**:
  - ❌ **No Claude Code (CLI) setup** (`claude mcp add lumina -- npx -y @lumina-org/mcp-server`).
  - ❌ **No per-OS step-by-step** for Claude Desktop (Mac `~/Library/Application Support/Claude/…` vs Windows `%APPDATA%\Claude\…` config paths).
  - ❌ **No Troubleshooting section** (server not detected, npx/Node missing, stdio logs).
  - ❌ **No FAQ.**
  - ⚠️ **Post-setup prompt examples** exist only as a short "use cases" list, not a dedicated copy-paste block.

## Phase C — `/tutorial` — 0/10 (MCP)

- ❌ The human step-by-step tutorial **does not mention MCP at all**. A user who
  prefers their AI assistant has no signpost from the tutorial to the MCP path.

## Phase D — `llms.txt` — 0/10 live, ~8/10 as-merged

- ❌ `https://www.lumina-org.com/llms.txt` and `https://docs.lumina-org.com/llms.txt`
  contain **no MCP section** live (grep `mcp` = 0), despite PR #22 adding an MCP
  section to the docs `llms.txt`. Same Mintlify deploy lag as B.
- The **merged** `llms.txt` MCP section is solid (server name, config, 11 tools / 4
  resources / 3 prompts, unsigned-tx note, docs link).

## Phase E — Gaps + recommendations

### Root-cause gap (highest priority)
1. **Force a docs (Mintlify) redeploy / cache-bust.** PRs #22 are merged but
   `/mcp/quickstart` 404s and `llms.txt` is stale. Until the docs site re-renders,
   the **live `/skills` card links to a 404** — the worst-case discoverability bug.
   (Known recurring issue — see prior `llms-override` / `disable-autogen` sprints.)

### Content gaps to add to the docs page + skills card
2. **Add Claude Code (CLI) everywhere** — skills card app list + a docs setup block:
   `claude mcp add lumina -- npx -y @lumina-org/mcp-server`.
3. **Expand `docs/mcp/quickstart.mdx`** with: per-OS Claude Desktop config paths
   (Mac/Windows), a **Troubleshooting** section, an **FAQ**, and a dedicated
   **post-setup prompt examples** block ("Buy me 1h BTC flash-crash cover", etc.).
4. **Add an MCP signpost at the top of `/tutorial`** — "Prefer your AI assistant?
   Add Lumina via MCP in 3 lines → /mcp/quickstart" — so the human path surfaces it.
5. Minor: the `/skills` card could show explicit install variants (global vs npx) and
   a one-line "verify with `npx @lumina-org/mcp-server`".

### What's already good (no action)
- npm package live + installable (`npm view @lumina-org/mcp-server` → 0.1.0).
- Landing `/skills` MCP card: prominent, correct config, repo + docs links.
- Safety framing (no-keys / sandbox-default) consistently present.

## Verdict
The MCP content is **mostly built and merged** — the live shortfall is **(a) a docs
deploy/cache lag** that must be flushed so the merged `/mcp/quickstart` + `llms.txt`
actually serve, and **(b) two content gaps** (Claude Code CLI everywhere; tutorial
signpost) plus depth gaps in the docs page (troubleshooting/FAQ/per-OS). Once the
docs redeploy and items 2–4 land, live discoverability moves from ~4/10 to ~9/10.
