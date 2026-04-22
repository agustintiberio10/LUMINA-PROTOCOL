// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {FounderVesting} from "../../src/token/FounderVesting.sol";
import {TreasuryVesting} from "../../src/token/TreasuryVesting.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";
// BondVault and TWAPBurner both declare an IPriceOracle interface. Import only
// the contract from TWAPBurner.sol and use ISwapRouter via an inline struct match.
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";
import {CapacityOracle} from "../../src/oracles/CapacityOracle.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════════════════════════════════════════════════════════
// MOCKS
// ═══════════════════════════════════════════════════════════

contract MockUSDC {
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

contract MockPriceOracle {
    uint256 public price = 0.036e18;

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 p) external {
        price = p;
    }
}

contract MockSwapRouter is IDexRouter {
    IERC20 public lumina;
    uint256 public oraclePrice = 0.036e18;

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function setPrice(uint256 p) external {
        oraclePrice = p;
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * 1e12 * 1e18) / oraclePrice;
        lumina.transfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

// Mock Shield that always allows policy creation and can simulate triggers
contract MockShield {
    bytes32 public _productId;
    address public router;
    uint256 public nextPolicyId = 1;
    mapping(uint256 => bool) public shouldTrigger;
    mapping(uint256 => uint256) public policyCoverage;

    constructor(bytes32 pid, address _router) {
        _productId = pid;
        router = _router;
    }

    function productId() external view returns (bytes32) {
        return _productId;
    }

    function setTrigger(uint256 policyId, bool trigger) external {
        shouldTrigger[policyId] = trigger;
    }

    // Must match IShieldV2.CreatePolicyParams layout (bytes extraData at tail).
    struct CreatePolicyParams {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint32 durationSeconds;
        bytes32 asset;
        bytes32 stablecoin;
        address protocol;
        bytes extraData;
    }

    function createPolicy(CreatePolicyParams calldata params) external returns (uint256) {
        require(msg.sender == router, "Only router");
        uint256 pid = nextPolicyId++;
        policyCoverage[pid] = params.coverageAmount;
        return pid;
    }

    struct PayoutResult {
        bool triggered;
        uint256 payoutAmount;
        address recipient;
        bytes32 reason;
    }

    function verifyAndCalculate(uint256 policyId, bytes calldata) external view returns (PayoutResult memory) {
        return PayoutResult({
            triggered: shouldTrigger[policyId],
            payoutAmount: (policyCoverage[policyId] * 8000) / 10000,
            recipient: address(0),
            reason: "TEST_TRIGGER"
        });
    }
}

// ═══════════════════════════════════════════════════════════
// FULL SYSTEM SETUP
// ═══════════════════════════════════════════════════════════

contract AdversarialAuditTest is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault bondVault;
    MockPriceOracle oracle;
    CapacityOracle capacityOracle;
    TWAPBurner twapBurner;
    PolicyManagerV2 policyManager;
    CoverRouterV2 coverRouter;
    MockUSDC usdc;
    MockSwapRouter swapRouter;
    MockShield shield;

    address deployer;
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");
    address attacker = makeAddr("attacker");
    address relayer = makeAddr("relayer");

    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC1H-001");

    function setUp() public {
        deployer = address(this);
        vm.warp(1767225600 + 60 days); // well past BASE_TIMESTAMP

        // 1. Deploy mocks
        usdc = new MockUSDC();
        oracle = new MockPriceOracle();

        // 2. Deploy ClaimBond
        claimBond = ProxyDeployer.deployClaimBond();

        // 3. Deploy token (need addresses for constructor)
        token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("tempVault"),
            makeAddr("tempCex"),
            makeAddr("tempFounder"),
            makeAddr("tempLbp"),
            makeAddr("tempTreasury")
        );

        // 4. Real swap router with the real token
        swapRouter = new MockSwapRouter(address(token));

        // 5. Deploy CapacityOracle (no pool, emergency price)
        capacityOracle = new CapacityOracle(address(0), address(token), address(usdc), 0.036e18);

        // 6. Deploy BondVault with 2-step init: policyManager set after PolicyManagerV2 deploy
        bondVault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(oracle), address(0));

        // Now deploy real policyManager
        policyManager = ProxyDeployer.deployPolicyManagerV2(address(bondVault));

        // Wire BondVault → PolicyManagerV2 (so reserveCapacity/issueBond auth works)
        bondVault.setPolicyManager(address(policyManager));

        // 7. Deploy TWAPBurner + CoverRouter
        twapBurner = ProxyDeployer.deployTWAPBurner(address(usdc), address(token), address(swapRouter));
        coverRouter = ProxyDeployer.deployCoverRouterV2(address(usdc), address(policyManager), address(twapBurner));

        // 8. Wire everything
        claimBond.setBondVault(address(bondVault));
        policyManager.setRouter(address(coverRouter));
        token.grantRole(token.BURNER_ROLE(), address(twapBurner));

        // 9. Setup shield
        shield = new MockShield(PRODUCT_ID, address(policyManager));
        policyManager.registerProduct(PRODUCT_ID, address(shield));
        coverRouter.configureProduct(PRODUCT_ID, 8000, 20, 15000, 3600, true);

        // 10. Fund the system
        deal(address(token), address(bondVault), 70_000_000 * 1e18);
        deal(address(token), address(swapRouter), 10_000_000 * 1e18); // for burn swaps

        // 11. Fund users
        usdc.mint(user1, 1_000_000e6);
        usdc.mint(user2, 1_000_000e6);
        usdc.mint(user3, 1_000_000e6);
        usdc.mint(attacker, 10_000_000e6);
        usdc.mint(relayer, 1_000_000e6);

        // 12. Setup relayer
        coverRouter.setRelayer(relayer, true);
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 1: FLUJO COMERCIAL NORMAL
    // ═══════════════════════════════════════════════════════════

    function test_flow_buy_no_trigger() public {
        uint256 supplyBefore = token.totalSupply();

        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 100e6);
        uint256 policyId = coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        assertGt(policyId, 0);
        assertEq(usdc.balanceOf(address(twapBurner)), 2_400_000);

        twapBurner.executeBurn();
        assertTrue(token.totalSupply() < supplyBefore);
    }

    function test_flow_buy_trigger_redeem() public {
        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 100e6);
        uint256 policyId = coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        shield.setTrigger(policyId, true);

        // Workaround: bondVault.policyManager == address(this), call issueBond directly
        _issueBondAsPM(user1, 800);

        uint256 epochId = _epochOfCurrentPlus24();
        assertEq(claimBond.balanceOf(user1, epochId), 800);

        vm.warp(claimBond.maturityDate(epochId) + 1);
        oracle.setPrice(0.5e18);

        uint256 balBefore = token.balanceOf(user1);
        vm.prank(user1);
        bondVault.redeemBond(epochId, 800);

        uint256 received = token.balanceOf(user1) - balBefore;
        uint256 expected = (800 * 1e36) / 0.5e18;
        assertEq(received, expected);

        assertEq(claimBond.balanceOf(user1, epochId), 0);
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 2: COMPRAS SIMULTÁNEAS
    // ═══════════════════════════════════════════════════════════

    function test_concurrent_3_purchases_same_block() public {
        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 100e6);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(coverRouter), 100e6);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        vm.startPrank(user3);
        usdc.approve(address(coverRouter), 100e6);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(twapBurner)), 2_400_000 * 3);
    }

    function test_100_purchases_stress() public {
        for (uint256 i = 0; i < 100; i++) {
            address buyer = makeAddr(string(abi.encodePacked("buyer", i)));
            usdc.mint(buyer, 100e6);
            vm.startPrank(buyer);
            usdc.approve(address(coverRouter), 100e6);
            coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
            vm.stopPrank();
        }

        assertEq(usdc.balanceOf(address(twapBurner)), 240_000_000);
        assertEq(policyManager.totalPolicies(), 100);
        assertEq(policyManager.activePolicies(), 100);
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 3: COMPRA SIN FONDOS
    // ═══════════════════════════════════════════════════════════

    function test_buy_zero_balance_reverts() public {
        address broke = makeAddr("broke");
        vm.startPrank(broke);
        usdc.approve(address(coverRouter), 100e6);
        vm.expectRevert();
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();
    }

    function test_buy_insufficient_balance_reverts() public {
        address poor = makeAddr("poor");
        usdc.mint(poor, 1e6);
        vm.startPrank(poor);
        usdc.approve(address(coverRouter), 100e6);
        vm.expectRevert();
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();
    }

    function test_buy_no_approval_reverts() public {
        vm.startPrank(user1);
        vm.expectRevert();
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 4: EDGE CASES DE COBERTURA
    // ═══════════════════════════════════════════════════════════

    function test_min_coverage() public {
        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 100e6);
        uint256 pid = coverRouter.purchasePolicy(PRODUCT_ID, 100e6, "BTC");
        vm.stopPrank();
        assertGt(pid, 0);
    }

    function test_below_min_coverage_reverts() public {
        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 100e6);
        vm.expectRevert();
        coverRouter.purchasePolicy(PRODUCT_ID, 99e6, "BTC");
        vm.stopPrank();
    }

    function test_large_coverage() public {
        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 10_000_000e6);
        uint256 pid = coverRouter.purchasePolicy(PRODUCT_ID, 1_000_000e6, "BTC");
        vm.stopPrank();
        assertGt(pid, 0);
        assertEq(usdc.balanceOf(address(twapBurner)), 2_400_000_000);
    }

    function test_zero_coverage_reverts() public {
        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 100e6);
        vm.expectRevert();
        coverRouter.purchasePolicy(PRODUCT_ID, 0, "BTC");
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 5: CAPACITY EXHAUSTION
    // ═══════════════════════════════════════════════════════════

    function test_exhaust_capacity() public {
        uint256 capacity = bondVault.availableCapacityUSD();
        uint256 chunk = 100_000; // $100K bonds for speed
        uint256 issued = 0;
        while (issued + chunk <= capacity) {
            _issueBondAsPM(user1, chunk);
            issued += chunk;
        }

        uint256 remaining = bondVault.availableCapacityUSD();
        if (remaining < chunk) {
            vm.prank(address(policyManager));
            vm.expectRevert("Exceeds capacity");
            bondVault.issueBond(user1, chunk);
        }
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 6: BOND REDEMPTION EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_redeem_before_maturity_reverts() public {
        _issueBondAsPM(user1, 800);
        uint256 epochId = _epochOfCurrentPlus24();

        vm.prank(user1);
        vm.expectRevert("Not matured");
        bondVault.redeemBond(epochId, 800);
    }

    function test_redeem_more_than_balance_reverts() public {
        _issueBondAsPM(user1, 800);
        uint256 epochId = _epochOfCurrentPlus24();

        vm.warp(claimBond.maturityDate(epochId) + 1);
        oracle.setPrice(0.5e18);

        vm.prank(user1);
        vm.expectRevert("Insufficient bonds");
        bondVault.redeemBond(epochId, 801);
    }

    function test_redeem_zero_reverts() public {
        _issueBondAsPM(user1, 800);
        uint256 epochId = _epochOfCurrentPlus24();

        vm.warp(claimBond.maturityDate(epochId) + 1);

        vm.prank(user1);
        vm.expectRevert("Zero amount");
        bondVault.redeemBond(epochId, 0);
    }

    function test_double_redeem_reverts() public {
        _issueBondAsPM(user1, 800);
        uint256 epochId = _epochOfCurrentPlus24();

        vm.warp(claimBond.maturityDate(epochId) + 1);
        oracle.setPrice(0.5e18);

        vm.startPrank(user1);
        bondVault.redeemBond(epochId, 800);
        vm.expectRevert("Insufficient bonds");
        bondVault.redeemBond(epochId, 800);
        vm.stopPrank();
    }

    function test_partial_redeem_then_transfer() public {
        _issueBondAsPM(user1, 800);
        uint256 epochId = _epochOfCurrentPlus24();

        vm.warp(claimBond.maturityDate(epochId) + 1);
        oracle.setPrice(0.5e18);

        vm.prank(user1);
        bondVault.redeemBond(epochId, 300);
        assertEq(claimBond.balanceOf(user1, epochId), 500);

        vm.prank(user1);
        claimBond.safeTransferFrom(user1, user2, epochId, 500, "");
        assertEq(claimBond.balanceOf(user1, epochId), 0);
        assertEq(claimBond.balanceOf(user2, epochId), 500);

        uint256 bal2Before = token.balanceOf(user2);
        vm.prank(user2);
        bondVault.redeemBond(epochId, 500);
        uint256 received2 = token.balanceOf(user2) - bal2Before;
        uint256 expected2 = (500 * 1e36) / 0.5e18;
        assertEq(received2, expected2);
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 7: ATAQUES
    // ═══════════════════════════════════════════════════════════

    function test_attack_setBondVault_not_owner() public {
        ClaimBond newBond = ProxyDeployer.deployClaimBond();
        vm.prank(attacker);
        vm.expectRevert();
        newBond.setBondVault(attacker);
    }

    function test_attack_mint_bonds_directly() public {
        vm.prank(attacker);
        vm.expectRevert("Only BondVault");
        claimBond.mint(attacker, 202804, 1_000_000);
    }

    function test_attack_issueBond_not_policyManager() public {
        vm.prank(attacker);
        vm.expectRevert("Only PolicyManager");
        bondVault.issueBond(attacker, 1_000_000);
    }

    function test_attack_no_withdraw_function() public view {
        uint256 vaultBalance = token.balanceOf(address(bondVault));
        assertEq(vaultBalance, 70_000_000 * 1e18);
    }

    function test_attack_spend_others_usdc() public {
        vm.prank(attacker);
        vm.expectRevert();
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
    }

    function test_attack_unauthorized_relayer() public {
        vm.prank(attacker);
        vm.expectRevert();
        coverRouter.purchasePolicyFor(PRODUCT_ID, 1000e6, "BTC", attacker);
    }

    function test_attack_register_malicious_shield() public {
        vm.prank(attacker);
        vm.expectRevert();
        policyManager.registerProduct(keccak256("EVIL"), attacker);
    }

    function test_attack_pause_router() public {
        vm.prank(attacker);
        vm.expectRevert();
        coverRouter.setPaused(true);
    }

    function test_attack_change_oracle() public {
        vm.prank(attacker);
        vm.expectRevert();
        twapBurner.setCapacityOracle(attacker);
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 8: BOND ISSUANCE AND REDEMPTION
    // ═══════════════════════════════════════════════════════════

    function test_bond_issuance_at_low_price() public {
        // Circuit breaker removed from BondVault — issuance depends on capacity only
        oracle.setPrice(0.004e18);

        // At low price capacity is reduced but small issuance may work
        uint256 cap = bondVault.availableCapacityUSD();
        if (cap >= 800) {
            _issueBondAsPM(user1, 800);
            assertEq(bondVault.totalCommittedUSD(), 800 * 1e18);
        }
    }

    function test_bond_redemption_works() public {
        _issueBondAsPM(user1, 800);
        uint256 epochId = _epochOfCurrentPlus24();

        vm.warp(claimBond.maturityDate(epochId) + 1);
        oracle.setPrice(0.05e18);

        vm.prank(user1);
        bondVault.redeemBond(epochId, 800);
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 9: TREASURY VESTING ATTACKS
    // ═══════════════════════════════════════════════════════════

    function test_treasury_nonowner_release() public {
        TreasuryVesting tv = new TreasuryVesting(address(token));
        deal(address(token), address(tv), 3_000_000 * 1e18);
        vm.warp(block.timestamp + 180 days + 1);

        vm.prank(attacker);
        vm.expectRevert();
        tv.release(attacker, 250_000 * 1e18);
    }

    function test_treasury_locked() public {
        TreasuryVesting tv = new TreasuryVesting(address(token));
        deal(address(token), address(tv), 3_000_000 * 1e18);

        vm.expectRevert("Still locked");
        tv.release(makeAddr("dest"), 250_000 * 1e18);
    }

    function test_treasury_month0_no_double_drain() public {
        TreasuryVesting tv = new TreasuryVesting(address(token));
        deal(address(token), address(tv), 3_000_000 * 1e18);
        vm.warp(block.timestamp + 180 days + 1);

        tv.release(makeAddr("dest"), 250_000 * 1e18);
        vm.expectRevert("Already released this month");
        tv.release(makeAddr("dest"), 250_000 * 1e18);
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 10: FOUNDER VESTING
    // ═══════════════════════════════════════════════════════════

    function test_founder_locked_before_altseason() public {
        MockFounderOracle fo = new MockFounderOracle();
        MockFounderAave fa = new MockFounderAave();
        FounderVesting fv = new FounderVesting(address(fo), address(fa), address(token), address(usdc), user1);
        deal(address(token), address(fv), 10_000_000 * 1e18);

        vm.expectRevert("Not triggered");
        fv.releaseTranche();
    }

    function test_founder_attacker_cannot_update_recipient() public {
        MockFounderOracle fo = new MockFounderOracle();
        MockFounderAave fa = new MockFounderAave();
        FounderVesting fv = new FounderVesting(address(fo), address(fa), address(token), address(usdc), user1);

        vm.prank(attacker);
        vm.expectRevert();
        fv.updateRecipient(attacker);
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 11: BURN MECHANICS
    // ═══════════════════════════════════════════════════════════

    function test_burn_permanence() public {
        uint256 supplyBefore = token.totalSupply();

        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 100e6);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        twapBurner.executeBurn();
        uint256 supplyAfter = token.totalSupply();
        assertTrue(supplyAfter < supplyBefore);

        assertEq(token.totalBurned(), supplyBefore - supplyAfter);
    }

    function test_burn_cooldown() public {
        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 200e6);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        twapBurner.executeBurn();

        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 200e6);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        vm.expectRevert("Cooldown active");
        twapBurner.executeBurn();

        vm.warp(block.timestamp + 901);
        twapBurner.executeBurn();
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 12: INVARIANT CHECKS
    // ═══════════════════════════════════════════════════════════

    function test_invariant_solvency() public {
        _issueBondAsPM(user1, 800);
        _issueBondAsPM(user2, 1200);
        _issueBondAsPM(user3, 500);

        uint256 balance = token.balanceOf(address(bondVault));
        uint256 price = oracle.getLuminaPrice();
        uint256 balanceUSD = (balance * price) / 1e18;
        uint256 committed = bondVault.totalCommittedUSD() / 1e18;

        assertTrue(balanceUSD >= committed);
    }

    function test_invariant_supply_decreasing() public {
        uint256 s1 = token.totalSupply();

        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 100e6);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        uint256 s2 = token.totalSupply();
        assertTrue(s2 <= s1);

        twapBurner.executeBurn();
        uint256 s3 = token.totalSupply();
        assertTrue(s3 <= s2);
        assertTrue(s3 < s1);
    }

    function test_invariant_burned_tracking() public {
        vm.startPrank(user1);
        usdc.approve(address(coverRouter), 100e6);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        twapBurner.executeBurn();

        assertEq(token.totalBurned(), token.MAX_SUPPLY() - token.totalSupply());
    }

    // ═══════════════════════════════════════════════════════════
    // SECTION 13: PRICE EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_redeem_high_price() public {
        _issueBondAsPM(user1, 800);
        uint256 epochId = _epochOfCurrentPlus24();

        vm.warp(claimBond.maturityDate(epochId) + 1);
        oracle.setPrice(100e18);

        vm.prank(user1);
        bondVault.redeemBond(epochId, 800);

        uint256 expected = (800 * 1e36) / 100e18;
        assertEq(token.balanceOf(user1), expected);
    }

    function test_redeem_floor_price() public {
        _issueBondAsPM(user1, 100);
        uint256 epochId = _epochOfCurrentPlus24();

        vm.warp(claimBond.maturityDate(epochId) + 1);
        oracle.setPrice(0.001e18);

        vm.prank(user1);
        bondVault.redeemBond(epochId, 100);

        uint256 expected = (100 * 1e36) / 0.001e18;
        assertEq(token.balanceOf(user1), expected);
    }

    function test_oracle_zero_uses_floor() public {
        _issueBondAsPM(user1, 800);
        uint256 epochId = _epochOfCurrentPlus24();

        vm.warp(claimBond.maturityDate(epochId) + 1);
        oracle.setPrice(0);

        vm.prank(user1);
        bondVault.redeemBond(epochId, 800);

        uint256 expected = (800 * 1e36) / 0.001e18;
        assertEq(token.balanceOf(user1), expected);
    }

    // ═══════════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @dev Helper: issue bond via policyManager (required since V5 reservation system)
    function _issueBondAsPM(address to, uint256 usdPayout) internal {
        vm.prank(address(policyManager));
        bondVault.issueBond(to, usdPayout);
    }

    function _epochOfCurrentPlus24() internal view returns (uint256) {
        uint256 matTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (matTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }
}

// Simple mocks for FounderVesting tests
contract MockFounderOracle {
    function getLatestPrice(bytes32) external pure returns (int256) {
        return 3000_00000000;
    }
}

contract MockFounderAave {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address) external pure returns (ReserveData memory data) {
        data.currentVariableBorrowRate = 5e25;
    }
}
