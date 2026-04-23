# Audit V5.1 #18 — ClaimBond NFT Metadata: Report

**Branch:** `audit/v5.1-18-nft-metadata`
**Date:** 2026-04-23
**Verdict:** PARTIALLY COMPLIANT — ERC-1155 core + supply tracking + transfer + balance / events all spec-compliant. URI scheme is non-standard (`lumina://...`) and there is no `setBaseURI` admin path — both flagged as **MEDIUM** findings for V5.2 deployment readiness. No HIGH issues.

---

## 1. Summary

`ClaimBond` is a clean ERC-1155 implementation built on OpenZeppelin's audited base. Token ID encodes the maturity epoch (`YYYYMM`); face value is fixed at $1 USD per token; supply is tracked per-epoch via `ERC1155SupplyUpgradeable`. Bond ownership and transfer semantics work correctly — the marketplace and buyback flows already rely on these and are exercised by audits #16 and #17.

The gap is in **discoverability and presentation**: the `uri()` function is `pure` and returns `lumina://claimbond/<epoch>` — a custom scheme that no marketplace, wallet, or block explorer can resolve. There is no admin path to point at an HTTPS endpoint, no inline JSON metadata, no image. This is a deployment-readiness gap, not a security defect.

## 2. How the audit was conducted

- File: `test/audit/v5.1-uups/token-nft/NFTMetadata.t.sol` (27 tests).
- Real `ClaimBond` proxy + real `BondVault` proxy + supporting `LuminaTokenV2` / oracle stack.
- Tests cover: URI format, determinism, uniqueness; ERC-165 / ERC-1155 / Metadata-URI interface support; mint / transfer / burn semantics; balance and supply queries; epoch-metadata views; mint validation (epoch range, month, caller).
- Inventory and design notes in `01-METADATA-INVENTORY.md`.

## 3. What works

| Property | Test | Verdict |
|---|---|---|
| Non-empty URI | `URI_NonEmpty` | ✅ |
| URI contains epoch ID | `URI_ContainsEpochId` | ✅ |
| URI deterministic | `URI_Deterministic` | ✅ |
| URI unique per epoch | `URI_DifferentEpochs_DifferentURIs` | ✅ |
| Far-future epoch (209912) | `URI_FarFutureEpoch_StillFormatted` | ✅ |
| ERC-165 | `ERC165_Supported` | ✅ |
| ERC-1155 | `ERC1155_Supported` | ✅ |
| ERC-1155 Metadata URI | `ERC1155MetadataURI_Supported` | ✅ |
| Unknown selector rejected | `UnknownInterface_NotSupported` | ✅ |
| Same epoch → same URI for two holders | `SameEpoch_SameURI_AfterMintToTwoHolders` | ✅ |
| Transfer preserves URI | `Transfer_PreservesURI` | ✅ |
| Mint emits TransferSingle | `MintEmitsTransferSingleEvent` | ✅ |
| `balanceOf` correct | `BalanceOf_ReturnsCorrectAmount` | ✅ |
| `balanceOfBatch` works | `BalanceOfBatch_AcrossEpochs` | ✅ |
| `totalSupply` per epoch | `TotalSupply_PerEpoch` | ✅ |
| Supply drops on burn | `TotalSupply_DropsOnBurn` | ✅ |
| Face value = $1 | `FaceValue_IsOneDollar` | ✅ |
| Holder face value scales | `HolderFaceValue_ScalesWithBalance` | ✅ |
| Maturity date computed correctly | `MaturityDate_StoredCorrectly` | ✅ |
| `getEpochInfo` aggregates | `GetEpochInfo_AfterMint` | ✅ |
| `getEpochInfo` for non-existent epoch | `GetEpochInfo_NonExistent_ReturnsFalse` | ✅ |
| Mint below epoch range reverts | `Mint_BelowEpochRange_Reverts` | ✅ |
| Mint above epoch range reverts | `Mint_AboveEpochRange_Reverts` | ✅ |
| Mint with invalid month reverts | `Mint_InvalidMonth_Reverts` | ✅ |
| Non-vault mint reverts | `NonBondVault_Mint_Reverts` | ✅ |
| Current scheme documented | `URI_FixedScheme_LuminaPrefix` | ✅ |
| No setBaseURI documented | `NoBaseURISetter_Documented` | ✅ |

## 4. Findings

### 4.1 MEDIUM — `uri()` returns a non-standard `lumina://` scheme

**Observation:** The implementation returns `lumina://claimbond/<epoch>`, which is not a registered URL scheme. Wallets (MetaMask, Rabby), marketplaces (OpenSea, Magic Eden, Blur), and block explorers (BaseScan) cannot resolve this — they will display the bond as an unnamed ERC-1155 with no image, no description, no attributes.

**Impact:** Bonds will be tradable on-chain (via the protocol's own marketplace) but invisible / opaque on every third-party UI. This affects:
- Holder UX: users can't see what they own in their wallets.
- Secondary-market liquidity: third-party marketplaces won't list these bonds.
- Brand presentation: the bond appears as a generic untyped ERC-1155 rather than a LUMINA bond.

**Severity rationale:** MEDIUM, not HIGH, because the protocol's *internal* marketplace and buyback engine read on-chain views (`getFaceValue`, `getEpochInfo`, `maturityDate`) directly — they don't depend on the URI. No funds are at risk. But this is a launch-blocker for any user-facing third-party integration.

**Recommendation (V5.2):**

```solidity
string private _baseURI;

function setBaseURI(string calldata newBase) external onlyOwner {
    _baseURI = newBase;
    emit URI(uri(0), 0); // ERC-1155 spec: notify of URI change
}

function uri(uint256 epochId) public view override returns (string memory) {
    return string(abi.encodePacked(_baseURI, _epochToString(epochId), ".json"));
}
```

Plus an off-chain API at `https://api.lumina-org.com/metadata/<chainId>/<epoch>.json` that synthesises:

```json
{
  "name": "LUMINA Bond #202912",
  "description": "Claim bond maturing 2029-12. Face value $1 USD per token; settled in $LUMINA at market price at maturity.",
  "image": "https://api.lumina-org.com/img/<epoch>.svg",
  "decimals": 0,
  "attributes": [
    { "trait_type": "Epoch", "value": 202912 },
    { "trait_type": "Maturity", "value": "2029-12-01", "display_type": "date" },
    { "trait_type": "Face Value", "value": "$1.00 USD" },
    { "trait_type": "Status", "value": "Active" }
  ]
}
```

### 4.2 MEDIUM — No `setBaseURI` admin path; URI logic frozen until next UUPS upgrade

**Observation:** `uri()` is `pure` and the contract has no setter. To change the URI scheme post-deployment requires a full UUPS upgrade (which IS available, but it is heavier than a config update).

**Impact:** Operationally awkward. If the metadata API moves to a new URL, an upgrade is required. Standard ERC-1155 deployments expose a `setBaseURI` for exactly this reason.

**Recommendation:** Same as §4.1 — adding `setBaseURI` resolves both findings simultaneously.

### 4.3 LOW — No `name()` / `symbol()` for collection identification

**Observation:** OpenZeppelin's `ERC1155Upgradeable` doesn't expose collection-level `name()` / `symbol()` (those are ERC-721 conventions), but most marketplaces look for them anyway via the optional `IERC1155MetadataURI` extension or off-chain. Without them, collection cards show as generic.

**Recommendation:** Add public `string public name = "LUMINA Bonds"; string public symbol = "LBOND";` constants. Trivial change, no security impact.

### 4.4 INFO — No on-chain JSON metadata

**Observation:** All metadata depends on an off-chain API. For maximum decentralisation, an inline data-URI fallback (returning a base64-encoded JSON with an SVG image) would mean the bonds are self-describing without any external service.

**Recommendation (optional, V5.3+):** Implement `uri()` with a fallback: if `_baseURI` is empty, return a `data:application/json;base64,...` data-URI built from `getEpochInfo`. Useful for emergency / IPFS-pin scenarios.

## 5. Reverse audit

- **Total tests:** 27 (new)
- **% substantive:** 100 % — every test calls real `ClaimBond` proxy methods through the real `BondVault` mint path.
- **Quality:** 9/10 — comprehensive coverage of the implemented functionality (URI, interfaces, balances, supply, mint validation, transfer semantics) and explicit documentation of the gaps. The two MEDIUM findings are concrete, actionable, and scoped to a specific V5.2 upgrade.

## 6. Regression

```
forge test --no-match-contract "Fork" --no-match-path "test/audit/invariant*"
```

```
Ran 110 test suites in 19.33s (98.97s CPU time): 1736 tests passed, 0 failed, 0 skipped (1736 total tests)
```

Baseline before audit was 1709. Delta = +27 new tests.

## 7. Verdict

**PARTIALLY COMPLIANT.** The ERC-1155 core + supply + transfer + face-value + maturity tracking are spec-compliant and production-ready for the protocol's internal use. The URI gap (§4.1, §4.2) needs a V5.2 upgrade before any third-party marketplace or wallet integration. No HIGH severity issues; no funds at risk. The two MEDIUM findings have a concrete, low-risk recommendation: add `setBaseURI` + point to an HTTPS metadata API.
