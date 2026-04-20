# Developer Onboarding Guide

## LUMINA Protocol V5.0 — Getting Started

---

## 1. Prerequisites

### Required Knowledge

- Solidity (v0.8.x) — intermediate to advanced
- OpenZeppelin contracts library (v4.x/v5.x)
- Upgradeable proxy patterns (UUPS, TransparentProxy)
- Foundry (forge, cast, anvil) for testing and deployment
- Git workflow and conventional commits

### Required Tools

| Tool | Version | Purpose |
|------|---------|---------|
| Foundry | Latest | Build, test, deploy |
| Node.js | >= 18.x | Scripts and tooling |
| Git | >= 2.30 | Version control |
| VS Code | Latest | IDE (recommended) |
| Slither | >= 0.9 | Static analysis |

### Environment Setup

```bash
# Clone the repository
git clone <repo-url> && cd LUMINA-PROTOCOL

# Install Foundry dependencies
forge install

# Install Node dependencies (for scripts/tooling)
npm install

# Copy environment template
cp .env.example .env

# Run tests to verify setup
forge test
```

---

## 2. Repository Structure

```
LUMINA-PROTOCOL/
├── src/
│   ├── token/            # LuminaTokenV2, vesting, distribution
│   ├── bond/             # BondVault, bond pricing, yield
│   ├── cover/            # CoverRouterV2, policies, claims
│   ├── shield/           # BaseShield, shield pools, risk
│   ├── burn/             # TWAPBurner, buyback mechanisms
│   ├── governance/       # Timelock, access control, multisig integration
│   └── libraries/        # Shared utilities and math libraries
├── test/
│   ├── unit/             # Isolated contract tests
│   ├── integration/      # Cross-contract interaction tests
│   ├── invariant/        # Fuzz/invariant tests
│   └── fork/             # Mainnet fork tests
├── script/
│   ├── deploy/           # Deployment scripts
│   └── ops/              # Operational scripts (pause, upgrade, etc.)
├── docs/
│   ├── architecture/     # System design documents
│   ├── runbooks/         # Operational runbooks
│   ├── training/         # Training materials (you are here)
│   ├── communications/   # Community templates
│   ├── legal/            # Compliance documents
│   └── audit/            # Audit reports and findings
├── monitoring/           # Alert configurations and dashboards
└── foundry.toml          # Foundry configuration
```

---

## 3. Critical Contracts to Understand First

Study these contracts in the following order. Each builds on concepts from the previous:

### 3.1 LuminaTokenV2 (`src/token/LuminaTokenV2.sol`)

The core ERC-20 token with upgradeable proxy pattern.

**Key Concepts**:
- UUPS upgradeable pattern
- Role-based access control (MINTER_ROLE, PAUSER_ROLE)
- Snapshot functionality for governance
- Permit (EIP-2612) for gasless approvals
- Transfer hooks for compliance

**Why First**: Everything in the protocol revolves around this token. Understanding its roles and permissions is foundational.

### 3.2 BondVault (`src/bond/BondVault.sol`)

Manages bond deposits, maturity, and yield distribution.

**Key Concepts**:
- Bond pricing curves and discount mechanisms
- Vesting schedules and maturity periods
- Yield accrual and distribution logic
- Integration with LuminaTokenV2 for minting rewards

**Why Second**: Bonds are the primary value accrual mechanism. Understanding how tokens flow in and out is critical.

### 3.3 CoverRouterV2 (`src/cover/CoverRouterV2.sol`)

Entry point for purchasing parametric insurance coverage.

**Key Concepts**:
- Policy creation and premium calculation
- Oracle integration for trigger conditions
- Claim processing and payout logic
- Pool routing and capacity management

**Why Third**: The CoverRouter is the main user-facing contract and orchestrates interactions between shields and users.

### 3.4 BaseShield (`src/shield/BaseShield.sol`)

Abstract base for all shield pool implementations.

**Key Concepts**:
- Capital pool management
- Risk parameter configuration
- Underwriting capacity calculation
- Trigger verification and payout execution
- Inheritance pattern for specific shield types

**Why Fourth**: Shields are the insurance backbone. Understanding BaseShield lets you understand all derived shield types.

### 3.5 TWAPBurner (`src/burn/TWAPBurner.sol`)

Automated token buyback and burn mechanism using time-weighted average pricing.

**Key Concepts**:
- TWAP calculation from oracle feeds
- Buyback execution with slippage protection
- Burn scheduling and rate limiting
- DEX integration (Uniswap V3)

**Why Fifth**: The burn mechanism creates deflationary pressure and is key to tokenomics. It ties together oracle usage and DEX interaction.

---

## 4. Development Workflow

### Branch Strategy

```
main                    # Production deployments
├── develop             # Integration branch
│   ├── feat/*          # New features
│   ├── fix/*           # Bug fixes
│   ├── refactor/*      # Code improvements
│   └── test/*          # Test additions
```

### Development Cycle

1. **Create branch** from `develop`: `git checkout -b feat/your-feature`
2. **Write tests first** — follow TDD approach
3. **Implement** the feature/fix
4. **Run full test suite**: `forge test`
5. **Run static analysis**: `slither src/your-contract.sol`
6. **Gas optimization**: `forge test --gas-report`
7. **Create PR** against `develop` with description and test plan
8. **Code review** — minimum 2 approvals required
9. **CI passes** — all tests, linting, and analysis must pass

### Testing Requirements

- **Unit test coverage**: Minimum 95% line coverage for all new code
- **Integration tests**: Required for any cross-contract interaction
- **Invariant tests**: Required for any contract handling funds
- **Fork tests**: Required for any oracle or DEX integration

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/unit/BondVault.t.sol

# Run with coverage
forge coverage

# Run invariant tests
forge test --match-contract Invariant
```

---

## 5. Security Checklist

Every contract and PR must satisfy the following security requirements:

### 5.1 ReentrancyGuard

- [ ] All external functions that transfer funds use `nonReentrant` modifier
- [ ] Cross-contract calls are identified and protected
- [ ] Callback patterns (e.g., ERC-721 `onERC721Received`) are reviewed for reentrancy

```solidity
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract MyContract is ReentrancyGuard {
    function withdraw(uint256 amount) external nonReentrant {
        // Safe from reentrancy
    }
}
```

### 5.2 Checks-Effects-Interactions (CEI)

- [ ] All state changes occur BEFORE external calls
- [ ] No state reads after external calls that could be stale
- [ ] Pattern is documented in comments for complex functions

```solidity
function withdraw(uint256 amount) external nonReentrant {
    // CHECKS
    require(balances[msg.sender] >= amount, "Insufficient balance");

    // EFFECTS
    balances[msg.sender] -= amount;

    // INTERACTIONS
    token.safeTransfer(msg.sender, amount);
}
```

### 5.3 AccessControl

- [ ] All privileged functions have appropriate role checks
- [ ] Roles follow least-privilege principle
- [ ] Role admin hierarchy is documented
- [ ] No functions are unintentionally public/external
- [ ] `onlyRole` or equivalent modifier on all admin functions

```solidity
bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

function setParameter(uint256 value) external onlyRole(OPERATOR_ROLE) {
    // Only authorized operators can call
}
```

### 5.4 Events

- [ ] All state-changing functions emit events
- [ ] Events include both old and new values for updates
- [ ] Events are indexed appropriately for off-chain filtering
- [ ] Critical operations emit events BEFORE external calls

```solidity
event ParameterUpdated(uint256 indexed id, uint256 oldValue, uint256 newValue);

function updateParameter(uint256 id, uint256 newValue) external onlyRole(ADMIN_ROLE) {
    uint256 oldValue = parameters[id];
    parameters[id] = newValue;
    emit ParameterUpdated(id, oldValue, newValue);
}
```

### 5.5 Input Validation

- [ ] All external inputs are validated with meaningful revert messages
- [ ] Address parameters checked for `address(0)`
- [ ] Numeric parameters checked for reasonable bounds
- [ ] Array inputs checked for length limits (gas DoS prevention)
- [ ] Enum values validated against valid range

```solidity
function setRecipient(address newRecipient, uint256 amount) external {
    require(newRecipient != address(0), "Zero address");
    require(amount > 0, "Amount must be positive");
    require(amount <= MAX_AMOUNT, "Exceeds maximum");
    // ...
}
```

### 5.6 SafeERC20

- [ ] All ERC-20 interactions use SafeERC20 library
- [ ] Never use raw `transfer()` or `transferFrom()`
- [ ] Approve patterns use `safeIncreaseAllowance` or reset to 0 first
- [ ] Return values are handled (SafeERC20 does this automatically)

```solidity
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MyContract {
    using SafeERC20 for IERC20;

    function deposit(IERC20 token, uint256 amount) external {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }
}
```

---

## 6. Additional Security Considerations

- **Upgradeable contracts**: Always use `initializer` modifier, never `constructor`
- **Storage collisions**: Follow EIP-7201 namespaced storage pattern
- **Oracle manipulation**: Use TWAP, not spot price. Validate freshness.
- **Flash loan attacks**: Consider atomic composability in all calculations
- **Frontrunning**: Use commit-reveal or private mempools where applicable
- **Integer overflow**: Solidity 0.8+ has built-in checks, but be aware of unchecked blocks
- **Denial of Service**: Avoid unbounded loops, prefer pull over push patterns

---

## 7. Resources

- **Internal**: Architecture docs in `docs/architecture/`
- **OpenZeppelin**: https://docs.openzeppelin.com
- **Foundry Book**: https://book.getfoundry.sh
- **Security**: Trail of Bits building-secure-contracts guide
- **Style Guide**: Follow Solidity style guide + project-specific conventions in `.solhint.json`

---

## 8. Getting Help

- **Technical questions**: Post in the `#dev-discussion` channel
- **Security concerns**: Report via `#security-private` (restricted access)
- **Code reviews**: Tag `@protocol-team` in PR
- **Deployment questions**: Refer to runbooks in `docs/runbooks/`

---

*Document Version: 1.0 | Last Updated: 2026-04-19 | LUMINA Protocol V5.0*
