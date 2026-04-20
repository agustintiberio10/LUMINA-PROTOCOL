# Compliance Checklist

## LUMINA Protocol V5.0 — Legal & Regulatory Framework

---

## 1. Legal Documents Required

### 1.1 Terms of Service (ToS)

- [ ] Define the protocol as software, not a financial service provider
- [ ] Clearly state that users interact with smart contracts at their own risk
- [ ] Specify supported jurisdictions and restricted regions
- [ ] Include limitation of liability clauses
- [ ] Define acceptable use policy
- [ ] Address dispute resolution mechanism (arbitration clause)
- [ ] Include force majeure provisions
- [ ] Define intellectual property rights
- [ ] Specify modification/update procedures and user notification
- [ ] Include severability clause
- [ ] Legal review by qualified counsel: [ ] Completed / [ ] Pending

### 1.2 Privacy Policy

- [ ] Identify what data is collected (wallet addresses, transaction data, IP if applicable)
- [ ] Clarify on-chain vs off-chain data handling
- [ ] Address GDPR compliance for EU users
- [ ] Address CCPA compliance for California users
- [ ] Define data retention periods
- [ ] Specify third-party data sharing (analytics, RPC providers, oracles)
- [ ] Provide user rights (access, deletion, portability)
- [ ] Cookie policy for web interface
- [ ] Data breach notification procedures
- [ ] Designate Data Protection Officer (DPO) if required
- [ ] Legal review by qualified counsel: [ ] Completed / [ ] Pending

### 1.3 Risk Disclaimers

- [ ] Smart contract risk disclaimer (bugs, exploits, upgrades)
- [ ] Oracle risk disclaimer (data feed failures, manipulation)
- [ ] Market risk disclaimer (token price volatility)
- [ ] Regulatory risk disclaimer (evolving legal landscape)
- [ ] Coverage limitation disclaimer (parametric =/= indemnity)
- [ ] No guarantee of returns for shield pool depositors
- [ ] Bond risk disclaimer (lock-up period, protocol risk)
- [ ] Impermanent loss risk for liquidity-related features
- [ ] Counterparty risk acknowledgment
- [ ] Past performance disclaimer
- [ ] Place disclaimers prominently in UI at point of interaction
- [ ] Legal review by qualified counsel: [ ] Completed / [ ] Pending

---

## 2. Regulatory Considerations

### 2.1 Parametric Insurance Classification

**Key Question**: Does LUMINA Protocol constitute "insurance" under applicable law?

**Analysis**:

| Factor | Traditional Insurance | LUMINA (Parametric) |
|--------|----------------------|---------------------|
| Loss verification | Adjuster/claims process | Automatic oracle trigger |
| Payout basis | Actual loss (indemnity) | Predefined parameter met |
| Insurable interest | Required | Not assessed |
| Licensed entity | Required (insurer) | Smart contract (no entity) |
| Regulatory oversight | State/national insurance regulators | Unclear/evolving |

**Jurisdictional Considerations**:

- [ ] **United States**: Parametric products may be classified as insurance in some states. Evaluate state-by-state licensing requirements. Consider "derivative" classification as alternative.
- [ ] **European Union**: Under Solvency II, parametric insurance requires licensed insurer. DeFi-native products may fall outside scope if no identifiable insurer. Monitor MiCA implications.
- [ ] **United Kingdom**: FCA sandbox may apply. Parametric products gaining regulatory clarity.
- [ ] **Singapore**: MAS has provided guidance on digital token insurance. Evaluate applicability.
- [ ] **Bermuda/Cayman**: More favorable regulatory environment for parametric products.

**Recommended Position**: Frame LUMINA as a "parametric protection protocol" or "conditional payment protocol" rather than "insurance" in public communications. Engage specialist counsel for jurisdiction-specific analysis.

### 2.2 Token Classification — Howey Test Analysis

**The Howey Test** (U.S. securities law) asks whether LUMINA token constitutes an "investment contract":

| Howey Prong | Analysis | Risk Level |
|-------------|----------|------------|
| **Investment of money** | Users purchase/earn LUMINA tokens | Met — HIGH |
| **Common enterprise** | Protocol pools funds, shared outcomes | Likely met — MEDIUM |
| **Expectation of profits** | Shield yields, burn mechanism, appreciation | Potentially met — HIGH |
| **Efforts of others** | Decentralized governance, but core team development | Partially met — MEDIUM |

**Risk Mitigation Strategies**:

- [ ] Maximize decentralization of governance and development
- [ ] Ensure token has genuine utility beyond speculation (governance, fee payment, staking)
- [ ] Avoid marketing token as an investment opportunity
- [ ] Do not reference price appreciation potential in official communications
- [ ] Document progressive decentralization roadmap
- [ ] Consider "sufficiently decentralized" arguments (SEC guidance)
- [ ] Engage securities counsel for formal opinion
- [ ] Monitor SEC enforcement actions against similar protocols

**Non-U.S. Classification**:

- [ ] EU (MiCA): Determine if utility token, e-money token, or asset-referenced token
- [ ] UK (FCA): Security token vs. utility token classification
- [ ] Singapore (MAS): Payment token vs. security token vs. utility token

### 2.3 AML/KYC Approach

**Current Approach**: Permissionless protocol — no KYC at smart contract level.

**Considerations**:

- [ ] Evaluate if any protocol function triggers Money Services Business (MSB) requirements
- [ ] Assess Travel Rule applicability (FATF Recommendation 16)
- [ ] Determine if DAO/multisig operators face compliance obligations
- [ ] Consider voluntary KYC for large depositors (>threshold) in future versions
- [ ] Implement OFAC sanctions screening on frontend (address blacklist)
- [ ] Document sanctions compliance approach for frontend operators
- [ ] Monitor evolving DeFi-specific AML guidance (FATF, FinCEN)

**Frontend Compliance**:

- [ ] Implement wallet screening against OFAC SDN list
- [ ] Block access from sanctioned jurisdictions via geofencing
- [ ] Maintain records of screening implementation
- [ ] Update sanctions lists on regular cadence (minimum daily)

---

## 3. Restricted Jurisdictions

### Fully Restricted (No Access)

Users from the following jurisdictions must be blocked at the frontend level:

- [ ] United States (pending regulatory clarity)*
- [ ] North Korea (DPRK)
- [ ] Iran
- [ ] Cuba
- [ ] Syria
- [ ] Crimea, Donetsk, Luhansk regions (Ukraine — Russian-occupied)
- [ ] Myanmar (depending on sanctions status)

*Note: U.S. restriction may be revisited based on regulatory developments and legal counsel advice.

### Partially Restricted (Limited Features)

- [ ] [Jurisdictions with specific product restrictions]
- [ ] [Jurisdictions requiring specific disclosures]

### Implementation

- [ ] Geofencing via IP detection on frontend
- [ ] VPN detection considerations (best effort, not infallible)
- [ ] Clear messaging for restricted users explaining why access is denied
- [ ] Regular review of OFAC/sanctions list updates
- [ ] Document that smart contracts are permissionless and restrictions are frontend-only

---

## 4. Intellectual Property

### 4.1 Trademark

- [ ] Register "LUMINA Protocol" trademark in relevant jurisdictions
- [ ] Register protocol logo and brand assets
- [ ] Document brand usage guidelines
- [ ] Monitor for unauthorized trademark use
- [ ] Consider defensive registrations in key markets

### 4.2 Licenses

- [ ] Determine open-source license for smart contracts (MIT, GPL, BUSL)
- [ ] Ensure all dependencies have compatible licenses
- [ ] Document license of each third-party library used
- [ ] Frontend code licensing (if different from contracts)
- [ ] API licensing terms (if applicable)
- [ ] Audit report licensing/publication rights

### 4.3 Patent Considerations

- [ ] Evaluate if any novel mechanisms warrant defensive patent filing
- [ ] Review freedom to operate regarding existing DeFi patents
- [ ] Consider joining a patent non-aggression community (e.g., LOT Network)

---

## 5. Insurance & Liability Considerations

### 5.1 Team/DAO Liability

- [ ] Evaluate DAO legal wrapper options (Cayman Foundation, Marshall Islands DAO LLC, Swiss Association)
- [ ] Directors & Officers (D&O) insurance for identified team members
- [ ] Cyber liability insurance for operational infrastructure
- [ ] Professional indemnity insurance for core contributors
- [ ] Document corporate structure and liability shields

### 5.2 Protocol-Level Considerations

- [ ] Define liability boundaries between protocol, frontend operator, and DAO
- [ ] Document that smart contract behavior is deterministic and transparent
- [ ] Establish bug bounty program as good-faith security measure
- [ ] Maintain audit trail of all governance decisions

---

## 6. Post-Launch Compliance

### Ongoing Requirements

- [ ] Quarterly review of regulatory developments in key jurisdictions
- [ ] Annual legal opinion refresh on token classification
- [ ] Monthly OFAC/sanctions list update verification
- [ ] Regular privacy policy updates as data practices evolve
- [ ] Community transparency reports (semi-annual)
- [ ] Engage government relations in key markets as needed
- [ ] Monitor enforcement actions against comparable protocols
- [ ] Update ToS/disclaimers as protocol features change
- [ ] Tax reporting considerations (1099s, VAT if applicable)
- [ ] Record-keeping of all material governance decisions

### Regulatory Engagement

- [ ] Identify relevant regulatory bodies in operating jurisdictions
- [ ] Consider proactive engagement (regulatory sandbox applications)
- [ ] Maintain list of specialized legal counsel by jurisdiction
- [ ] Participate in industry working groups (e.g., DeFi Education Fund, Blockchain Association)
- [ ] Prepare response framework for regulatory inquiries

---

## 7. Compliance Responsibility Matrix

| Area | Responsible Party | Review Frequency |
|------|-------------------|-----------------|
| ToS / Privacy Policy | Legal Counsel | Quarterly |
| Sanctions Screening | Frontend Operator | Daily (automated) |
| Token Classification | Securities Counsel | Semi-annual |
| Insurance Regulation | Insurance Counsel | Quarterly |
| AML/KYC Policy | Compliance Lead | Quarterly |
| IP Protection | IP Counsel | Annual |
| Jurisdiction Restrictions | Legal + Engineering | Monthly |

---

## Disclaimer

This document is an internal operational checklist and does not constitute legal advice. All items should be reviewed and validated by qualified legal counsel in relevant jurisdictions before implementation. Regulatory landscapes evolve rapidly; this document requires regular updates.

---

*Document Version: 1.0 | Last Updated: 2026-04-19 | LUMINA Protocol V5.0*
