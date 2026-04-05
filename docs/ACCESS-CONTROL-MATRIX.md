# ACCESS CONTROL MATRIX

## Roles
| Role | Holder | How Assigned |
|------|--------|-------------|
| Owner (all UUPS proxies) | TimelockController | At deployment |
| TimelockController proposer/executor | Gnosis Safe 2-of-3 | At deployment |
| EMERGENCY_ROLE | Gnosis Safe signers | grantEmergencyRole() by owner |
| Oracle Signer | Single key (planned 2-of-3) | Constructor / addSigner() |
| Authorized Relayer | API server | setRelayer() by owner |

## Functions by Contract

### CoverRouter
| Function | Access | Description |
|----------|--------|-------------|
| purchasePolicy | Anyone (buyer) | Buy insurance |
| purchasePolicyFor | Authorized relayers | Buy on behalf of agent |
| triggerPayout | Agent/relayer/owner, anyone after 6h | Trigger claim |
| cleanupExpiredPolicy | Anyone | Release expired collateral |
| executeScheduledPayout | Anyone (after delay) | Execute delayed payout |
| cancelScheduledPayout | EMERGENCY_ROLE only, before delay | Veto fraudulent payout |
| registerProduct | Owner | Add new product |
| setProductActive | Owner | Activate/deactivate product |
| setOracle | Owner | Change oracle address |
| setPaused | Owner | Pause new purchases |
| setEmergencyPause | Owner | Set EP contract |

### BaseVault (4 instances)
| Function | Access | Description |
|----------|--------|-------------|
| depositAssets | Anyone | Deposit USDC |
| requestWithdrawal | LP (share holder) | Start cooldown |
| completeWithdrawal | LP (after cooldown) | Withdraw USDC |
| executePayout | Router only | Execute insurance payout (NO pause) |
| lockCollateral | PolicyManager only | Lock for policy |
| unlockCollateral | PolicyManager only | Release collateral |
| claimPendingPayout | Anyone (keyed by msg.sender) | Claim queued payout (NO pause) |
| claimPendingWithdrawal | Anyone (keyed by msg.sender) | Claim queued withdrawal |
| pause/unpause | Owner | Global vault pause |
| setEmergencyPause | Owner | Set EP contract |
| setCooldownDuration | Owner | Change cooldown |

### PolicyManager
| Function | Access | Description |
|----------|--------|-------------|
| recordAllocation | Router only | Lock collateral for policy |
| releaseAllocation | Router only | Free collateral |
| freezeProduct | Owner | Emergency halt per product |
| unfreezeProduct | Owner | Re-enable product |
| createCorrelationGroup | Owner | Risk grouping |

### EmergencyPause
| Function | Access | Description |
|----------|--------|-------------|
| emergencyPauseAll | EMERGENCY_ROLE | Instant global pause |
| emergencyUnpauseAll | EMERGENCY_ROLE (with cooldown) | Unpause protocol |
| grantEmergencyRole | Owner (Timelock) | Add pauser |
| revokeEmergencyRole | Owner (Timelock) | Remove pauser |

### LuminaOracle
| Function | Access | Description |
|----------|--------|-------------|
| getLatestPrice | Anyone (view) | Read Chainlink price |
| verifySignature | Anyone (view) | Verify oracle proof |
| addSigner | Owner | Add oracle signer |
| removeSigner | Owner | Remove signer |
| setRequiredSignatures | Owner | Change threshold |
| registerFeed | Owner | Add Chainlink feed |
