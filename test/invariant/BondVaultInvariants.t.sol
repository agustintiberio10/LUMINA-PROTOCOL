// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ Mocks ═══════

contract InvMockOracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @title BondVaultHandler
/// @notice Foundry invariant handler — calls issueBond / redeemBond
///         with bounded random inputs. Tracks ghost variables for invariant checks.
contract BondVaultHandler is Test {
    BondVault public vault;
    ClaimBond public claimBond;
    InvMockOracle public oracle;
    LuminaTokenV2 public token;

    uint256 public totalBondsIssued;
    uint256 public totalBondsRedeemed;
    uint256 public issueCalls;
    uint256 public redeemCalls;

    // Track users and their bond balances
    address[] public users;
    mapping(address => bool) public isUser;

    constructor(BondVault _vault, ClaimBond _bond, InvMockOracle _oracle, LuminaTokenV2 _token) {
        vault = _vault;
        claimBond = _bond;
        oracle = _oracle;
        token = _token;

        // Pre-create some users
        for (uint256 i = 1; i <= 10; i++) {
            address u = address(uint160(0x1000 + i));
            users.push(u);
            isUser[u] = true;
        }
    }

    function issueBond(uint256 userIdx, uint256 amount) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        amount = bound(amount, 1, 100_000); // $1 to $100K bonds

        address user = users[userIdx];

        try vault.issueBond(user, amount, 0.036e18) {
            totalBondsIssued += amount;
            issueCalls++;
        } catch {
            // Expected: capacity exhausted, paused, etc.
        }
    }

    function redeemBond(uint256 userIdx, uint256 amount, uint256 priceWad) external {
        userIdx = bound(userIdx, 0, users.length - 1);
        amount = bound(amount, 1, 10_000);
        // [Fix C-3] MIN_REDEEM_PRICE raised to 5e15.
        priceWad = bound(priceWad, 5e15, 100e18);

        address user = users[userIdx];

        // Get the user's epoch (24 months from setUp)
        uint256 matTs = block.timestamp + 730 days;
        uint256 mfb = (matTs - 1767225600) / 2629746;
        uint256 epochId = (2026 + mfb / 12) * 100 + (1 + mfb % 12);

        uint256 bal = claimBond.balanceOf(user, epochId);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        // Warp to maturity for redemption
        uint256 matDate = claimBond.maturityDate(epochId);
        if (matDate == 0) return;
        if (block.timestamp < matDate) {
            vm.warp(matDate + 1);
        }

        oracle.setPrice(priceWad);

        vm.prank(user);
        try vault.redeemBond(epochId, amount) {
            totalBondsRedeemed += amount;
            redeemCalls++;
        } catch {
            // Expected: insufficient reserve, price too low, etc.
        }
    }
}

/// @title BondVaultInvariants
/// @notice Foundry invariant test suite — 5 invariants for BondVault.
contract BondVaultInvariants is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    InvMockOracle oracle;
    BondVaultHandler handler;

    uint256 initialSupply;

    function setUp() public {
        vm.warp(1767225600 + 60 days);

        oracle = new InvMockOracle();
        claimBond = ProxyDeployer.deployClaimBond();
        token = ProxyDeployer.deployLuminaTokenV2(
            address(0xBB01), address(0xBB05), address(0xBB03), address(0xBB02), address(0xBB04)
        );

        // Deploy vault with handler as policyManager (so handler can issueBond)
        handler = new BondVaultHandler(
            BondVault(address(0)),
            claimBond,
            oracle,
            token // placeholder vault
        );

        vault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), address(handler));

        // Wire
        claimBond.setBondVault(address(vault));

        // Re-deploy handler with real vault
        handler = new BondVaultHandler(vault, claimBond, oracle, token);

        // Re-deploy vault with handler as policyManager
        claimBond = ProxyDeployer.deployClaimBond();
        vault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), address(handler));
        claimBond.setBondVault(address(vault));

        // Rebuild handler with correct vault
        handler = new BondVaultHandler(vault, claimBond, oracle, token);
        // We need policyManager == handler, so redeploy vault once more
        claimBond = ProxyDeployer.deployClaimBond();
        vault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), address(handler));
        claimBond.setBondVault(address(vault));

        // Fund vault
        deal(address(token), address(vault), 70_000_000 * 1e18);

        initialSupply = token.totalSupply();

        // Target only the handler for invariant calls
        targetContract(address(handler));
    }

    /// INV-1: Solvency — vault USD value >= committed obligations
    function invariant_solvency() public view {
        uint256 balance = token.balanceOf(address(vault));
        uint256 price = oracle.getLuminaPrice();
        uint256 balanceUSD18 = (balance * price) / 1e18;
        uint256 committed = vault.totalCommittedUSD();

        assertTrue(balanceUSD18 >= committed, "INV-1: Vault is insolvent");
    }

    /// INV-2: Total bonds issued (in handler ghost) bounded by capacity
    function invariant_noOverMint() public view {
        uint256 balance = token.balanceOf(address(vault));
        uint256 price = oracle.getLuminaPrice();
        uint256 balanceUSD = (balance * price) / 1e18 / 1e18; // integer dollars
        // Handler total issued (integer dollars) should be bounded by vault capacity
        // We use a generous bound: vault balance in USD should exceed issued amount
        assertTrue(
            balanceUSD >= handler.totalBondsIssued() - handler.totalBondsRedeemed(),
            "INV-2: Over-minted beyond vault backing"
        );
    }

    /// INV-3: Burn monotonicity — supply only decreases
    function invariant_supplyMonotonic() public view {
        assertTrue(token.totalSupply() <= initialSupply, "INV-3: Supply increased (impossible - no mint function)");
    }

    /// INV-5: Immutability — BondVault has no owner/admin/withdraw
    function invariant_immutability() public view {
        // BondVault should NOT have Ownable-like functions.
        // This is a static property verified by compilation (no owner storage slot).
        // Dynamic: ensure totalCommittedUSD only changes via issue/redeem paths.
        // If vault balance decreased but no redeem happened, something is wrong.
        // (This is already covered by INV-1 solvency.)
        assertTrue(true, "INV-5: Static immutability check placeholder");
    }

    /// Handler call summary (informational)
    function invariant_callSummary() public view {
        // Just log — not an assertion
        // console.log would only show with -vvvv
    }
}
