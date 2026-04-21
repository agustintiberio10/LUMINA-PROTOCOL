# Capacity Reservation System - Design Document

## Problem Statement

**Bug ID:** M-RACE (MEDIUM)
**Component:** BondVault + PolicyManagerV2
**Branch:** fix/v5-capacity-reservation-race

Two concurrent policy purchases in the same block both pass the capacity check
because `totalCommittedUSD` only updates at trigger time (`issueBond()`), not at
purchase time. If both policies trigger, the second `issueBond()` call may revert
with "Exceeds capacity", causing the user to lose their premium with no bond payout.

### Race Condition Timeline (Before Fix)

```
Block N:
  Tx1: buyer1.purchasePolicy($1.2M) -> availableCapacityUSD = $1.26M -> PASS
  Tx2: buyer2.purchasePolicy($1.2M) -> availableCapacityUSD = $1.26M -> PASS (stale!)

Block N+K:
  Tx3: trigger(buyer1) -> issueBond($1.2M) -> totalCommittedUSD += $1.2M -> OK
  Tx4: trigger(buyer2) -> issueBond($1.2M) -> totalCommittedUSD + $1.2M > max -> REVERT
       buyer2 paid premium but gets no bond.
```

## Solution: Capacity Reservation

Introduce a `totalReservedUSD` state variable in BondVault that tracks capacity
reserved by active (untriggered, unexpired) policies. The reservation lifecycle:

1. **Purchase** (`recordPolicy`): Reserve capacity immediately
2. **Trigger** (`triggerPayout`/`settlePolicy`): Convert reservation to commitment
3. **Expiry** (`markExpired`/`settlePolicy`): Release reservation

### State Transitions

```
Purchase:   totalReservedUSD  += payoutUSD * 1e18
Trigger:    totalReservedUSD  -= payoutUSD * 1e18  (commitReservation)
            totalCommittedUSD += payoutUSD * 1e18  (issueBond)
Expiry:     totalReservedUSD  -= payoutUSD * 1e18  (releaseReservation)
```

### Capacity Calculation

```solidity
availableCapacityUSD = maxCommitUSD - (totalCommittedUSD + totalReservedUSD)
```

This ensures the second purchase in the race scenario sees reduced available
capacity and fails at purchase time (before premium is spent), rather than
failing silently at trigger time (after premium is lost).

## Contract Changes

### BondVault.sol

New state:
- `uint256 public totalReservedUSD` - 18-dec USD-wei

New functions (all `onlyPolicyManager`):
- `reserveCapacity(uint256 amount)` - Called at policy purchase
- `releaseReservation(uint256 amount)` - Called at policy expiry
- `commitReservation(uint256 amount)` - Called at policy trigger (before issueBond)

Modified functions:
- `availableCapacityUSD()` - Subtracts both committed AND reserved
- `getStatus()` - Same adjustment for available capacity view

Unchanged:
- `issueBond()` - Capacity check unchanged; works correctly because
  `commitReservation()` removes the reservation before `issueBond()` adds the
  commitment. The net capacity usage stays the same.

### PolicyManagerV2.sol

New state:
- `mapping(bytes32 => mapping(uint256 => uint256)) public policyReservedUSD`

Modified functions:
- `recordPolicy()` - Calls `bondVault.reserveCapacity()` after capacity check
- `triggerPayout()` - Calls `bondVault.commitReservation()` before `issueBond()`
- `settlePolicy()` - Commits on trigger, releases on expiry
- `markExpired()` - Calls `bondVault.releaseReservation()`

## Security Considerations

1. **Access Control**: All three new BondVault functions require `msg.sender == policyManager`
2. **Invariant**: `totalReservedUSD` can never go negative (checked with require)
3. **No double-counting**: `commitReservation` removes from reserved before `issueBond` adds to committed
4. **Backward compatibility**: `issueBond()` capacity check is unchanged; existing flows work identically
5. **Gas overhead**: ~20K gas per policy purchase (1 SSTORE for reservation, 1 SLOAD+SSTORE in BondVault)

## Test Coverage

18 dedicated tests in `test/audit/capacity-reservation/CapacityReservation.t.sol`:
- Basic reservation on purchase
- Per-policy reservation storage
- Race condition prevention (core fix validation)
- Trigger commits reservation
- Expiry releases reservation
- Freed capacity available for new purchases
- Access control (3 tests)
- Insufficient reservation reverts (2 tests)
- Multiple policy accumulation
- Partial trigger/release
- settlePolicy triggered and not-triggered paths
- getStatus view reflects reservations
- Zero amount reverts
- Full lifecycle: purchase -> trigger -> redeem
