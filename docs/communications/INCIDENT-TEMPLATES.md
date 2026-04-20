# Incident Communication Templates

## LUMINA Protocol V5.0 — Public Communication During Incidents

---

## Template 1: P0 Critical Incident

**Use when**: Complete protocol pause, potential exploit detected, funds at immediate risk.

---

> **Subject**: LUMINA Protocol — Critical Incident Update

---

🚨 **CRITICAL INCIDENT — LUMINA Protocol**

**Status**: INVESTIGATING / MITIGATING / RESOLVED (choose one)

**What happened**:
[Brief, factual description of the incident. Do not speculate. Example: "At [TIME] UTC on [DATE], our security monitoring detected abnormal transaction patterns on the [CONTRACT_NAME] contract. The protocol has been paused as a precautionary measure."]

**User impact**:
- All protocol operations are currently paused
- No new deposits, withdrawals, or policy purchases can be processed
- [Any additional specific impacts]

**Your funds**:
All user funds secured in smart contracts remain safe. The pause mechanism prevents any further state changes, protecting all deposited assets. [If applicable: "No user funds have been lost or are at risk."]

**What we are doing**:
1. Security team is actively investigating the root cause
2. All protocol operations have been paused via emergency multisig action
3. External security partners have been engaged
4. We will provide updates every [30 minutes / 1 hour]

**Next steps**:
- We will publish a detailed post-mortem within 48 hours of resolution
- Protocol will only resume after thorough security verification
- Next update: [TIME] UTC

**What you should do**:
- No action is required from users at this time
- Do not interact with any unofficial links claiming to be "recovery" tools
- Follow only official channels for updates

---

*LUMINA Protocol Team | [DATE] [TIME] UTC*

---

## Template 2: P1 Service Degradation

**Use when**: Partial functionality impaired, one subsystem affected, no funds at risk.

---

> **Subject**: LUMINA Protocol — Service Degradation Notice

---

⚠️ **SERVICE DEGRADATION — LUMINA Protocol**

**Status**: INVESTIGATING / MITIGATING / RESOLVED (choose one)

**What happened**:
[Brief description. Example: "We are experiencing degraded performance on the [SUBSYSTEM] due to [REASON — e.g., oracle latency, network congestion, third-party dependency]. Core protocol functions remain operational."]

**User impact**:
- [Specific feature] may experience delays of [DURATION]
- [Specific feature] is temporarily unavailable
- All other protocol functions continue to operate normally
- **No funds are at risk**

**Your funds**:
All funds remain fully secure. This issue affects [specific functionality] only and does not impact the security or integrity of deposited assets.

**What we are doing**:
1. Engineering team has identified the affected component
2. [Specific mitigation action being taken]
3. Monitoring shows [relevant metric] is [improving/stable]

**Next steps**:
- Expected resolution: [TIME ESTIMATE]
- We will confirm when full service is restored
- If the situation changes, we will escalate communications accordingly

**What you should do**:
- [Specific action if any — e.g., "Delay submitting claims until service is restored"]
- Normal protocol usage can continue for unaffected features

---

*LUMINA Protocol Team | [DATE] [TIME] UTC*

---

## Template 3: Auto-Pause Activation

**Use when**: Circuit breaker or auto-pause triggered by on-chain conditions (oracle deviation, TVL drop, unusual volume).

---

> **Subject**: LUMINA Protocol — Automatic Safety Pause Activated

---

🛡️ **AUTO-PAUSE ACTIVATED — LUMINA Protocol**

**Status**: REVIEWING

**What happened**:
At [TIME] UTC on [DATE], LUMINA Protocol's automated safety system activated a precautionary pause on [CONTRACT/POOL NAME]. This was triggered by [TRIGGER REASON — e.g., "oracle price deviation exceeding the configured 15% threshold" / "TVL decrease exceeding the 25% circuit breaker limit" / "transaction volume anomaly detection"].

**Important**: This is a designed safety mechanism working as intended. Auto-pause systems exist specifically to protect user funds during unusual market conditions or unexpected on-chain activity.

**User impact**:
- [Specific contract/pool] is temporarily paused
- Users cannot [specific actions] until the pause is lifted
- Existing positions and deposits are unaffected and secure
- Unrelated protocol features continue to function normally

**Your funds**:
All funds are safe. The auto-pause mechanism is a protective measure that prevents any state changes during unusual conditions, ensuring no transactions occur under potentially adverse circumstances.

**What we are doing**:
1. Security team is reviewing the trigger conditions
2. Verifying that the trigger was due to legitimate market conditions (not an attack)
3. Assessing whether conditions have normalized for safe resumption

**Next steps**:
- If conditions were legitimate market movement: resume operations within [TIME ESTIMATE]
- If further investigation is needed: will provide update within [TIME]
- Community will be notified before operations resume

**What you should do**:
- No action required
- Your positions remain intact and will continue to function normally once the pause is lifted

---

*LUMINA Protocol Team | [DATE] [TIME] UTC*

---

## Template 4: Mass Trigger Event

**Use when**: A parametric trigger event affects multiple policies simultaneously (e.g., widespread protocol hack triggers coverage payouts).

---

> **Subject**: LUMINA Protocol — Mass Trigger Event & Claims Processing

---

🔔 **MASS TRIGGER EVENT — LUMINA Protocol**

**Status**: PROCESSING

**What happened**:
At [TIME] UTC on [DATE], a qualifying trigger event was detected affecting [SHIELD POOL NAME / EVENT DESCRIPTION]. This event has activated coverage for [NUMBER] active policies across [SHIELD TYPE]. Our oracle network has confirmed the trigger conditions are met.

[Brief factual description of the external event — e.g., "The [PROTOCOL_NAME] exploit resulted in losses exceeding the configured trigger threshold of [AMOUNT/PERCENTAGE], activating parametric coverage for all qualifying LUMINA shield holders."]

**User impact**:
- **If you hold active coverage**: Your policy has been triggered. Payouts will be processed automatically.
- **Payout timeline**: Claims processing will begin within [TIME] and complete within [TIME].
- **Payout amount**: Per your policy terms, coverage pays [PERCENTAGE/AMOUNT] of your covered amount.
- **Shield pool depositors**: Pool utilization has increased. Detailed impact assessment will follow.

**Your funds**:
- **Coverage holders**: Payouts are guaranteed by the shield pool reserves. Funds are allocated and will be distributed.
- **Shield depositors**: Your deposits are being utilized as designed to cover valid claims. Remaining balances will be available after claims processing.
- **Other users**: No impact on deposits, bonds, or other protocol functions.

**What we are doing**:
1. Oracle verification of trigger conditions: CONFIRMED
2. Claims calculation engine processing all eligible policies
3. Payout distribution queue being prepared
4. Shield pool reserves are sufficient to cover all claims

**Next steps**:
- Automatic payouts will begin at [TIME] UTC
- Users will receive funds directly to their wallet (no claim action needed)
- Full event report will be published within 72 hours
- Shield pool rebalancing will occur over the following [TIME PERIOD]

**What you should do**:
- **Coverage holders**: No action needed. Payouts are automatic.
- **Shield depositors**: Review your position after claims are processed.
- Beware of scams — LUMINA will NEVER ask you to "claim" via external links.

---

*LUMINA Protocol Team | [DATE] [TIME] UTC*

---

## Usage Guidelines

1. **Speed over perfection**: Publish initial communication within 15 minutes of incident detection.
2. **Factual only**: Never speculate about causes until confirmed.
3. **Update regularly**: Follow the cadence promised in the initial communication.
4. **Multi-channel**: Post on Twitter/X, Discord, Telegram, and the protocol blog simultaneously.
5. **Archive**: All incident communications should be preserved for the post-mortem record.

---

*Document Version: 1.0 | Last Updated: 2026-04-19 | LUMINA Protocol V5.0*
