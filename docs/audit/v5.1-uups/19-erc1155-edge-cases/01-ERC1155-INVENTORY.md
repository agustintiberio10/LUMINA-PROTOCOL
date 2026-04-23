# Audit V5.1 #19 — ERC-1155 Edge Cases: Inventory

**Target:** `src/bonds/ClaimBond.sol` (ERC-1155 bond NFT, post fix-#18)
**Date:** 2026-04-23

---

## 1. Surface audited

### 1.1 Standard functions (inherited from OpenZeppelin `ERC1155Upgradeable` + `ERC1155SupplyUpgradeable`)

- `balanceOf(address, uint256)`
- `balanceOfBatch(address[], uint256[])`
- `safeTransferFrom(from, to, id, amount, data)`
- `safeBatchTransferFrom(from, to, ids[], amounts[], data)`
- `setApprovalForAll(operator, approved)`
- `isApprovedForAll(account, operator)`
- `supportsInterface(bytes4)`
- `totalSupply(uint256)` (from `ERC1155SupplyUpgradeable`)

### 1.2 Protocol-specific functions

- `mint(address, uint256 epochId, uint256 usdAmount)` — onlyBondVault
- `burn(address, uint256 epochId, uint256 usdAmount)` — onlyBondVault
- `burnByHolder(address account, uint256 epochId, uint256 amount)` — account or approved

### 1.3 Fix-#18 overrides / additions

- `uri(uint256 epochId)` — HTTPS base + epoch + `.json`
- `name()` / `symbol()` — pure constants
- `setBaseURI(string)` — owner admin
- `setAuthorizedOperator(address, bool)` — owner admin
- `authorizedOperators(address)` — public mapping
- `_update(from, to, ids, values)` override — restricts non-zero↔non-zero transfers to whitelisted operators

## 2. Edge-case matrix

| # | Category | Scenario | Test |
|---|---|---|---|
| 1 | Transfer target | to == holder (self) via operator | `Transfer_ToSelf_ViaOperator_NoBalanceChange` |
| 2 | | holder → holder direct | `Transfer_HolderToHolder_Direct_Blocked` (fix-#18) |
| 3 | | to == address(0) | `Transfer_ToZeroAddress_Reverts_OZ` |
| 4 | | to = EOA via operator | `Transfer_ToEOA_SucceedsViaOperator` |
| 5 | | to = contract without `onERC1155Received` | `Transfer_ToNonReceiverContract_Reverts` |
| 6 | | to = contract with valid receiver | `Transfer_ToValidReceiver_Succeeds` |
| 7 | Transfer amount | amount = 0 | `Transfer_ZeroAmount_Allowed` |
| 8 | | amount = exact balance | `Transfer_ExactBalance_DrainsHolder` |
| 9 | | amount > balance | `Transfer_MoreThanBalance_Reverts` |
| 10 | Batch transfer | ids.length ≠ amounts.length | `Batch_LengthMismatch_Reverts` |
| 11 | | ids = amounts = [] | `Batch_EmptyArrays_NoOp` |
| 12 | | all amounts = 0 | `Batch_ZeroAmounts_NoBalanceChange` |
| 13 | | direct holder-initiated | `Batch_DirectHolderInitiated_Blocked` (fix-#18) |
| 14 | balanceOf | untouched account | `BalanceOf_UntouchedAccount_ReturnsZero` |
| 15 | balanceOfBatch | length mismatch | `BalanceOfBatch_LengthMismatch_Reverts` |
| 16 | | empty arrays | `BalanceOfBatch_EmptyArrays_ReturnsEmpty` |
| 17 | | mixed holdings | `BalanceOfBatch_Works_MixedHoldings` |
| 18 | Approval | to self | `SetApprovalForAll_ToSelf_Accepted_OZv5` |
| 19 | | to address(0) | `SetApprovalForAll_ToZeroAddress_Reverts` |
| 20 | | revoke blocks next transfer | `RevokedApproval_BlocksSubsequentTransfers` |
| 21 | | holder-initiated without approval | `HolderInitiated_WithoutApproval_StillBlockedByFix18` |
| 22 | Mint | amount = 0 | `Mint_ZeroAmount_Reverts` |
| 23 | | to = address(0) | `Mint_ToZeroAddress_Reverts` |
| 24 | | to = valid receiver contract | `Mint_ToValidReceiverContract_Succeeds` |
| 25 | | to = non-receiver contract | `Mint_ToNonReceiverContract_Reverts` |
| 26 | | invalid epoch range | `Mint_InvalidEpoch_Reverts` |
| 27 | Burn | > balance | `BurnMoreThanBalance_Reverts` |
| 28 | | exact balance zeros out | `Burn_ExactBalance_Zeros` |
| 29 | | burnByHolder > balance | `BurnByHolder_InsufficientBalance_Reverts` |
| 30 | | burnByHolder via approved | `BurnByHolder_Authorised_Succeeds` |
| 31 | URI | non-minted epoch | `URI_NonMintedEpoch_StillFormats` |
| 32 | | `type(uint256).max` epoch | `URI_MaxUint_DoesNotRevert` |
| 33 | | reflects base URI change | `URI_AfterBaseURIChange_Reflects` |
| 34 | supportsInterface | ERC-165 | `SupportsInterface_ERC165` |
| 35 | | ERC-1155 | `SupportsInterface_ERC1155` |
| 36 | | Metadata-URI | `SupportsInterface_MetadataURI` |
| 37 | | bogus selectors | `SupportsInterface_Bogus_IsFalse` |
| 38 | Callback | single data passthrough | `Callback_Data_PassthroughOnSingle` |
| 39 | | batch data passthrough | `Callback_Data_PassthroughOnBatch` |
| 40 | | reentrancy via receiver | `Callback_Reentrancy_Blocked_ByFix18` |

## 3. Notable findings (full detail in REPORT.md)

- **OZ v5 self-approval is silently accepted**, not rejected. Harmless because the holder's own transfers don't consult the approval map, but documented for clarity.
- **`uri()` is now pure-function of `_baseURI` + epoch**; it does not require the epoch to exist, which is correct per ERC-1155 spec (URI templates are pre-committed at deploy time).
- **Fix-#18 interaction with ERC-1155 reentrancy**: the callback-into-self path in `ReentrantReceiver` is swallowed because the receiver is not a whitelisted operator — so a malicious receiver cannot exploit the ERC-1155 callback to re-enter transfer logic.
