# Pre-Mainnet Checklist — Forward-Looking

This is NOT executed during audit #32. It's the canonical checklist that must pass before ANY mainnet deploy. Lock in the requirements now so the future "are we ready?" conversation has a definitive answer.

---

## 1. Code

### Audits complete

- [ ] Audit #1-40 of the V5.1 series complete + merged
- [ ] All blocking findings resolved (CRITICAL, HIGH, MEDIUM)
- [ ] LOW / INFO findings resolved or documented as accepted-risk
- [ ] ~~At least 1 external professional audit complete~~ — _founder decided NOT to pursue Tier-1 external audit for V5.1 testnet (May 2026); revisit pre-mainnet. Bug bounty + multisig at T+30d post-deploy instead._
- [ ] Audit report PUBLIC at deploy time (no embargo)

### Fixes applied

- [ ] Fix M-01: TWAPBurner price oracle integration
- [ ] Fix M-02: TWAPBurner minOut floor
- [ ] Fix M-03: BuybackEngine reads marketplace fee BPS
- [ ] Fix #18: NFT metadata + restricted transfers
- [ ] Fix #26: recoverToken in 7 fund-holders
- [ ] Fix #27: admin-setter events
- [ ] Fix #28: pause hysteresis + KeeperPaused event
- [ ] Fix #31: deploy script CRITICAL + 2 HIGH
- [ ] All future audit fixes (29-40)

### Quality gates

- [ ] 100% of new tests across all audits are substantive (no `assertTrue(true)`)
- [ ] Aggregate test count ≥ 2500 (anchored to today's 2091 + future audits)
- [ ] `forge fmt` clean
- [ ] `forge build` 0 errors, 0 warnings
- [ ] Full regression suite passes
- [ ] Slither + custom analyzer scans clean (no high/critical)

## 2. Bug bounty

- [ ] Bug bounty program live (Immunefi / Code4rena)
- [ ] Bounty pool funded with ≥ $50K
- [ ] Severity matrix posted publicly (CRITICAL → $X / HIGH → $Y / MEDIUM → $Z)
- [ ] Disclosure policy clear (responsible disclosure window)

## 3. Operational infrastructure

### Multisig

- [ ] Gnosis Safe (or equivalent) deployed with 3-of-5 (or higher) threshold
- [ ] Each signer holds the key on a hardware wallet (Ledger / Trezor / GridPlus)
- [ ] No two signers share a physical location or office
- [ ] Backup recovery procedure documented and tested

### Timelock

- [ ] `TimelockController` deployed with **48h minimum delay**
- [ ] Multisig is the proposer + executor of the timelock
- [ ] Critical admin operations (upgrades, parameter changes) ONLY via timelock
- [ ] Cancel-tx procedure documented (Guardian role optional)

### Monitoring

- [ ] 24/7 on-call rotation (≥ 2 engineers)
- [ ] Event subscription on:
  - Every `Upgraded(address)` (UUPS upgrades)
  - Every `RoleGranted` / `RoleRevoked`
  - Every `OwnershipTransferred`
  - Every `TokenRecovered` (audit #26 fix)
  - Every `AutoPauseActivated` / `AutoPauseDeactivated` (audit #28 fix)
  - Every `BondIssued` / `BondRedeemed` (volume tracking)
  - Solvency ratio drops below 100% (HEALTHY threshold)
- [ ] Alerting wired to Slack / PagerDuty
- [ ] Public status page (e.g. `status.lumina-protocol.io`)
- [ ] Grafana / Dune dashboards for protocol health

## 4. Liquidity

- [ ] DEX pool LUMINA/USDC seeded with ≥ $100K initial liquidity
- [ ] LBP (Liquidity Bootstrapping Pool) executed or scheduled (Balancer / Sushi)
- [ ] CEX listings discussed (Tier 3+ only initially; Tier 1 post-LBP success)
- [ ] Slippage curve verified — first $10K trade < 5% slippage at launch price

## 5. Communication

- [ ] Pre-launch announcement 2 weeks before deploy
- [ ] Documentation site live (`docs.lumina-protocol.io`)
- [ ] User guide published (how to buy a policy, how to redeem)
- [ ] Operator runbook published (incident response, rotation procedures)
- [ ] Discord / Telegram / Twitter accounts active
- [ ] Press kit ready (press release, logos, founder bios)
- [ ] Beta testing summary published (Sepolia E2E results)

## 6. Pre-deploy rehearsals

- [ ] Sepolia V5.1 deploy ✅ (audit #32 — this is the prep audit; deploy itself is operational)
- [ ] Sepolia E2E running for ≥ 2 weeks before mainnet
- [ ] Mainnet fork rehearsal (audit #38) — full deploy on `forge --fork-url $BASE_RPC` to verify no surprises
- [ ] Mainnet dry run (audit #39) — actual mainnet deploy script execution to a single contract for gas/sanity check, then revert
- [ ] Post-deploy validation suite (audit #40) — automated verification of all 24+ contracts post-deploy

## 7. Legal / compliance (jurisdictional)

- [ ] Legal review of token economics (USA/EU/Asia)
- [ ] Compliance attestation if required (KYC for ops team, no for users)
- [ ] Terms of Service published
- [ ] Privacy policy published
- [ ] Risk disclosure document published

## 8. Go / no-go

The mainnet deploy is GO only when:
1. Every box in §1-7 is checked.
2. Founder + at least 2 other multisig signers explicitly approve.
3. No CRITICAL or HIGH findings open in any audit channel.
4. No active incidents on Sepolia (status page green for ≥ 7 days).
5. Bug bounty has at least 30 days of public exposure.

If ANY of the above is no, the deploy is NO-GO.

---

## 9. Day-of-launch sequence (for reference)

When all checklist items are GO:

1. **T - 24h:** final regression run + smoke test on Sepolia.
2. **T - 4h:** all signers online and ready.
3. **T - 1h:** deployer wallet funded, ETH balance verified.
4. **T - 0:** run mainnet deploy script with `--broadcast`.
5. **T + 5min:** verify script runs, every check is PASS.
6. **T + 15min:** smoke test (buy 1 policy, list 1 bond, execute 1 buy).
7. **T + 30min:** transfer ownership to multisig (timelock takes admin via grantRole).
8. **T + 1h:** deployer revokes own admin roles. Multisig is now sole admin.
9. **T + 2h:** announcement on Discord / Twitter / mailing list.
10. **T + 24h:** community Q&A; on-call team monitors continuously.

---

This checklist is normative. It will be referenced in audits #38-40 ("mainnet readiness") and is the gate before any mainnet broadcast.
