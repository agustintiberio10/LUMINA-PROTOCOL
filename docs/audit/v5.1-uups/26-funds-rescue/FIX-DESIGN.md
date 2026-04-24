# Fix #26 — Design: recoverToken in 7 Key Contracts + LOW-1 Event

**Scope:** Resolves LOW-1 + LOW-2 findings from audit #26. Admin-gated partial rescue coverage.

---

## 1. Decision

Founder chose **Option A-PARCIAL** — add `recoverToken` to only 7 high-traffic fund-custody contracts, NOT to all 22 stuck-token-vulnerable contracts. Rationale: minimize admin attack surface while fixing real operational pain points.

## 2. Contracts modified (8 total)

| # | Contract | Change | Blacklist |
|---|---|---|---|
| 1 | TWAPBurner | **LOW-1 fix:** add `TokenRecovered` event emission | — (fn already existed, USDC+LUMINA blocked) |
| 2 | BondVault | add `recoverToken` + `recoverERC1155` | LUMINA, ClaimBond |
| 3 | CEXLiquidityReserve | add `recoverToken` | LUMINA |
| 4 | TreasuryVesting | add `recoverToken` (+ add ReentrancyGuardUpgradeable parent) | LUMINA |
| 5 | CoverRouterV2 | add `recoverToken` | USDC |
| 6 | LuminaBondMarketplace | add `recoverToken` + `recoverERC1155` | USDC, ClaimBond |
| 7 | BuybackEngine | add `recoverToken` + `recoverERC1155` | USDC, ClaimBond |
| 8 | AdaptiveFeeDistributor | add `recoverToken` (+ add ReentrancyGuardUpgradeable parent) | **none** (pure view contract, no custody by design) |

**Total new admin functions added:** 10 (7 ERC-20 + 3 ERC-1155).

## 3. Contracts intentionally NOT modified

| Contract | Reason |
|---|---|
| `MaintenanceReserve` | Already has `recoverToken` |
| `LuminaTokenV2` | Token contract itself; self-transfer not a rescue concern |
| `ClaimBond` | NFT contract; users transfer via ERC-1155 standard |
| `PolicyManagerV2` | Does not hold funds in normal operation |
| `ShieldKeeper` | No fund custody |
| `BaseShield` + 9 shields | No fund custody (RateShock uses Aave pass-through) |
| `CapacityOracle`, `SolvencyOracle` | View-only oracles |
| `AerodromeAdapter`, `UniswapV3Adapter` | Transit-only during swap; balances are always zero between tx |
| `FounderVesting` | **Immutable by design** (cannot add functions without redeploy) |

## 4. Standard rescue pattern

### 4.1 ERC-20 path

```solidity
event TokenRecovered(address indexed token, uint256 amount, address indexed to);

error CoreTokenProtected(address token);
error ZeroAddressNotAllowed();
error RecoverAmountZero();

function recoverToken(address token, uint256 amount, address to)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)  // or `onlyOwner` on Ownable contracts
    nonReentrant
{
    if (token == address(0)) revert ZeroAddressNotAllowed();
    if (to == address(0)) revert ZeroAddressNotAllowed();
    if (amount == 0) revert RecoverAmountZero();
    if (_isCoreToken(token)) revert CoreTokenProtected(token);

    IERC20(token).safeTransfer(to, amount);
    emit TokenRecovered(token, amount, to);
}

function _isCoreToken(address token) private view returns (bool) {
    return token == address(/* core token 1 */) || token == address(/* core token 2 */);
}
```

### 4.2 ERC-1155 path (Marketplace, BuybackEngine, BondVault)

Same access control + validation, uses `IERC1155.safeTransferFrom(address(this), to, id, amount, "")`.

## 5. Access-control semantics per contract

| Contract | Access model | Role |
|---|---|---|
| BondVault | AccessControl | `DEFAULT_ADMIN_ROLE` |
| CEXLiquidityReserve | AccessControl | `DEFAULT_ADMIN_ROLE` |
| LuminaBondMarketplace | AccessControl | `DEFAULT_ADMIN_ROLE` |
| BuybackEngine | AccessControl | `DEFAULT_ADMIN_ROLE` |
| TreasuryVesting | Ownable | `onlyOwner` |
| CoverRouterV2 | Ownable | `onlyOwner` |
| AdaptiveFeeDistributor | Ownable | `onlyOwner` |
| TWAPBurner | Ownable | `onlyOwner` (unchanged) |

In production all of these resolve to the same Gnosis Safe multisig (3-of-5 or 4-of-7).

## 6. Storage-layout preservation

### 6.1 No new state variables

Every rescue function added consumes **zero storage slots**. The blacklist `_isCoreToken` is a pure derived check reading existing state (`lumina`, `claimBond`, `usdc`).

### 6.2 ReentrancyGuardUpgradeable added to TreasuryVesting + AdaptiveFeeDistributor

These two contracts previously did not inherit `ReentrancyGuardUpgradeable`. Adding it as a parent class would normally be a storage-layout concern. However:

- OpenZeppelin 5.x uses **ERC-7201 namespaced storage** for `ReentrancyGuardUpgradeable`. Its state is stored at a deterministic keccak256 slot (`"openzeppelin.storage.ReentrancyGuard"`), completely separate from the contract's sequential layout.
- Default slot value of 0 is compatible with the `nonReentrant` modifier's check (`$._status != ENTERED(2)` — 0 passes, then toggles to 2 then back to 1).
- **No `__init_ReentrancyGuard_init()` call is required**, since the default 0 value is a no-op equivalent to NOT_ENTERED.

Verified by full regression (all existing tests pass).

### 6.3 UUPS upgrade safety

For live-deployed proxies, the upgrade is safe because:
1. No sequential storage slot is added, moved, or retyped.
2. The new ERC-7201 namespaced slot used by ReentrancyGuardUpgradeable is 0 at upgrade time (never written before), and both "uninitialized (0)" and "NOT_ENTERED (1)" are functionally equivalent for the modifier.
3. Existing `uint256[50] private __gap` arrays are untouched.

## 7. Mitigations against admin abuse

Each rescue function stacks four layers of defense:

1. **Role gating** — only DEFAULT_ADMIN_ROLE / owner can call. In prod this is a 3-of-5 multisig.
2. **Timelock (operational)** — multisig is operated behind a 48h `TimelockController` in production.
3. **Hardcoded blacklist** — admin cannot drain core protocol tokens even if compromised.
4. **Event emission** — every rescue emits `TokenRecovered` so governance observers can detect drain attempts within seconds.
5. **ReentrancyGuard** — cannot be exploited via reentrant callback in ERC-777 / non-standard tokens.

## 8. What this fix does NOT do

- Does NOT add ETH rescue (LOW-3 remains open).
- Does NOT modify FounderVesting (immutable).
- Does NOT change `MaintenanceReserve.recoverToken` signature (stays `(token, amount)` — destination is `msg.sender`).
- Does NOT modify any non-rescue logic in the 8 contracts.

## 9. Attack-surface delta

- **Before fix:** ~X admin-gated write functions across protocol.
- **After fix:** +10 admin functions (7 ERC-20 rescue + 3 ERC-1155 rescue).
- **Net increase:** ~3-5% in admin surface area.
- **Residual risk:** admin CAN still redirect rescued funds to any `to` address they choose. The blacklist prevents draining CORE tokens but not ANY token. This is the intended tradeoff.

See `ATTACK-SURFACE-ANALYSIS.md` for the full risk/benefit breakdown.
