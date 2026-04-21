# Capacity Reservation Fix Report

## Summary

| Field | Value |
|-------|-------|
| Bug ID | M-RACE |
| Severity | MEDIUM |
| Category | Race Condition |
| Branch | fix/v5-capacity-reservation-race |
| Files Modified | 6 source/test files |
| Tests Added | 18 |
| Tests Passing | 827/827 (0 failures) |

## Bug Description

Two concurrent policy purchases in the same block both pass the `availableCapacityUSD`
check because capacity is only committed when `issueBond()` is called at trigger time,
not when the policy is purchased. If both policies trigger, the second issueBond call
may revert, causing the user to lose their premium with no bond payout.

## Root Cause

`PolicyManagerV2.recordPolicy()` checked `bondVault.availableCapacityUSD()` as a
snapshot view but did not reserve capacity. `BondVault.availableCapacityUSD()` only
considered `totalCommittedUSD`, not pending policies.

## Fix Applied

### BondVault.sol
- Added `totalReservedUSD` state variable (18-dec USD-wei)
- Added `reserveCapacity()`, `releaseReservation()`, `commitReservation()` functions
- Updated `availableCapacityUSD()` to subtract `totalCommittedUSD + totalReservedUSD`
- Updated `getStatus()` with same adjustment
- Added events: `CapacityReserved`, `ReservationReleased`, `ReservationCommitted`

### PolicyManagerV2.sol
- Added `policyReservedUSD` mapping (productId -> policyId -> reserved amount)
- Updated IBondVault interface with new functions
- `recordPolicy()`: reserves capacity immediately after check
- `triggerPayout()`: commits reservation before issueBond
- `settlePolicy()`: commits on trigger, releases on non-trigger
- `markExpired()`: releases reservation

### Test Files Updated
- `test/audit/capacity-reservation/CapacityReservation.t.sol` - 18 new tests (created)
- `test/core/PolicyManagerV2Test.t.sol` - Mock updated for reservation interface
- `test/audit/AdversarialAuditTest.t.sol` - Updated BondVault init and direct issueBond calls
- `test/audit/CertiKSimulation.t.sol` - Same pattern
- `test/audit/rounding/RoundingErrors.t.sol` - Same pattern
- `test/audit/race/RaceConditions.t.sol` - Updated race test to verify fix behavior
- `test/automation/ShieldKeeperTest.t.sol` - Mock updated for reservation interface

## Verification

```
forge test --no-match-contract "Fork"
827 tests passed, 0 failed, 0 skipped
```

## Risk Assessment

- **Breaking changes**: None. `issueBond()` capacity check is unchanged. Existing
  bond issuance flows work identically.
- **Gas impact**: ~20K additional gas per policy purchase (reservation SSTORE).
  Negligible compared to existing ~300K gas per purchase.
- **Upgrade path**: New state variable (`totalReservedUSD`) starts at 0, which is
  correct for existing deployed contracts with no active reservations.
