# 02 — Web manual checklist

Foundry and Jest cannot exercise the browser surface. This is the manual smoke pass an operator should run **after** merging the audit-35 fix PR (`fix/audit-35-web-full`) on `org-lumina/v0-lumina-landing-page`. The fix migrates the frontend off Base Mainnet V1/V2 onto Base Sepolia V5.1; this checklist confirms the migration actually works in a real browser.

## Pre-conditions

- Audit-35 fix PR is merged (or running locally with that branch).
- `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` set on Vercel (audit-35 WC-1 fix).
- `NEXT_PUBLIC_RPC_URL` optionally set to a paid Alchemy/Infura URL (audit-35 CHAIN-1 fix; falls back to public Sepolia RPC).
- Wallet has Base Sepolia ETH (faucet at <https://www.alchemy.com/faucets/base-sepolia>) and some Mock USDC at `0x63D340AE7229BB464bC801f225651341ebcD3693`.

## Run order

Each `[ ]` is a single observation. If any fails, capture a screenshot + URL and file an issue against `org-lumina/v0-lumina-landing-page`.

### Connect & network

- [ ] Open <https://lumina-org.com> (the deployed Vercel URL after merge).
- [ ] Click **Connect Wallet**.
- [ ] MetaMask popup appears (or Coinbase / Rainbow / WalletConnect, depending on what the user picks).
- [ ] After approving, the app prompts to switch chain to Base Sepolia.
- [ ] Approve the chain switch. The address chip top-right shows the connected account.
- [ ] Reload the page. The wallet stays connected (legacy localStorage flow), no popup re-appears (`reconnectOnMount: false` is intentional).

### Reads

- [ ] Dashboard `/dashboard` loads.
- [ ] **Overview** tab: 9 products visible (post-CHAIN-1 migration to V5.1 shields).
- [ ] LUMINA balance shown (probably 0 for a fresh wallet — that's fine).
- [ ] USDC balance shown (matches `cast call MOCK_USDC balanceOf(addr)` from a terminal, accounting for 6 decimals).

### Vaults / LP (expected partially-broken)

- [ ] **My Vaults** tab loads but the deposit/withdraw buttons either disabled or surface "not available". This is expected: V5.1 does not have LP primitives — see `01-FLOWS.md` for the protocol-roadmap action item. **Do not file as a bug; this is documented behaviour.**

### Marketplace

- [ ] **Marketplace** view (or whatever the dashboard tab is called for trading bonds) loads.
- [ ] Listings render (or empty state if no one has listed yet — fine in early testnet).
- [ ] If at least one listing exists: click **Buy** on it. Approval popup → Buy popup → toast indicating success → bond NFT shown in the user's holdings (might require a refresh).

### Policies

- [ ] **My Policies** tab. For the founder wallet (`0xe585e76A…`) at least one row should show — policy id 3 from PR #86's E2E.
- [ ] For a fresh wallet that has not bought any policies, the table is empty. (Buying through the web is intentionally NOT supported; agents buy via API.)

### Disconnect

- [ ] Click the address chip → **Disconnect**.
- [ ] The legacy localStorage entry is cleared and wagmi disconnects in lockstep (audit-35 INFO-1 documents the dual-system bridge).
- [ ] Reload the page: no auto-reconnect popup.

### Console / network sanity

- [ ] No `console.error` referencing `demo-project-id` (means audit-35 WC-1 fix is honoured).
- [ ] No 404s in the Network tab when interacting with the app (means CHAIN-1 migration's RPC and contract reads succeed).

## After all steps

- All `[ ]` ticked → frontend is **e2e-validated for V5.1 Sepolia**.
- One or more failed → file follow-up tickets and reference back to this checklist by path.

## Why this is a checklist, not a Playwright suite

The frontend repo has no test infrastructure today. Adding Playwright + a Sepolia-on-CI funded wallet is more than the audit window allows. The checklist captures the same intent that an automated suite would, in a form an operator can run before each release.
