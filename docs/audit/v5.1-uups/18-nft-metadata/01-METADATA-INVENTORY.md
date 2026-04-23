# Audit V5.1 #18 — ClaimBond NFT Metadata: Inventory

**Target:** LUMINA Protocol V5.1 — `src/bonds/ClaimBond.sol` (ERC-1155 bond NFT)
**Date:** 2026-04-23

---

## 1. Current implementation

### 1.1 Token model

- `ClaimBond` extends `ERC1155Upgradeable` + `ERC1155SupplyUpgradeable` + `OwnableUpgradeable` + `UUPSUpgradeable`.
- Token ID = epoch in `YYYYMM` integer form (e.g., `202912` = December 2029).
- One token = $1 USD face value (`getFaceValue` returns `1e18`).
- Mintable / burnable only by `BondVault` (via `onlyBondVault` modifier); plus a `burnByHolder` path that the `BuybackEngine` uses for double-burn.
- `setBondVault` is one-shot, owner-only — anti-frontrun.

### 1.2 URI implementation

```solidity
function uri(uint256 epochId) public pure override returns (string memory) {
    return string(abi.encodePacked("lumina://claimbond/", _epochToString(epochId)));
}
```

- Function is `pure` — reads no state.
- No `_baseURI` storage variable, no `setBaseURI` admin function.
- Returns a custom `lumina://` scheme rather than `https://` or `ipfs://`.
- ID is appended as a 6-character zero-padded string (`_epochToString`).

### 1.3 Epoch metadata stored on-chain

| Field | Source | Notes |
|---|---|---|
| `epochExists[id]` | mint side-effect | first mint into an epoch initialises this |
| `maturityDate[id]` | mint side-effect | derived from epoch via `_timestampFromYearMonth` |
| Face value | `getFaceValue(id)` | always `1e18` for any existing epoch |
| Total supply | inherited `totalSupply(id)` | tracked by `ERC1155SupplyUpgradeable` |
| Maturation | `isMatured(id)` | `block.timestamp >= maturityDate[id]` |
| `getEpochInfo(id)` | aggregate view | returns the four above as a tuple |

### 1.4 Interface support (verified by tests)

| Selector | Standard | Supported |
|---|---|---|
| `0x01ffc9a7` | ERC-165 | ✅ |
| `0xd9b67a26` | ERC-1155 | ✅ |
| `0x0e89341c` | ERC-1155 Metadata URI | ✅ |

## 2. Standards compliance

### 2.1 ERC-1155 ✅

`balanceOf`, `balanceOfBatch`, `safeTransferFrom`, `safeBatchTransferFrom`, `setApprovalForAll`, `isApprovedForAll` — all inherited from OpenZeppelin's audited implementation. Tests confirm:

- `balanceOf` returns the correct count (`test_NFT_UUPS_BalanceOf_ReturnsCorrectAmount`).
- `balanceOfBatch` works across epochs (`test_NFT_UUPS_BalanceOfBatch_AcrossEpochs`).
- `totalSupply` per epoch tracked via `ERC1155SupplyUpgradeable` (`test_NFT_UUPS_TotalSupply_PerEpoch`, `test_NFT_UUPS_TotalSupply_DropsOnBurn`).
- `safeTransferFrom` preserves URI semantics (`test_NFT_UUPS_Transfer_PreservesURI`).
- Mint emits `TransferSingle` per spec (`test_NFT_UUPS_MintEmitsTransferSingleEvent`).

### 2.2 ERC-1155 Metadata URI ⚠️

The interface is *technically* compliant (function returns a non-empty `string`), but the URI scheme is non-standard:

- `lumina://claimbond/202912` is not a resolvable URL by OpenSea / MetaMask / Magic Eden / Etherscan.
- No JSON metadata is delivered — neither inline (data URI) nor via HTTPS endpoint.
- Wallets and marketplaces will display the bond as an unknown ERC-1155 token with no name, image, or attributes.

This is the central finding of the audit; full discussion in REPORT.md §4.

## 3. What's NOT implemented (by design or by gap)

| Item | Status | Production-ready? |
|---|---|---|
| `name` (collection name) | ❌ no | needed |
| `symbol` (collection symbol) | ❌ no | needed |
| `description` per token | ❌ no | needed (e.g., "LUMINA Bond — matures 2029-12") |
| `image` per token | ❌ no | needed (SVG generative or static) |
| `attributes` (OpenSea filters) | ❌ no | nice-to-have |
| `setBaseURI` admin path | ❌ no | needed if pointing to off-chain API |
| `URI` event on changes | ❌ no | n/a (nothing changes) |
| Generative SVG | ❌ no | nice-to-have |
| IPFS pinning | ❌ no | needed for long-term decentralisation |

## 4. Recommended path to production (full discussion in REPORT)

The minimal upgrade for a marketplace-friendly bond NFT is:

1. **V5.2 upgrade**: rewrite `uri()` to emit `https://api.lumina-org.com/metadata/<chainId>/<tokenId>.json` (or similar), replacing the `pure` modifier with a `view` that reads a settable `_baseURI` storage slot.
2. **`setBaseURI(string)`** restricted to `onlyOwner`, emitting `URI(newuri, 0)` per ERC-1155 spec.
3. **Off-chain API** that synthesises the per-epoch JSON from the on-chain `getEpochInfo` view (no extra writes needed).
4. **Optional fallback to data URI** with an inline SVG so wallets work without the API.

These are V5.2-scope changes. This audit *does not* apply them — it documents the gap and verifies what currently works.
