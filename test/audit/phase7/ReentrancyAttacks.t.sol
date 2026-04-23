// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {LuminaBondMarketplace} from "../../../src/marketplace/LuminaBondMarketplace.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ═══════════════════════════════════════════════════════════
// MOCKS
// ═══════════════════════════════════════════════════════════

contract MockPriceOracleR {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract MockUSDCR {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] < amount) revert("Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ═══════════════════════════════════════════════════════════
// MALICIOUS CONTRACTS
// ═══════════════════════════════════════════════════════════

/// @dev Malicious ERC-1155 receiver that tries to re-enter BondVault.issueBond
///      during the onERC1155Received callback triggered by ClaimBond.mint.
contract MaliciousBondReceiver {
    BondVault public vault;
    address public policyManager;
    uint256 public attackCount;
    bool public attackBlocked;

    constructor(address _vault, address _policyManager) {
        vault = BondVault(_vault);
        policyManager = _policyManager;
    }

    /// @dev ERC-1155 callback -- tries to call issueBond again to re-enter BondVault.
    ///      BondVault.issueBond has nonReentrant, so this should revert.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        attackCount++;
        if (attackCount < 2) {
            // Try to re-enter issueBond via the policyManager impersonation
            // This will fail because BondVault.issueBond is nonReentrant
            try vault.issueBond(address(this), 100) {
            // If we reach here, the attack succeeded (should never happen)
            }
            catch {
                attackBlocked = true;
            }
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165
            || interfaceId == 0x4e2312e0; // ERC1155Receiver
    }
}

/// @dev Malicious ERC-1155 receiver that tries to re-enter BondVault.redeemBond
///      during the ERC-1155 burn callback path.
contract MaliciousRedeemReceiver {
    BondVault public vault;
    ClaimBond public bond;
    uint256 public targetEpoch;
    uint256 public attackCount;
    bool public attackBlocked;

    constructor(address _vault, address _bond) {
        vault = BondVault(_vault);
        bond = ClaimBond(_bond);
    }

    function triggerRedeem(uint256 epochId, uint256 amount) external {
        targetEpoch = epochId;
        attackCount = 0;
        attackBlocked = false;
        vault.redeemBond(epochId, amount);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        attackCount++;
        if (attackCount < 2 && bond.balanceOf(address(this), targetEpoch) > 0) {
            try vault.redeemBond(targetEpoch, bond.balanceOf(address(this), targetEpoch)) {
            // Attack succeeded -- should never happen
            }
            catch {
                attackBlocked = true;
            }
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x4e2312e0;
    }
}

/// @dev Malicious ERC-1155 receiver that tries to re-enter marketplace.executeBuy
///      when it receives the bond token from a purchase.
contract MaliciousMarketBuyer {
    LuminaBondMarketplace public marketplace;
    uint256 public targetListingId;
    uint256 public attackCount;
    bool public attackBlocked;

    constructor(address _marketplace) {
        marketplace = LuminaBondMarketplace(_marketplace);
    }

    function maliciousBuy(uint256 listingId) external {
        targetListingId = listingId;
        attackCount = 0;
        attackBlocked = false;
        marketplace.executeBuy(listingId);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        attackCount++;
        if (attackCount < 2) {
            try marketplace.executeBuy(targetListingId) {
            // Attack succeeded -- should never happen
            }
            catch {
                attackBlocked = true;
            }
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x4e2312e0;
    }
}

// ═══════════════════════════════════════════════════════════
// TEST CONTRACT
// ═══════════════════════════════════════════════════════════

contract ReentrancyAttacks is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault bondVault;
    MockPriceOracleR oracle;
    MockUSDCR usdc;
    LuminaBondMarketplace marketplace;

    address deployer;
    address user1 = makeAddr("user1");
    address twapBurner = makeAddr("twapBurner"); // dummy for marketplace fees

    function setUp() public {
        deployer = address(this);
        vm.warp(1767225600 + 60 days);

        // Deploy mocks
        usdc = new MockUSDCR();
        oracle = new MockPriceOracleR();

        // Deploy ClaimBond
        claimBond = ProxyDeployer.deployClaimBond();

        // Deploy token with unique addresses
        token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("tempVault"),
            makeAddr("tempCex"),
            makeAddr("tempFounder"),
            makeAddr("tempLbp"),
            makeAddr("tempTreasury")
        );

        // Deploy BondVault -- this test contract acts as policyManager
        bondVault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), address(this));

        // Wire ClaimBond
        claimBond.setBondVault(address(bondVault));

        // Deploy marketplace
        marketplace =
            ProxyDeployer.deployLuminaBondMarketplace(address(claimBond), address(usdc), twapBurner, address(this));
        // [FIX-#18] Whitelist marketplace so ClaimBond allows its transfers.
        claimBond.setAuthorizedOperator(address(marketplace), true);

        // Fund the vault with LUMINA
        deal(address(token), address(bondVault), 70_000_000 * 1e18);
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 1: Reentrancy via ERC-1155 callback on issueBond
    // ═══════════════════════════════════════════════════════════

    /// @notice A malicious contract receives a bond (ERC-1155 mint callback) and
    ///         tries to call issueBond again. The nonReentrant modifier blocks it.
    function test_Audit_BondVault_NoReentrancyViaERC1155Hook() public {
        MaliciousBondReceiver attacker = new MaliciousBondReceiver(address(bondVault), address(this));

        // Issue bond to the malicious receiver -- triggers onERC1155Received
        // which tries to call issueBond again
        bondVault.issueBond(address(attacker), 500);

        // Verify: attacker's re-entrant call was blocked
        assertTrue(attacker.attackBlocked(), "Reentrancy via ERC-1155 hook was NOT blocked");
        assertEq(attacker.attackCount(), 1, "Callback should have fired exactly once");

        // Verify: only the original 500 bonds were issued, not 500+100
        uint256 epochId = _epochOfCurrentPlus24();
        assertEq(claimBond.balanceOf(address(attacker), epochId), 500, "Should only have 500 bonds");
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 2: Reentrancy during marketplace executeBuy
    // ═══════════════════════════════════════════════════════════

    /// @notice A malicious buyer receives a bond via executeBuy (ERC-1155 transfer callback)
    ///         and tries to call executeBuy again. The nonReentrant modifier blocks it.
    function test_Audit_Marketplace_NoReentrancyDuringExecuteBuy() public {
        // Setup: user1 lists a bond on the marketplace
        uint256 epochId = _epochOfCurrentPlus24();
        bondVault.issueBond(user1, 100);

        vm.startPrank(user1);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 100, 50e6); // $50 USDC
        vm.stopPrank();

        // Deploy malicious buyer
        MaliciousMarketBuyer attacker = new MaliciousMarketBuyer(address(marketplace));

        // Fund attacker with USDC (price + buyer fee)
        uint256 buyerFee = (50e6 * 150) / 10000; // 1.5%
        uint256 totalCost = 50e6 + buyerFee;
        usdc.mint(address(attacker), totalCost * 2); // extra for potential re-entry

        // Approve marketplace
        vm.prank(address(attacker));
        usdc.approve(address(marketplace), totalCost * 2);

        // Execute malicious buy -- callback tries to re-enter executeBuy
        vm.prank(address(attacker));
        attacker.maliciousBuy(listingId);

        // Verify: reentrancy was blocked (listing is already inactive on re-entry attempt)
        assertTrue(attacker.attackBlocked(), "Marketplace reentrancy was NOT blocked");
        assertEq(claimBond.balanceOf(address(attacker), epochId), 100, "Should have exactly 100 bonds");
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 3: Reentrancy on redeemBond
    // ═══════════════════════════════════════════════════════════

    /// @notice A malicious contract holds bonds, calls redeemBond, and in the
    ///         transfer callback tries to redeem again. nonReentrant blocks it.
    function test_Audit_BondVault_RedeemNoReentrancy() public {
        MaliciousRedeemReceiver attacker = new MaliciousRedeemReceiver(address(bondVault), address(claimBond));

        uint256 epochId = _epochOfCurrentPlus24();

        // Issue bonds to attacker
        bondVault.issueBond(address(attacker), 500);
        assertEq(claimBond.balanceOf(address(attacker), epochId), 500);

        // Warp past maturity
        vm.warp(claimBond.maturityDate(epochId) + 1);
        oracle.setPrice(0.5e18);

        // Record balances before
        uint256 vaultBalBefore = token.balanceOf(address(bondVault));

        // Attacker tries to redeem + re-enter
        vm.prank(address(attacker));
        attacker.triggerRedeem(epochId, 200);

        // Verify: only 200 bonds were redeemed (re-entry was blocked)
        // The redeemBond path: burn bonds first, then transfer LUMINA.
        // ClaimBond._burn does NOT trigger onERC1155Received (burn != transfer to contract).
        // But the token.transfer of LUMINA also doesn't trigger ERC-1155 callbacks.
        // The nonReentrant guard is still the primary defense.
        uint256 expectedLumina = (200 * 1e36) / 0.5e18;
        uint256 vaultBalAfter = token.balanceOf(address(bondVault));
        assertEq(vaultBalBefore - vaultBalAfter, expectedLumina, "Only 200 bonds worth of LUMINA should leave vault");
        assertEq(claimBond.balanceOf(address(attacker), epochId), 300, "Should have 300 remaining bonds");
    }

    // ═══════════════════════════════════════════════════════════
    // TEST 4: Cross-contract reentrancy BondVault -> Marketplace
    // ═══════════════════════════════════════════════════════════

    /// @notice Verifies that a cross-contract reentrancy vector (issuing a bond whose
    ///         callback tries to manipulate the marketplace) is not possible because
    ///         each contract has independent nonReentrant guards.
    function test_Audit_CrossContract_BondVault_To_Marketplace() public {
        // Setup: user1 lists a bond on marketplace
        uint256 epochId = _epochOfCurrentPlus24();
        bondVault.issueBond(user1, 100);

        vm.startPrank(user1);
        claimBond.setApprovalForAll(address(marketplace), true);
        uint256 listingId = marketplace.list(epochId, 50, 30e6);
        vm.stopPrank();

        // Deploy a contract that, on receiving bonds from issueBond, tries to buy from marketplace
        CrossContractAttacker attacker =
            new CrossContractAttacker(address(bondVault), address(marketplace), address(usdc), address(claimBond));
        attacker.setTargetListing(listingId);

        // Fund attacker for marketplace purchase
        uint256 buyerFee = (30e6 * 150) / 10000;
        uint256 totalCost = 30e6 + buyerFee;
        usdc.mint(address(attacker), totalCost);
        vm.prank(address(attacker));
        usdc.approve(address(marketplace), totalCost);

        // Issue bond to attacker -- callback tries to executeBuy on marketplace
        // This is cross-contract: BondVault's nonReentrant doesn't block marketplace
        // BUT marketplace.executeBuy has its OWN nonReentrant, so it succeeds independently.
        // The key assertion: the BondVault state is consistent after the cross-contract call.
        bondVault.issueBond(address(attacker), 200);

        // Verify: attacker got 200 bonds from issueBond
        assertEq(claimBond.balanceOf(address(attacker), epochId), 200 + 50, "Should have 250 bonds total");

        // Verify: marketplace listing was bought (cross-contract call succeeded -- this is safe
        // because each contract has its own reentrancy guard)
        assertTrue(attacker.crossCallSucceeded(), "Cross-contract call should succeed (independent guards)");

        // Verify: BondVault state is consistent
        // totalCommittedUSD should reflect both issuances: user1(100) + attacker(200) = 300
        // Note: user1's 50 bonds went to marketplace, then to attacker -- no new commitment
        assertEq(bondVault.totalCommittedUSD(), (100 + 200) * 1e18, "Committed USD should be correct");
    }

    // ═══════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════

    function _epochOfCurrentPlus24() internal view returns (uint256) {
        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (matTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }
}

/// @dev Attacker that tries cross-contract reentrancy: on receiving bonds from BondVault,
///      it attempts to call marketplace.executeBuy.
contract CrossContractAttacker {
    BondVault public vault;
    LuminaBondMarketplace public marketplace;
    MockUSDCR public usdc;
    ClaimBond public bond;
    uint256 public targetListingId;
    bool public crossCallSucceeded;

    constructor(address _vault, address _marketplace, address _usdc, address _bond) {
        vault = BondVault(_vault);
        marketplace = LuminaBondMarketplace(_marketplace);
        usdc = MockUSDCR(_usdc);
        bond = ClaimBond(_bond);
    }

    function setTargetListing(uint256 id) external {
        targetListingId = id;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        // During BondVault.issueBond callback, try to interact with marketplace
        if (!crossCallSucceeded) {
            try marketplace.executeBuy(targetListingId) {
                crossCallSucceeded = true;
            } catch {}
        }
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x4e2312e0;
    }
}
