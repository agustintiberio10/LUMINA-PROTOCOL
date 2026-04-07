# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Lumina Protocol, please report it responsibly.

**Email:** security@lumina-org.com
**Response time:** We will acknowledge within 24 hours and provide a detailed response within 72 hours.

**Please do NOT:**
- Open a public GitHub issue for security vulnerabilities
- Exploit the vulnerability on mainnet
- Share details publicly before a fix is deployed

## Scope

| Contract | Address | In Scope |
|----------|---------|----------|
| CoverRouter | 0xd5f8678A... | Yes |
| PolicyManager | 0xCCA07e06... | Yes |
| 4 Vaults | 0xbd44.../0xFee5.../0x429b.../0x1778... | Yes |
| LuminaOracle | 0x4d1140ac... | Yes |
| EmergencyPause | 0xc7ac8c19... | Yes |
| 5 Shields | 0x36e3... (BCS) / 0xA755... (EAS) / 0x7578... (Depeg) / 0x2ac0... (IL) / 0x9870... (Exploit) | Yes |
| API (Node.js) | lumina-protocol-production.up.railway.app | Yes |

## Bug Bounty

We are planning a formal bug bounty program on Immunefi. In the meantime, responsible disclosures will be rewarded based on severity:
- Critical: Up to $50,000
- High: Up to $10,000
- Medium: Up to $2,000

## Audit Reports

- [Security Audit V3 Final](docs/SECURITY-AUDIT-V3-FINAL.md)
- [Anti-Fraud Playbook](docs/ANTI-FRAUD-PLAYBOOK.md)
- [Access Control Matrix](docs/ACCESS-CONTROL-MATRIX.md)

## Known Issues & Accepted Risks

See [SECURITY-AUDIT-V3-FINAL.md](docs/SECURITY-AUDIT-V3-FINAL.md) for documented accepted risks.
