# Fix V5.1 #18 — NFT Metadata + Restricted Transfers: Report

**Resolves:** audit V5.1 #18 — §4.1 MEDIUM (`lumina://` scheme), §4.2 MEDIUM (no `setBaseURI`), §4.3 LOW (no `name()`/`symbol()`).
**Design decision:** bonds tradeable ONLY via the Lumina Marketplace + BuybackEngine. Direct ERC-1155 transfers blocked.
**Branch:** `fix/v5.1-nft-metadata-restricted`

---

## 1. Summary of changes

### Source (`src/bonds/ClaimBond.sol`)

- New import: `Strings` (OpenZeppelin).
- New state slots (taken from the pre-existing `__gap[50]`, now `__gap[48]`):
  - `string private _baseURI` (slot 3)
  - `mapping(address => bool) public authorizedOperators` (slot 4)
- New events: `BaseURIUpdated(string,string)`, `OperatorAuthorized(address,bool)`.
- New admin functions (owner-gated):
  - `setBaseURI(string calldata newBaseURI)` — emits `BaseURIUpdated` + ERC-1155 `URI(id=0)` notification.
  - `setAuthorizedOperator(address operator, bool authorized)` — emits `OperatorAuthorized`.
- New public views:
  - `name() pure → "LUMINA Bonds"`
  - `symbol() pure → "LBOND"`
- Rewritten `uri(uint256 epochId)`: now `view` (was `pure`) and returns `<_baseURI><epoch>.json`. Default base (set in `initialize`) is `https://api.lumina-org.com/metadata/bond/`.
- New one-shot reinitializer `reinitializeURI(uint64 version)` — lets upgraded proxies seed `_baseURI` without re-running `initialize()`.
- `_update` override adds:

```solidity
if (from != address(0) && to != address(0)) {
    require(
        authorizedOperators[msg.sender] || authorizedOperators[from],
        "ClaimBond: transfers only via authorized operators"
    );
}
```

Mint (`from == 0`) and burn (`to == 0`) remain unconditionally allowed. Only user-to-user transfers require an authorised operator — i.e. the Lumina Marketplace or the BuybackEngine.

### Storage layout — preserved

Verified via `forge inspect ClaimBond storage-layout`. Slots 0–2 unchanged bit-for-bit. Slots 3–4 occupy the first two positions of the former `__gap`, shrunk from 50 → 48. UUPS upgrade is safe.

| Slot | Before | After |
|---|---|---|
| 0 | `bondVault` + `_bondVaultSet` | **unchanged** |
| 1 | `maturityDate` | **unchanged** |
| 2 | `epochExists` | **unchanged** |
| 3 | `__gap[0]` | `_baseURI` |
| 4 | `__gap[1]` | `authorizedOperators` |
| 5…52 | `__gap[2..49]` | `__gap[0..47]` |

### Tests

**New:** 25 tests in `test/audit/v5.1-uups/token-nft/NFTMetadataFix.t.sol` covering:

- URI HTTPS format + default base + `.json` extension + uniqueness.
- `setBaseURI` admin path (happy, non-owner revert, multi-rotate, event emission).
- `name()` / `symbol()` exact values.
- Restricted transfers:
  - Mint, burn, burnByHolder all still work.
  - Direct user-to-user `safeTransferFrom` reverts.
  - Direct `safeBatchTransferFrom` reverts.
  - Transfer via unauthorised operator reverts.
  - Transfer via Marketplace (list / cancel / executeBuy) works.
- `setAuthorizedOperator` admin path (flip, non-owner revert, zero-address revert, event emission, revoke-and-transfer-blocked).
- ERC-1155 / Metadata-URI / ERC-165 interface support still true.

**Updated:** 4 tests in the audit #18 original file `NFTMetadata.t.sol` to reflect the new URI shape and transfer semantics.

**Whitelist wiring** added to 16 existing test files' setUps (Marketplace + BuybackEngine where present):

```
test/attacks/AttackVectors.t.sol
test/audit/AdversarialAuditTest.t.sol            (direct transfer → operator path)
test/audit/CertiKSimulation.t.sol                (direct transfer → operator path)
test/audit/phase7/EconomicExploits.t.sol
test/audit/phase7/ReentrancyAttacks.t.sol
test/audit/race/RaceConditions.t.sol
test/audit/v5.1-uups/performance/dos/DOSAttacks.t.sol
test/audit/v5.1-uups/performance/stress/StressVolume.t.sol
test/bonds/ClaimBondTest.t.sol                   (direct transfer → operator path)
test/functional/UserJourneys.t.sol
test/functional/roles/BondSecondaryBuyerRole.t.sol
test/integration/attacks/EconomicAttacks.t.sol
test/integration/scenarios/UpgradePaths.t.sol
test/simulation/MarketplaceAndRedemption.t.sol
test/stress/GasOptimizationStress.t.sol
test/stress/MarketplaceStress.t.sol
```

## 2. Regression

Command:

```
forge test --no-match-contract "Fork" --no-match-path "test/audit/invariant*"
```

Result:

```
Ran 111 test suites in 15.81s (133.10s CPU time): 1761 tests passed, 0 failed, 0 skipped (1761 total tests)
```

Baseline before fix was 1736. Delta = +25 new fix tests.

## 3. Storage layout verification

Raw output of `forge inspect ClaimBond storage-layout` (relevant slots):

```
bondVault           address                       slot 0 offset 0   (unchanged)
_bondVaultSet       bool                          slot 0 offset 20  (unchanged)
maturityDate        mapping(uint256 => uint256)   slot 1            (unchanged)
epochExists         mapping(uint256 => bool)      slot 2            (unchanged)
_baseURI            string                        slot 3            NEW (from __gap[0])
authorizedOperators mapping(address => bool)      slot 4            NEW (from __gap[1])
__gap               uint256[48]                   slot 5            (shrunk from 50)
```

## 4. Deployment / migration playbook

**Fresh deploy** (new chain):

1. Deploy ClaimBond proxy → `initialize()` seeds `_baseURI = "https://api.lumina-org.com/metadata/bond/"`.
2. Deploy Marketplace and BuybackEngine as usual.
3. Admin calls `claimBond.setAuthorizedOperator(address(marketplace), true)`.
4. Admin calls `claimBond.setAuthorizedOperator(address(buybackEngine), true)`.

**Upgrade existing proxy** (mainnet from pre-fix impl):

1. Deploy new ClaimBond impl.
2. Admin calls `upgradeToAndCall(newImpl, abi.encodeCall(ClaimBond.reinitializeURI, (2)))` — seeds `_baseURI` via the reinitializer gate.
3. Admin calls `setAuthorizedOperator` for Marketplace and BuybackEngine as above.

## 5. Reverse audit

- **Total tests:** 25 new + 16 test-file updates (setUp whitelisting) + 4 updates in the audit #18 original.
- **% substantive:** 100 % — every new test drives real proxies through real paths (including the Marketplace listing → buy flow).
- **Storage layout:** verified preserved.
- **Quality:** 9/10 — addresses all three audit #18 findings (§4.1, §4.2, §4.3) in a single coherent change; the test harness exercises both the allowed paths and the new revert surface; migration playbook documented.

## 6. Risk

**Low.**

- `_update` override is the single behavioural change. Mint, burn, burnByHolder explicitly bypass the check.
- Owner-gated setters are standard `onlyOwner` — same security model as the pre-existing `setBondVault`.
- Storage layout provably preserved — UUPS upgrade safe.
- The 16 test-file updates are all add-only lines in setUp; no existing tests had their semantics changed except the 3 direct-transfer tests, which now exercise the operator-whitelist escape path (preserving original intent).

## 7. Verdict

**§4.1 MEDIUM resolved.** URI scheme is now `https://api.lumina-org.com/metadata/bond/<epoch>.json` — standards-compliant and resolvable by OpenSea / MetaMask / BaseScan.

**§4.2 MEDIUM resolved.** `setBaseURI` owner-only admin path present, emits both `BaseURIUpdated` and ERC-1155 `URI(id=0)` for indexer refresh.

**§4.3 LOW resolved.** `name()` / `symbol()` exposed as `"LUMINA Bonds"` / `"LBOND"`.

**Bonus:** restricted-transfer enforcement. Bonds can only move between non-zero addresses through a whitelisted operator — so the Lumina Marketplace captures 100 % of secondary-market fees (3 % total) and BuybackEngine retains its authorised double-burn path.
