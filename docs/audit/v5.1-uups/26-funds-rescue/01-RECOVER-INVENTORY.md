# Audit V5.1 #26 — Recover Function Inventory

Enumerates every contract in V5.1 and its current `recoverToken` / stuck-fund rescue surface. Used as the baseline for PARTE 2 tests and PARTE 3 gap analysis.

**Protocol scope:** 24 UUPS contracts + FounderVesting (immutable).

---

## 1. Contracts WITH recoverToken

### 1.1 TWAPBurner — `src/core/TWAPBurner.sol:382-386`

```solidity
function recoverToken(address token, uint256 amount) external onlyOwner {
    require(token != address(usdc), "Cannot recover USDC");
    require(token != address(lumina), "Cannot recover LUMINA");
    IERC20(token).safeTransfer(owner(), amount);
}
```

- **Access:** `onlyOwner` (Gnosis Safe in prod).
- **Blacklist:** `usdc`, `lumina` — the two tokens that legitimately flow through this contract.
- **Destination:** `owner()` (hardcoded).
- **Event:** **NONE** (observability gap — flagged as LOW).
- **Amount guard:** none explicitly, but `safeTransfer` reverts on underflow if `amount > balance`.

### 1.2 MaintenanceReserve — `src/treasury/MaintenanceReserve.sol:130-134`

```solidity
function recoverToken(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(token != address(usdc), "Cannot recover USDC");
    IERC20(token).safeTransfer(msg.sender, amount);
    emit TokenRecovered(token, amount);
}
```

- **Access:** `DEFAULT_ADMIN_ROLE`.
- **Blacklist:** `usdc` only — the token this contract legitimately holds.
- **Destination:** `msg.sender` (caller-chosen vs hardcoded: note — caller is the admin in practice).
- **Event:** `TokenRecovered(address indexed token, uint256 amount)`.
- **Amount guard:** `safeTransfer` underflow revert.

**Observation:** LUMINA is NOT blacklisted on MaintenanceReserve. This is intentional — MaintenanceReserve is a USDC-only holder, so LUMINA accidentally landing there should be rescuable.

---

## 2. Contracts WITHOUT recoverToken

The vast majority of contracts in V5.1 do not expose any rescue surface. Any ERC-20 (other than their core role token) sent accidentally becomes stuck.

| Contract | Holds (by design) | Could receive accidentally | Rescue path today |
|---|---|---|---|
| **BondVault** | LUMINA (70M initial), ClaimBonds (via interface) | Any ERC-20 / ERC-1155 | **NONE — stuck** |
| **ClaimBond** | Its own ERC-1155 bond balances | Any ERC-20 / other ERC-1155 / ERC-721 | **NONE — stuck** |
| **CoverRouterV2** | USDC (transient — approved to TWAPBurner same-tx) | Any ERC-20 | **NONE — stuck** |
| **PolicyManagerV2** | No tokens | Any ERC-20 | **NONE — stuck** |
| **BuybackEngine** | USDC (from TWAPBurner buyback bucket); Bonds (transient during `executeOffer`) | LUMINA; any other ERC-20 | **NONE — stuck** |
| **LuminaBondMarketplace** | USDC (transient during `executeBuy`); ClaimBonds (during listing escrow) | Any other ERC-20 | **NONE — stuck** |
| **CEXLiquidityReserve** | LUMINA (14M initial) | USDC; any other ERC-20 | **NONE — stuck** |
| **TreasuryVesting** | LUMINA (3M initial) | USDC; any other ERC-20 | **NONE — stuck** |
| **FounderVesting** | LUMINA (8M initial) | USDC; any other ERC-20 | **NONE — stuck AND cannot add (immutable)** |
| **LuminaTokenV2** | (token itself) | Any non-self ERC-20 | **NONE — stuck** |
| **CapacityOracle** | No tokens | Any ERC-20 | **NONE — stuck** |
| **SolvencyOracle** | No tokens | Any ERC-20 | **NONE — stuck** |
| **AdaptiveFeeDistributor** | No tokens | Any ERC-20 | **NONE — stuck** |
| **ShieldKeeper** | No tokens | Any ERC-20 | **NONE — stuck** |
| **BaseShield + 9 shields** | No tokens (Aave pass-through for RateShock) | Any ERC-20 | **NONE — stuck** |
| **AerodromeAdapter** | Transient during swap | Any other ERC-20 | **NONE — stuck** |
| **UniswapV3Adapter** | Transient during swap | Any other ERC-20 | **NONE — stuck** |

---

## 3. ETH handling

No contract in V5.1 declares `receive()` or `fallback()`. Direct `.call{value: x}` and `.send` to any protocol contract will revert. The only way ETH can enter is via `selfdestruct(target)` or post-Shanghai `SELFDESTRUCT`-equivalent force-sends (although Cancun deprecated this in mainnet EOA contexts, contracts with pre-existing SELFDESTRUCT obligations can still route ETH).

No `recoverETH` function exists on any contract. If ETH is force-sent, it is permanently stuck.

This is a low-likelihood concern (no caller motivation to selfdestruct ETH into protocol contracts) but a documented gap.

---

## 4. NFT / ERC-1155 handling

- **ERC-721:** no contract implements `onERC721Received`, so standard `safeTransferFrom` reverts at the destination. But a sender using unsafe `transferFrom` can deposit an NFT on any contract — becomes stuck.
- **ERC-1155 external:** `BondVault`, `BuybackEngine`, `LuminaBondMarketplace` inherit/interact with `ClaimBond` via `ERC1155Holder` (or equivalent acceptance). If an external ERC-1155 is sent via `safeTransferFrom`, they may accept it and it would be stuck because the `recoverToken` signature (IERC20) cannot move ERC-1155s.

---

## 5. Protected tokens (intentionally non-rescuable)

These are the "core" tokens each contract is supposed to hold. Rescue is permanently denied so admin cannot drain user funds:

| Contract | Protected token | Why |
|---|---|---|
| TWAPBurner | USDC | Legitimate premium channel |
| TWAPBurner | LUMINA | Transient post-swap, burned same-tx |
| MaintenanceReserve | USDC | Sole operational holding |
| BondVault | LUMINA + ClaimBond | (blacklist would be required if `recoverToken` existed) |
| CEXLiquidityReserve | LUMINA | (blacklist would be required if `recoverToken` existed) |
| TreasuryVesting | LUMINA | (blacklist would be required if `recoverToken` existed) |
| FounderVesting | LUMINA | (already impossible to rescue — immutable + no fn) |

---

## 6. Drain-risk analysis (admin malicious scenario)

### 6.1 Can a compromised admin drain protocol core tokens via `recoverToken`?

**NO**, for the two contracts that HAVE `recoverToken`:

- **TWAPBurner:** USDC + LUMINA are blacklisted. Admin cannot drain them through this path. ✅
- **MaintenanceReserve:** USDC is blacklisted. LUMINA is NOT (by design — it's not a core holding). Admin can extract LUMINA if accidentally deposited, which is acceptable. ✅

### 6.2 Residual admin-drain surface

Admin can always drain via the contracts' primary business functions if those are admin-gated (e.g., `MaintenanceReserve.spend`). But that is covered by other audits (admin-key-risk, #17).

### 6.3 Can any non-admin drain via `recoverToken`?

**NO.** Both functions are gated — `onlyOwner` and `onlyRole(DEFAULT_ADMIN_ROLE)` respectively.

---

## 7. Summary matrix

| Capability | TWAPBurner | MaintenanceReserve | Every other contract |
|---|---|---|---|
| `recoverToken(address,uint256)` | ✅ | ✅ | ❌ |
| Blacklist of core tokens | ✅ (USDC+LUMINA) | ✅ (USDC) | N/A |
| Access control | onlyOwner | DEFAULT_ADMIN_ROLE | N/A |
| Emits event | ❌ (gap) | ✅ | N/A |
| Destination hardcoded | ✅ (owner) | ✅ (msg.sender) | N/A |
| ETH rescue | ❌ | ❌ | ❌ |
| ERC-721 rescue | ❌ | ❌ | ❌ |
| ERC-1155 non-core rescue | ❌ | ❌ | ❌ |

Overall: the protocol has two rescue hatches in the right places (the two contracts with frequent incoming tokens) and no rescue hatch in the 22+ other contracts. See REPORT.md for severity analysis and recommendations.
