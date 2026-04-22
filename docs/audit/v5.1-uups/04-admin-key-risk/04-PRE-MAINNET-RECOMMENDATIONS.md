# V5.1 Pre-Mainnet Recommendations (Admin-Risk)

**Audit:** V5.1 #4 — Admin Key Risk
**Date:** 2026-04-22

Actionable checklist before turning the mainnet deployment key over to users.

---

## 1. OBLIGATORY (block mainnet launch)

- [ ] **Deploy a 3-of-5 multisig on hardware wallets.**
  - Recommended: Safe (Gnosis Safe) on Base with 5 independent signers.
  - At least one signer must be an independent auditor / board member not
    on the core team payroll.
  - Document the signer set publicly.

- [ ] **Install `TimelockController` with 48h delay** between any admin
  proposal and its execution. Covered operations:
  - `upgradeToAndCall` on all 24 UUPS contracts
  - `grantRole` / `revokeRole` on all AccessControl contracts
  - Every setter on every contract except `pause` / `unpause` on
    ShieldKeeper (emergency ops; see Guardian pattern below)

- [ ] **Transfer all roles/ownership from deployer EOA to the multisig
  (via the timelock as proposer/executor).** Final state:
  - `Ownable.owner == timelockAddress` on 16 Ownable contracts
  - `DEFAULT_ADMIN_ROLE == timelockAddress` on 7 AccessControl contracts
  - Deployer EOA has renounced every role.

- [ ] **Set up on-chain monitoring** (OpenZeppelin Defender / Tenderly /
  Forta) for every admin-sensitive event across all 24 contracts. Must
  auto-post to the governance channel within 60s of emission.

- [ ] **Audit the timelock & multisig deploy transaction** end-to-end before
  deploying production proxies.

## 2. HIGHLY RECOMMENDED

- [ ] **Bug bounty on Immunefi** with admin-risk-weighted scope. Suggested
  tiering:
  - CRITICAL (≥ $500k): Unauthorized upgrade, role grant, fund drain.
  - HIGH (≥ $100k): Front-running / reorder attacks on admin txs.
  - MEDIUM (≥ $25k): Setter misuse, DoS.

- [ ] **Second external audit focused on admin-risk minimization**
  (complementing the 40-part internal V5.1 audit series). Engage a firm
  known for proxy / upgrade pattern review (e.g. OpenZeppelin, Trail of Bits,
  Spearbit).

- [ ] **Separation of roles across all contracts.** Deploy multisig
  composition:
  - Deployer role retired.
  - Operations multisig (for routine param changes): 2-of-4.
  - Admin multisig (for upgrades + role grants): 3-of-5.
  - Emergency guardian (pause only): 1-of-3.

- [ ] **Pre-publish the upgrade queue** on the governance frontend so every
  pending timelock operation is visible.

- [ ] **Freeze ABI** post-launch: any new function added requires a new
  audit round and 72h public notice before the timelock queue fills.

## 3. OPTIONAL (nice-to-have)

- [ ] **Emergency Guardian pattern** — dedicated `PAUSER_ROLE` on every
  pausable contract, held by a separate 1-of-3 multisig with no upgrade
  power. Enables fast-pause without waiting for the 48h timelock.

- [ ] **Governance DAO roadmap.** Launch a v1 LUMINA-gated governance
  (snapshot or on-chain) within 12 months. Replace the admin multisig
  progressively with DAO vote + timelock.

- [ ] **Public pending-upgrade dashboard** with diff viewer against the
  current impl bytecode (e.g. Ethscan verified-contract diff + a
  protocol-operated UI).

- [ ] **Policy-insurance backstop.** Purchase coverage from Nexus Mutual /
  Sherlock against "admin action" as a specific covered loss category.

- [ ] **Time-bounded admin.** Hard-code a sunset block after which all
  admin-only functions revert unless re-authorized by DAO vote. This is a
  non-trivial contract change — defer until V6.

## 4. Sanity-check timeline

| T-date | Milestone |
|--------|-----------|
| T-28d | Deploy multisig + timelock on Base Sepolia; dry-run an upgrade. |
| T-14d | Freeze code. Final internal audit sign-off (this series). |
| T-7d | Publish disclosure doc (`03-PUBLIC-ADMIN-DISCLOSURE.md`). |
| T-2d | Deploy to mainnet with deployer EOA as initial admin. |
| T-0  | Run transfer-to-timelock+multisig transaction. Deployer EOA renounces. |
| T+1d | Post-launch: verify via block explorer that admin = timelock. |
| T+30d | First bug-bounty payout window closes if no reports. |

---

## Exit check — "is the admin actually safe?"

Before launch, answer YES to ALL:

- [ ] Deployer EOA has `hasRole(DEFAULT_ADMIN_ROLE, deployer) == false`
      on every AccessControl contract.
- [ ] Deployer EOA owner == address(0) (renounced) on every Ownable
      contract (alternative: owner == multisig).
- [ ] Every `_authorizeUpgrade`-guarded call goes through the timelock.
- [ ] Every role-grant goes through the timelock.
- [ ] At least one independent signer has rehearsed a "stop an upgrade"
      emergency drill.
- [ ] Public sentinel alerts posted in a public channel with ≥3 subscribers
      outside the core team.

If any box is unchecked, mainnet is not ready.
