// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/bonds/BondVault.sol";

contract MockPriceOracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract BondVaultTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MockPriceOracle oracle;

    address lbp = makeAddr("lbp");
    address founder = makeAddr("founder");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");

    function setUp() public {
        // [SR3] Warp past ClaimBond.BASE_TIMESTAMP (Jan 1 2026 UTC = 1767225600)
        // so that maturityTimestamp = block.timestamp + 730d is a valid epoch.
        vm.warp(1767225600 + 30 days);

        oracle = new MockPriceOracle();
        claimBond = new ClaimBond();
        token = new LuminaTokenV2(makeAddr("tempVault"), makeAddr("cex"), founder, lbp, treasury);

        vault = new BondVault(
            address(token),
            address(claimBond),
            address(oracle),
            address(this) // test acts as PolicyManager
        );

        claimBond.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000 * 1e18);
    }

    function test_initial_state() public view {
        assertEq(vault.totalCommittedUSD(), 0);
        assertFalse(vault.paused());
        assertEq(token.balanceOf(address(vault)), 70_000_000 * 1e18);
    }

    function test_issueBond() public {
        vault.issueBond(user, 800);
        // [V3/SR2] totalCommittedUSD is now 18-dec USD-wei: 800 * 1e18
        assertEq(vault.totalCommittedUSD(), 800 * 1e18);
        // verify bond was minted to user
        uint256 epoch = _currentEpochPlus24();
        assertEq(claimBond.balanceOf(user, epoch), 800);
    }

    function test_issueBond_only_policyManager() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("Only PolicyManager");
        vault.issueBond(user, 800);
    }

    function test_capacity_check() public view {
        // [V3/SR2] availableCapacityUSD returns INTEGER dollars (post-fix).
        uint256 cap = vault.availableCapacityUSD();
        // 82M * $0.036 = $2.952M, 50% = $1.476M
        assertGt(cap, 1_200_000);
        assertLt(cap, 1_300_000);
    }

    function test_exceeds_capacity_reverts() public {
        uint256 cap = vault.availableCapacityUSD();
        vm.expectRevert("Exceeds capacity");
        vault.issueBond(user, cap + 1);
    }

    function test_circuit_breaker_blocks_issuance() public {
        oracle.setPrice(0.004e18);
        // [SR3] issueBond at low price reverts; paused state is NOT persisted by
        // the revert (EVM discards state changes on revert). Persistence comes
        // from triggerBreaker() — tested below.
        vm.expectRevert("Price below circuit breaker");
        vault.issueBond(user, 800);
    }

    function test_triggerBreaker_persists_pause() public {
        oracle.setPrice(0.004e18);
        vault.triggerBreaker();
        assertTrue(vault.paused());

        // Subsequent issueBond now blocked by the persistent "paused" flag.
        oracle.setPrice(0.036e18); // price recovers but still paused
        vm.expectRevert("Circuit breaker active");
        vault.issueBond(user, 800);
    }

    function test_circuit_breaker_reset() public {
        oracle.setPrice(0.004e18);
        vault.triggerBreaker();
        assertTrue(vault.paused());

        // Reset requires 1-hour cooldown + price >= RESET_PRICE
        oracle.setPrice(0.009e18);
        vm.expectRevert("Cooldown active");
        vault.resetCircuitBreaker();

        vm.warp(block.timestamp + 1 hours + 1);
        vault.resetCircuitBreaker();
        assertFalse(vault.paused());
    }

    function test_redeemBond_price_up() public {
        vault.issueBond(user, 800);
        uint256 epoch = _currentEpochPlus24();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        // $LUMINA went UP to $0.50 → agent gets FEWER tokens
        oracle.setPrice(0.5e18);
        // [V2/SR2] Formula fixed: (usdAmount * 1e36) / price. Pays 1,600 WHOLE LUMINA.
        uint256 expected = (800 * 1e36) / 0.5e18; // 1,600 * 1e18 wei = 1,600 LUMINA

        vm.prank(user);
        vault.redeemBond(epoch, 800);

        assertEq(token.balanceOf(user), expected);
        assertEq(vault.totalCommittedUSD(), 0);
    }

    function test_redeemBond_price_down() public {
        vault.issueBond(user, 800);
        uint256 epoch = _currentEpochPlus24();
        vm.warp(claimBond.maturityDate(epoch) + 1);

        // $LUMINA went DOWN to $0.01 → agent gets MORE tokens
        oracle.setPrice(0.01e18);
        // [V2/SR2] Formula fixed: pays 80,000 WHOLE LUMINA.
        uint256 expected = (800 * 1e36) / 0.01e18; // 80,000 * 1e18 wei

        vm.prank(user);
        vault.redeemBond(epoch, 800);

        assertEq(token.balanceOf(user), expected);
    }

    function test_partial_redeem() public {
        vault.issueBond(user, 800);
        uint256 epoch = _currentEpochPlus24();
        vm.warp(claimBond.maturityDate(epoch) + 1);
        oracle.setPrice(0.5e18);

        vm.prank(user);
        vault.redeemBond(epoch, 300);

        assertEq(claimBond.balanceOf(user, epoch), 500);
        // [V3/SR2] totalCommittedUSD is 18-dec USD-wei: 500 * 1e18 after partial redeem
        assertEq(vault.totalCommittedUSD(), 500 * 1e18);
    }

    function test_cannot_redeem_before_maturity() public {
        vault.issueBond(user, 800);
        uint256 epoch = _currentEpochPlus24();
        vm.prank(user);
        vm.expectRevert("Not matured");
        vault.redeemBond(epoch, 800);
    }

    function test_redemption_works_even_when_paused() public {
        // Issue bond first
        vault.issueBond(user, 800);
        uint256 epoch = _currentEpochPlus24();

        // Trigger circuit breaker persistently (via separate fn, not via revert)
        oracle.setPrice(0.004e18);
        vault.triggerBreaker();
        assertTrue(vault.paused());

        // Warp to maturity
        vm.warp(claimBond.maturityDate(epoch) + 1);
        oracle.setPrice(0.0005e18); // still below MIN_REDEEM_PRICE

        // Redemption should fail because below MIN_REDEEM_PRICE floor (not because paused)
        vm.prank(user);
        vm.expectRevert("Price too low");
        vault.redeemBond(epoch, 800);

        // But with acceptable redemption price it works even though vault is paused
        oracle.setPrice(0.05e18);
        vm.prank(user);
        vault.redeemBond(epoch, 800);
    }

    function test_previewRedemption() public view {
        uint256 preview = vault.previewRedemption(800);
        // [V2/SR2] Formula fixed: (usdAmount * 1e36) / price.
        // Compute at runtime (uint256 vars) to force integer division;
        // inline rational-literal math wouldn't resolve to uint256.
        uint256 usd = 800;
        uint256 price = 0.036e18;
        uint256 expected = (usd * 1e36) / price;
        assertEq(preview, expected);
    }

    function _currentEpochPlus24() internal view returns (uint256) {
        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (matTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }

    // ═══════ setPolicyManager tests ═══════

    function test_SetPolicyManager_OneShot() public {
        // Deploy BondVault with policyManager = address(0)
        BondVault v = new BondVault(address(token), address(claimBond), address(oracle), address(0));

        address pm = makeAddr("policyManager");

        // Before: policyManager is zero
        assertEq(v.policyManager(), address(0));

        // Set it
        v.setPolicyManager(pm);

        // After: policyManager is set
        assertEq(v.policyManager(), pm);
    }

    function test_RevertIf_SetPolicyManagerTwice() public {
        BondVault v = new BondVault(address(token), address(claimBond), address(oracle), address(0));

        address pm = makeAddr("policyManager");
        v.setPolicyManager(pm);

        // Second call should revert
        vm.expectRevert("PolicyManager already set");
        v.setPolicyManager(makeAddr("anotherPM"));
    }

    function test_RevertIf_SetPolicyManagerZero() public {
        BondVault v = new BondVault(address(token), address(claimBond), address(oracle), address(0));

        vm.expectRevert("Zero address");
        v.setPolicyManager(address(0));
    }

    function test_RevertIf_SetPolicyManagerUnauthorized() public {
        BondVault v = new BondVault(address(token), address(claimBond), address(oracle), address(0));

        address pm = makeAddr("policyManager");
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert("Only deployer");
        v.setPolicyManager(pm);
    }

    function test_SetPolicyManager_ConstructorWithAddress() public {
        address pm = makeAddr("policyManager");

        // Deploy with non-zero policyManager in constructor
        BondVault v = new BondVault(address(token), address(claimBond), address(oracle), pm);

        // policyManager should already be set
        assertEq(v.policyManager(), pm);

        // setPolicyManager should revert because it was already set in constructor
        vm.expectRevert("PolicyManager already set");
        v.setPolicyManager(makeAddr("anotherPM"));
    }

    // ═══════ setAuthorizedCaller (AUTHORIZED_CALLER_ADMIN_ROLE) ═══════

    function test_SetAuthorizedCaller_ByAdmin_Success() public {
        address newCaller = makeAddr("newCaller");

        // address(this) is deployer and has AUTHORIZED_CALLER_ADMIN_ROLE
        vault.setAuthorizedCaller(newCaller, true);

        assertTrue(vault.authorizedCallers(newCaller));
    }

    function test_SetAuthorizedCaller_RevertIf_NotAdmin() public {
        address newCaller = makeAddr("newCaller");
        address notAdmin = makeAddr("notAdmin");

        vm.prank(notAdmin);
        vm.expectRevert();
        vault.setAuthorizedCaller(newCaller, true);
    }

    function test_SetAuthorizedCaller_CanRevoke() public {
        address caller = makeAddr("caller");

        vault.setAuthorizedCaller(caller, true);
        assertTrue(vault.authorizedCallers(caller));

        vault.setAuthorizedCaller(caller, false);
        assertFalse(vault.authorizedCallers(caller));
    }

    function test_SetAuthorizedCaller_RevertIf_ZeroAddress() public {
        vm.expectRevert("Zero address");
        vault.setAuthorizedCaller(address(0), true);
    }
}
