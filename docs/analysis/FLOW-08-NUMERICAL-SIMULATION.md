# FLOW-08 — Numerical simulation of 5 events

Goal: trace the balances and ratios through a realistic sequence. Every line of math comes from a source formula already cited in FLOW-01 through FLOW-07.

---

## 8.1 Assumptions (initial state)

- LUMINA total supply: 100,000,000 (100M).
- BondVault balance: 70,000,000 LUMINA.
- Starting price: $0.036 (deploy-time emergency price).
- `totalCommittedUSD`: 0 (no policies sold yet).
- `totalReservedUSD`: 0.
- `SAFETY_FACTOR_BPS`: 5000 (50%).
- `MIN_REDEEM_PRICE`: 0.001e18 ($0.001).
- TWAPBurner balances: all 0.
- MaintenanceReserve balance: 0.
- BuybackEngine balance: 0.
- Adaptive mode enabled. Initial quadrant: HEALTHY-STABLE (sLevel=1, mLevel=1) = `(8500, 800, 200, 500)`.

## 8.2 Event 1 — 10,000 policies sold at $50 coverage, 1% premium

### Step-by-step math

- Premium per policy: `50 × 1% = $0.50` = 500,000 USDC-wei (6-dec).
- Total premium: `10,000 × 0.50 = $5,000` = 5,000,000,000 USDC-wei.
- After flow: all $5,000 → TWAPBurner.

### Bond obligations

For each policy, if the "trigger" probability commit path runs (see `issueBond`), the protocol reserves capacity. Assume NOT triggered yet — obligations are 0 at this point. `totalCommittedUSD` remains 0.

### `executeBurn` after 15 minutes (cooldown satisfied)

- TWAPBurner balance: 5,000 USDC.
- `maxBurnAmount = 10,000 USDC` → full $5,000 processed.
- Distribution HEALTHY-STABLE: (8500, 800, 200, 500).
- `toBurn = 5000 × 8500 / 10000 = 4,250 USDC`.
- `toBuyback = 5000 × 800 / 10000 = 400 USDC`.
- `toOps = 5000 × 200 / 10000 = 100 USDC`.
- `toMaint = 5000 × 500 / 10000 = 250 USDC`.

### Post-event balances

| Contract | USDC | LUMINA |
|---|---|---|
| TWAPBurner | 0 | 0 |
| BondVault | 0 | 70,000,000 |
| BuybackEngine | 400 | 0 |
| ops EOA | 100 | 0 |
| MaintenanceReserve | 250 | 0 |
| LUMINA supply | — | 100M − X, where X ≈ 4,250 / 0.036 ≈ 118,055 LUMINA (from `_swapAndBurn`) |

Simplification: assume DEX gives 1:price ratio with no slippage. LUMINA destroyed ≈ 118,055. New supply: ~99,881,944.

### Solvency ratio after Event 1

- `obligations` = 0 → `_calculateSolvencyRatio` returns `type(uint256).max` (`SolvencyOracle.sol:125`). Vault is trivially solvent.

## 8.3 Event 2 — 500 policies trigger, each paying out $50

When a policy triggers, `BondVault.issueBond` is invoked (by PolicyManager after claim validation). Effect:

- `claimBond.mint(agent, epoch, 50e18)` — each insured agent gets ERC-1155 bonds worth $50.
- `totalCommittedUSD += 50 × 1e18` per policy.

Total: `500 × $50 = $25,000` committed. `totalCommittedUSD = 25,000e18`.

### Capacity check at issuance (per issueBond at BondVault.sol:159-180)

```
reserveBalance = 70M LUMINA  (still the initial mint)
reserveValueUSD = 70M × 0.036 = $2,520,000
maxCommitUSD = $2,520,000 × 0.5 = $1,260,000
```

$25,000 committed << $1.26M cap. Passes easily.

### Solvency ratio after Event 2

Price still $0.036.
- Numerator: `valueUSD = 70M × 0.036 × 1e18 / 1e18 = $2,520,000e18`.
- Denominator: `totalCommittedUSD = 25,000e18`.
- Ratio: `2,520,000e18 × 10000 / 25,000e18 = 1,008,000 bps = 10,080%`.

**10,080% ≥ 20,000 bps is false → 20,000 too high. Let me recheck: `1,008,000 > 20,000` → ULTRA (sLevel=0).**

Actually `1,008,000 bps = 10,080%` which is > 200% → ULTRA (sLevel=0).

### Adaptive distribution now = ULTRA-STABLE (sLevel=0, mLevel=1) = (9000, 500, 0, 500)

So from this event on, any executeBurn allocates 90% to burn, 5% buyback, 0% ops (luxury of not paying infra out of burns — ULTRA row), 5% maint. Ops wallet stops getting fresh premium income from the matrix.

## 8.4 Event 3 — Price drops to $0.01 (72% drop)

The emergency price oracle has a floor, but assume the market price feed has updated and TWAP absorbs the move.

### Capacity recomputed

```
reserveValueUSD = 70M × 0.01 = $700,000
maxCommitUSD = $700,000 × 0.5 = $350,000
```

Still > $25,000 committed. Issuance can continue.

### Solvency recomputed

- Numerator: `70M × 0.01 = $700,000`.
- Denominator: `$25,000`.
- Ratio: `700,000 × 10000 / 25,000 = 280,000 bps = 2800%` → ULTRA.

Still ULTRA. Quadrant doesn't change. The 16-cell matrix still prescribes (9000, 500, 0, 500) for ULTRA-STABLE — still mostly burn.

This is a **counter-intuitive** finding. Price dropped 72% and the protocol's response is "burn more aggressively" because solvency is still >200%. From a defense-in-depth standpoint, this makes sense — the 70M-LUMINA cushion is absorbing the drop. But it also illustrates the vault's nature: a finite deposit that silently erodes.

## 8.5 Event 4 — Price collapses to $0.0005 (below MIN_REDEEM_PRICE)

### Capacity

```
reserveValueUSD = 70M × 0.0005 = $35,000
maxCommitUSD = $35,000 × 0.5 = $17,500
```

Since `totalCommittedUSD = $25,000 > $17,500`, any new `issueBond` call reverts with "Exceeds capacity". **New policy issuance halts.**

### Can holders redeem?

`redeemBond` requires `currentPrice >= MIN_REDEEM_PRICE` (0.001e18 = $0.001). $0.0005 < $0.001 → **redemption halts too.**

Bond holders are frozen. Both sides of the protocol are locked.

### Solvency ratio

- Numerator: `70M × 0.0005 = $35,000`.
- Denominator: `$25,000`.
- Ratio: `35,000 × 10000 / 25,000 = 14,000 bps = 140%` → HEALTHY (sLevel=1).

Note: we crossed from ULTRA (>200%) into HEALTHY (100-200%). The matrix now prescribes HEALTHY-STABLE (1,1) = (8500, 800, 200, 500). But because MIN_REDEEM_PRICE blocks redemptions and capacity is exceeded, the matrix only applies to whatever new USDC arrives — which has dropped to zero (no new policies).

### What the matrix DOES NOT do

No allocation in (1,1) = (8500, 800, 200, 500) sends any USDC to BondVault. If the protocol somehow received new USDC during this event, it would still be distributed per the matrix — 85% burned (via DEX at the depressed price), 8% to BuybackEngine, 2% ops, 5% maint. **Zero to BondVault.**

## 8.6 Event 5 — Admin response options (all require off-chain action)

With no automatic refill:

### Option A — Admin sends LUMINA directly

```solidity
// From an admin-held EOA that has LUMINA tokens (e.g., TreasuryVesting has released some)
lumina.transfer(address(bondVault), 10_000_000e18);
```

Effect: `bondVault.lumina.balanceOf` increases by 10M. But:
- Total supply is UNCHANGED (no burn happened). So if admin moves LUMINA from a circulating wallet, the market balance reduces.
- Solvency ratio numerator goes up → ratio improves.
- Still requires off-chain decision + manual tx.

### Option B — MaintenanceReserve.spend($250 → admin) → admin swaps → transfers

If MaintenanceReserve has accumulated $250 (from Event 1), admin could:
1. `spend(admin, 250e6, Other, "Vault rescue")` — USDC to admin.
2. Admin off-chain swaps 250 USDC → LUMINA on the DEX. At $0.0005, gets ~500,000 LUMINA.
3. Admin `lumina.transfer(bondVault, 500,000e18)`.

This is 3 manual txs, off-chain custody, and relies on admin security. And $250 worth of LUMINA is a rounding error against a vault holding 70M.

### Option C — Build the proposed rescue function (see FLOW-07 §7.7)

- Admin queues `swapAndReplenishBondVault(X USDC, minLumina, router)` in Timelock.
- After 48h: one tx does swap + deposit atomically.
- Observable on-chain. Slippage-guarded. Router-whitelisted. Non-custodial.

This is the only clean path. All current options require trust and off-chain coordination.

## 8.7 Summary table — simulation end state

| Metric | Event 1 | Event 2 | Event 3 | Event 4 |
|---|---|---|---|---|
| LUMINA price | $0.036 | $0.036 | $0.01 | $0.0005 |
| BondVault LUMINA | 70M | 70M | 70M | 70M |
| totalCommittedUSD | $0 | $25,000 | $25,000 | $25,000 |
| maxCommitUSD | $1.26M | $1.26M | $350k | $17.5k |
| Solvency ratio | ∞ | 10,080% | 2,800% | 140% |
| Quadrant | HEALTHY-STABLE | ULTRA-STABLE | ULTRA-STABLE | HEALTHY-STABLE |
| Issuance works? | Yes | Yes | Yes | No (capacity) |
| Redemption works? | (nothing to redeem) | Yes (post-maturity) | Yes | No (MIN_REDEEM_PRICE) |
| Protocol can auto-refill vault? | — | — | — | **No** |

The simulation confirms: a price crash does NOT trigger a protocol response that replenishes BondVault. It only changes the solvency quadrant, which changes how the matrix splits INCOMING USDC among destinations that are all NOT BondVault.
