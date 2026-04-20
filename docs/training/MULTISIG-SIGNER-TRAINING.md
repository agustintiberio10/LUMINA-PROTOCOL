# Multisig Signer Training Guide

## LUMINA Protocol V5.0 — Essential Signer Skills

---

## 1. Essential Skills

### 1.1 Reading Transactions

Every multisig transaction contains critical information that must be verified before signing:

- **To Address**: The target contract receiving the call. Always verify against the official contract registry.
- **Value**: Amount of native token (ETH) being sent. Should be `0` for most protocol operations.
- **Data (Calldata)**: The encoded function call. This is the most important field to decode and verify.
- **Nonce**: Sequential transaction number. Ensures correct ordering and prevents replay.
- **Operation**: `0` for CALL, `1` for DELEGATECALL. Protocol operations should almost always be `0`.

### 1.2 Verifying Calldata

Before signing any transaction, decode and verify the calldata:

1. **Identify the function selector** — The first 4 bytes (8 hex characters) identify the function being called.
2. **Decode parameters** — Use tools like:
   - Gnosis Safe Transaction Builder UI
   - `cast calldata-decode` (Foundry)
   - Etherscan's "Decode Input Data"
   - OpenChain signature database
3. **Cross-reference** — Verify decoded parameters against the proposal description.
4. **Check addresses** — Every address parameter must be verified against the contract registry.

Common function selectors to recognize:

| Selector | Function |
|----------|----------|
| `0xa9059cbb` | `transfer(address,uint256)` |
| `0x095ea7b3` | `approve(address,uint256)` |
| `0x8456cb59` | `pause()` |
| `0x3f4ba83a` | `unpause()` |
| `0x3659cfe6` | `upgradeTo(address)` |
| `0x4f1ef286` | `upgradeToAndCall(address,bytes)` |

### 1.3 Hardware Wallet Best Practices

- **Dedicated device**: Use a hardware wallet exclusively for multisig signing. Never use it for personal transactions.
- **Firmware updates**: Keep firmware current, but wait 48 hours after release to confirm no issues.
- **Seed phrase storage**: Store in a fireproof safe, never digitally. Use metal backup plates.
- **Verify on device**: ALWAYS confirm the transaction details on the hardware wallet screen, not just the computer.
- **PIN security**: Use a strong PIN. Enable wipe after failed attempts if supported.
- **Physical security**: Store the device in a secure location when not in use.
- **Passphrase (25th word)**: Consider using a BIP39 passphrase for additional security.

---

## 2. Common Mistakes to Avoid

### Critical Errors

| Mistake | Consequence | Prevention |
|---------|-------------|------------|
| Signing without decoding calldata | Could approve malicious transaction | Always decode and verify every field |
| Trusting the "description" field blindly | Description can be misleading | Independently verify calldata matches intent |
| Signing on a compromised machine | Private key extraction | Use dedicated, hardened machine for signing |
| Reusing nonces | Transaction replacement/front-running | Verify nonce matches expected sequence |
| Not verifying implementation contract | Could upgrade to malicious code | Check implementation is audited and from official deploy |

### Operational Errors

- **Signing too quickly**: Allow minimum 24 hours for review on non-emergency transactions.
- **Not checking timelock status**: Verify the transaction is within the expected timelock window.
- **Ignoring gas parameters**: Extremely high gas could drain the safe's ETH balance.
- **Not coordinating with other signers**: Communicate via secure channels before signing.
- **Signing duplicate transactions**: Check if an equivalent transaction already exists in the queue.

### Social Engineering

- **Never sign** because someone says "it's urgent" without independent verification.
- **Never sign** based solely on a message in Discord/Telegram, even from admins.
- **Always verify** through a separate communication channel (phone call, video).
- **Be suspicious** of any transaction that deviates from standard operations.

---

## 3. Practice Scenarios

### Scenario 1: Allocate Tokens from CEXReserve

**Context**: The team needs to allocate 500,000 LUMINA tokens from the CEXReserve wallet to a new exchange listing address.

**Transaction Details**:
```
To: 0x[CEXReserve Contract Address]
Value: 0
Data: 0xa9059cbb000000000000000000000000[exchange_address_padded]000000000000000000000000000000000000000000000069e10de76676d0800000
```

**Verification Steps**:
1. Decode calldata: `transfer(address recipient, uint256 amount)`
2. Verify recipient address matches the confirmed exchange deposit address (check via separate channel with exchange).
3. Verify amount: `0x69e10de76676d0800000` = 500,000 * 10^18 (500,000 LUMINA with 18 decimals).
4. Confirm the allocation was approved in governance proposal (reference proposal ID).
5. Verify the CEXReserve contract address matches the registry.
6. Check that the transfer does not exceed the approved allocation limit.

**Red Flags to Watch For**:
- Recipient address not matching any known exchange address
- Amount exceeding the approved allocation
- Transaction submitted without corresponding governance approval

---

### Scenario 2: Pause CoverRouter

**Context**: A vulnerability has been reported in the CoverRouter. The security team recommends an immediate pause.

**Transaction Details**:
```
To: 0x[CoverRouterV2 Proxy Address]
Value: 0
Data: 0x8456cb59
```

**Verification Steps**:
1. Decode calldata: `pause()` — no parameters needed.
2. Verify the target address is the actual CoverRouterV2 proxy (check registry).
3. Confirm the pause request came through the proper security channel.
4. Verify that the caller (multisig) has the `PAUSER_ROLE` on CoverRouterV2.
5. Acknowledge that this is a time-sensitive emergency operation.
6. Coordinate with other signers via secure voice/video call.

**Red Flags to Watch For**:
- Target address not matching CoverRouterV2 proxy
- Request coming from unverified source
- No corresponding security advisory or vulnerability report
- Calldata containing additional encoded data beyond the pause selector

**Post-Execution**:
- Confirm pause event emitted on-chain
- Notify the community via incident template (P0 Critical)
- Begin remediation process

---

### Scenario 3: Upgrade Contract via Timelock

**Context**: A new implementation of BondVault has been audited and approved. The upgrade goes through the Timelock controller.

**Transaction Details**:
```
To: 0x[Timelock Controller Address]
Value: 0
Data: 0x01d5062a...[encoded schedule/execute call]
```

**Verification Steps**:
1. Decode the outer call: `schedule(address target, uint256 value, bytes data, bytes32 predecessor, bytes32 salt, uint256 delay)` or `execute(...)`.
2. Decode the inner calldata (the `data` parameter): should be `upgradeTo(address newImplementation)`.
3. Verify the new implementation address:
   - Matches the audited contract deployment
   - Source code is verified on Etherscan
   - Audit report references this exact bytecode/address
4. Verify the timelock delay matches the configured minimum (e.g., 48 hours).
5. If executing: confirm the schedule transaction was already executed and the delay has elapsed.
6. Cross-reference with the governance proposal approving this upgrade.

**Red Flags to Watch For**:
- Implementation address not verified on block explorer
- Timelock delay shorter than minimum configured
- No audit report for the new implementation
- `upgradeToAndCall` with unexpected initialization data
- Predecessor hash not matching expected dependency chain

**Post-Execution**:
- Verify the proxy now points to the new implementation
- Run integration tests against the upgraded contract
- Monitor for 24 hours for any anomalies
- Announce upgrade completion to the community

---

## 4. Signing Checklist (Use Before Every Signature)

- [ ] I have independently decoded the calldata
- [ ] The target address matches our contract registry
- [ ] The function and parameters match the stated intent
- [ ] I have verified this through a separate communication channel
- [ ] The transaction nonce is correct and sequential
- [ ] I have checked for any red flags listed above
- [ ] I am signing on my dedicated hardware wallet
- [ ] I have verified the details on my hardware wallet screen
- [ ] I understand what this transaction will do on-chain

---

*Document Version: 1.0 | Last Updated: 2026-04-19 | LUMINA Protocol V5.0*
