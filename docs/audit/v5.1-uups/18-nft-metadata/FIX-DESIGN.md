# Fix V5.1 #18 — NFT Metadata + Restricted Transfers — Design

**Resolves:** audit V5.1 #18 — §4.1 MEDIUM (lumina:// scheme), §4.2 MEDIUM (no setBaseURI), §4.3 LOW (no name/symbol).
**Founder decision:** bonds tradeable ONLY through Lumina Marketplace + BuybackEngine. Direct ERC-1155 transfers blocked.
**Branch:** `fix/v5.1-nft-metadata-restricted`

---

## 1. Goals

1. URI returns standard HTTPS URLs (`https://api.lumina-org.com/metadata/bond/<epoch>.json`).
2. Admin can update the base URI via `setBaseURI`.
3. `name()` / `symbol()` for marketplace and explorer compatibility.
4. Direct user-to-user `safeTransferFrom` is blocked. Only authorized operators (initially Marketplace and BuybackEngine) can transfer between non-zero parties.
5. Mint (`from == 0`) and burn (`to == 0`) remain unrestricted — needed for bond issuance and redemption.
6. **Storage layout preserved** — UUPS upgrade compatibility.

## 2. Storage layout

ClaimBond does NOT use ERC-7201 namespaced storage; it uses a regular layout with an explicit `__gap[50]`. New fields take from the gap.

Before:

```
slot 0  : bondVault (address, 20b) + _bondVaultSet (bool, 1b)
slot 1  : maturityDate
slot 2  : epochExists
slot 3..52 : __gap[50]
```

After:

```
slot 0  : bondVault (address, 20b) + _bondVaultSet (bool, 1b)   ← unchanged
slot 1  : maturityDate                                            ← unchanged
slot 2  : epochExists                                             ← unchanged
slot 3  : _baseURI (string, 1 slot for length+pointer)            ← NEW
slot 4  : authorizedOperators (mapping)                           ← NEW
slot 5..52 : __gap[48]                                            ← shrunk
```

Total slots used = unchanged. Existing slots (0–2) are bit-identical. UUPS upgrade is safe.

## 3. Code changes (`src/bonds/ClaimBond.sol`)

### 3.1 New imports

```solidity
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
```

### 3.2 New state (taken from `__gap`)

```solidity
string private _baseURI;                          // slot 3
mapping(address => bool) public authorizedOperators; // slot 4
uint256[48] private __gap;                        // shrunk from 50
```

### 3.3 New initializer-side default

```solidity
function initialize() public initializer {
    __ERC1155_init("");
    __ERC1155Supply_init();
    __Ownable_init(msg.sender);
    __UUPSUpgradeable_init();
    _baseURI = "https://api.lumina-org.com/metadata/bond/";
}
```

For UUPS upgrade of an already-deployed proxy, admin can call `setBaseURI` post-upgrade with the same default; the new `_baseURI` slot is initialized to the empty string by `_update`-style ABI on upgrade so we explicitly seed it.

For migration of already-initialised proxies, also expose a one-shot reinitialize:

```solidity
function reinitializeURI(uint64 version) external reinitializer(version) {
    _baseURI = "https://api.lumina-org.com/metadata/bond/";
}
```

(Not strictly needed for the fresh-deploy case; add for upgrade safety.)

### 3.4 New setters

```solidity
event BaseURIUpdated(string oldBaseURI, string newBaseURI);
event OperatorAuthorized(address indexed operator, bool authorized);

function setBaseURI(string calldata newBaseURI) external onlyOwner {
    string memory old = _baseURI;
    _baseURI = newBaseURI;
    emit BaseURIUpdated(old, newBaseURI);
    emit URI(uri(0), 0); // ERC-1155 spec notification (id=0 = collection-wide change)
}

function setAuthorizedOperator(address operator, bool authorized) external onlyOwner {
    require(operator != address(0), "ClaimBond: zero address");
    authorizedOperators[operator] = authorized;
    emit OperatorAuthorized(operator, authorized);
}
```

### 3.5 Override `uri`

```solidity
function uri(uint256 epochId) public view override returns (string memory) {
    return string(abi.encodePacked(_baseURI, _epochToString(epochId), ".json"));
}
```

Note: was `pure` → now `view` (reads `_baseURI`).

### 3.6 `name()` / `symbol()`

```solidity
function name() external pure returns (string memory) {
    return "LUMINA Bonds";
}

function symbol() external pure returns (string memory) {
    return "LBOND";
}
```

### 3.7 Restricted `_update`

```solidity
function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
    internal
    override(ERC1155Upgradeable, ERC1155SupplyUpgradeable)
{
    // Allow mint (from == 0) and burn (to == 0) unconditionally.
    if (from != address(0) && to != address(0)) {
        require(
            authorizedOperators[msg.sender] || authorizedOperators[from],
            "ClaimBond: transfers only via authorized operators"
        );
    }
    super._update(from, to, ids, values);
}
```

Why `msg.sender || from` (not just `msg.sender`)?

- Marketplace is whitelisted. When marketplace receives the bond from a seller via `claimBond.safeTransferFrom(seller, marketplace, ...)`, `msg.sender == marketplace`, so the check passes.
- When marketplace later transfers the bond OUT (cancel back to seller, or buy to buyer), `msg.sender == marketplace` AND `from == marketplace`, both authorised — no change.
- The `from` branch lets us also accept a transfer initiated by a contract whose address equals an authorised operator, even if `msg.sender` is something else (e.g., a router). Defensive.

## 4. Whitelist wiring

`Marketplace` and `BuybackEngine` are deployed AFTER `ClaimBond` in the canonical setUp, so we cannot hard-code them in `initialize()`. Instead:

- Admin calls `claimBond.setAuthorizedOperator(marketplace, true)` post-deploy.
- Admin calls `claimBond.setAuthorizedOperator(buybackEngine, true)` post-deploy.

For test fixtures (DeployE2ETest + every other setup that uses marketplace), we add these two calls after the marketplace and buybackEngine are deployed.

In `ProxyDeployer.sol`, we add a small helper `wireClaimBondMarketplaceOperator(claimBond, marketplace, buybackEngine)` so test files can opt-in.

## 5. Test impact

**Expected new tests:** ~20 in `NFTMetadataFix.t.sol` covering URI, setBaseURI, name/symbol, restricted transfers, marketplace whitelist, BuybackEngine whitelist, batch transfer block, ERC-1155 compliance, lifecycle integration, storage preservation.

**Expected breakage in existing tests:**
- Any test that does direct `claimBond.safeTransferFrom(holder, otherUser, …)` outside of the marketplace path will now revert.
- Any test that uses the marketplace WITHOUT first whitelisting it will revert.

Both are addressed by:
- Updating the few existing tests that do direct transfers (very rare — bonds aren't typically user-transferred).
- Updating any setUp that uses marketplace to call `setAuthorizedOperator(marketplace, true)`.

## 6. Risk

**Low.**

- The `_update` override is the only behavioural change. Mint and burn are explicitly unguarded; existing core flows (issueBond, redeemBond, double-burn) remain unchanged.
- Storage layout is provably preserved (slots 0–2 unchanged, gap shrunk).
- New fields are owner-controlled; no economic surface.
- Reverse-compatible: setting `_baseURI = ""` returns `https-blank-prefix + epoch + ".json"`, still a (broken) string — no panic. Admin must seed correctly.

## 7. Deployment / migration

**Fresh deploy:** `initialize()` seeds `_baseURI`. Admin then calls `setAuthorizedOperator(marketplace, true)` and `setAuthorizedOperator(buybackEngine, true)`.

**Upgrade existing proxy:** call `reinitializeURI(2)` once after upgrading the impl, then the same two `setAuthorizedOperator` calls.

(See FIX-REPORT.md after implementation for the actual numbers.)
