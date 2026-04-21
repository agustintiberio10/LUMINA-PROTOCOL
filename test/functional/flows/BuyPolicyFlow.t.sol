// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../../src/interfaces/IDexRouter.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract MockUSDC_BPF {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract MockSwapRouter_BPF is IDexRouter {
    IERC20 public lumina;
    uint256 public rate = 27; // 1 USDC = 27 LUMINA

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * rate * 1e12;
        lumina.transfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract MockShieldV2_BPF {
    bytes32 public productId;
    uint256 private _nextPolicyId;

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

    struct PayoutResult {
        bool triggered;
        uint256 payoutAmount;
        address recipient;
        bytes32 reason;
    }

    mapping(uint256 => address) public policyBuyer;

    constructor(bytes32 _productId) {
        productId = _productId;
    }

    function createPolicy(CreatePolicyParams calldata params) external returns (uint256 policyId) {
        _nextPolicyId++;
        policyId = _nextPolicyId;
        policyBuyer[policyId] = params.buyer;
    }

    function verifyAndCalculate(uint256 policyId, bytes calldata) external view returns (PayoutResult memory result) {
        result = PayoutResult({
            triggered: true, payoutAmount: 800e6, recipient: policyBuyer[policyId], reason: "MOCK_TRIGGER"
        });
    }

    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (address insuredAgent, uint256, uint256, uint256, uint256, uint8)
    {
        return (policyBuyer[policyId], 0, 0, 0, 0, 0);
    }
}

contract MockPriceOracle_BPF {
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

/// @title BuyPolicyFlowTest
/// @notice Phase 7.4 functional flow tests for the buy-policy lifecycle.
///         Tests PolicyManagerV2 + BondVault + ClaimBond integration.
contract BuyPolicyFlowTest is Test {
    // ═══════ CORE CONTRACTS (real) ═══════
    LuminaTokenV2 token;
    BondVault bondVault;
    ClaimBond claimBond;
    TWAPBurner twapBurner;
    PolicyManagerV2 policyManager;
    CoverRouterV2 coverRouter;

    // ═══════ MOCKS ═══════
    MockUSDC_BPF usdc;
    MockSwapRouter_BPF swapRouter;
    MockShieldV2_BPF mockShield;
    MockPriceOracle_BPF priceOracle;

    // ═══════ ADDRESSES ═══════
    address cexReserve = makeAddr("cexReserve");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");

    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");
    address agent3 = makeAddr("agent3");

    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC1H-FLOW");
    uint256 constant BASE_TS = 1767225600; // Jan 1 2026 UTC

    function setUp() public {
        // Warp to 60 days after epoch base
        vm.warp(BASE_TS + 60 days);

        // 1. Deploy mocks
        usdc = new MockUSDC_BPF();
        priceOracle = new MockPriceOracle_BPF(0.036e18); // $0.036

        // 2. Deploy ClaimBond
        claimBond = ProxyDeployer.deployClaimBond();

        // 3. Predict BondVault address for token constructor
        uint64 currentNonce = vm.getNonce(address(this));
        // token via proxy(+2), swapRouter(+1), twapBurner(+1), policyManager via proxy(+2), bondVault proxy at +7
        address predictedBondVault = vm.computeCreateAddress(address(this), currentNonce + 7);

        // 4. Deploy token
        token = ProxyDeployer.deployLuminaTokenV2(
            predictedBondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting
        );

        // 5. Deploy swap router mock
        swapRouter = new MockSwapRouter_BPF(address(token));
        deal(address(token), address(swapRouter), 1_000_000e18);

        // 6. Deploy TWAPBurner
        twapBurner = new TWAPBurner(address(usdc), address(token), address(swapRouter));

        // 7. Deploy PolicyManagerV2
        policyManager = ProxyDeployer.deployPolicyManagerV2(predictedBondVault);

        // 8. Deploy BondVault
        bondVault = ProxyDeployer.deployBondVault(
            address(token), address(claimBond), address(priceOracle), address(policyManager)
        );
        require(address(bondVault) == predictedBondVault, "BondVault address mismatch");

        // 9. Wire ClaimBond -> BondVault
        claimBond.setBondVault(address(bondVault));

        // 10. Grant BURNER_ROLE to TWAPBurner
        token.grantRole(token.BURNER_ROLE(), address(twapBurner));

        // 11. Deploy MockShield and register product
        mockShield = new MockShieldV2_BPF(PRODUCT_ID);
        policyManager.registerProduct(PRODUCT_ID, address(mockShield));

        // 12. Deploy CoverRouter
        coverRouter = ProxyDeployer.deployCoverRouterV2(address(usdc), address(policyManager), address(twapBurner));

        // 13. Wire PolicyManager -> CoverRouter
        policyManager.setRouter(address(coverRouter));

        // 14. Configure product in CoverRouter
        coverRouter.configureProduct(
            PRODUCT_ID,
            8000, // 80% payout ratio
            200, // 2% trigger probability
            15000, // 1.5x margin
            3600, // 1 hour duration
            true
        );

        // 15. Fund agents with USDC
        usdc.mint(agent1, 10_000_000e6);
        usdc.mint(agent2, 10_000_000e6);
        usdc.mint(agent3, 10_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════

    /// @dev Compute the epochId for a bond issued at `issueTimestamp`.
    function _computeEpochId(uint256 issueTimestamp) internal pure returns (uint256) {
        uint256 maturityTs = issueTimestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }

    /// @dev Buy a policy as `buyer` and trigger it so bonds are issued.
    function _buyAndTrigger(address buyer, uint256 coverageAmount)
        internal
        returns (uint256 policyId, uint256 epochId)
    {
        vm.startPrank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);
        policyId = coverRouter.purchasePolicy(PRODUCT_ID, coverageAmount, "BTC");
        vm.stopPrank();

        epochId = _computeEpochId(block.timestamp);

        // Trigger the policy (permissionless)
        coverRouter.submitTrigger(PRODUCT_ID, policyId, "");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 1: Happy path - buy policy, trigger, verify bond minted
    // ═══════════════════════════════════════════════════════════

    function test_Flow_BuyPolicy_HappyPath() public {
        uint256 coverageAmount = 1000e6; // $1,000

        // Buy policy
        vm.startPrank(agent1);
        usdc.approve(address(coverRouter), type(uint256).max);
        uint256 policyId = coverRouter.purchasePolicy(PRODUCT_ID, coverageAmount, "BTC");
        vm.stopPrank();

        // Verify policy recorded in PolicyManager
        assertEq(policyManager.totalPolicies(), 1, "Should have 1 policy");
        assertEq(policyManager.activePolicies(), 1, "Should have 1 active policy");

        PolicyManagerV2.PolicyRecord memory pr = policyManager.getPolicy(PRODUCT_ID, policyId);
        assertEq(pr.buyer, agent1, "Policy buyer should be agent1");
        assertEq(pr.coverageAmount, coverageAmount, "Coverage amount mismatch");
        assertFalse(pr.triggered, "Policy should not be triggered yet");
        assertFalse(pr.expired, "Policy should not be expired");

        // Trigger the policy => bond gets issued
        uint256 commitBefore = bondVault.totalCommittedUSD();
        coverRouter.submitTrigger(PRODUCT_ID, policyId, "");

        // Verify bond NFT minted (ERC-1155)
        uint256 epochId = _computeEpochId(block.timestamp);
        uint256 bondBalance = claimBond.balanceOf(agent1, epochId);
        // payout = 1000e6 * 80% = 800e6 USDC => payoutUSD = 800 integer dollars => 800 bond tokens
        assertEq(bondBalance, 800, "Agent1 should have 800 bond tokens ($800)");

        // Verify committed USD increased
        uint256 commitAfter = bondVault.totalCommittedUSD();
        assertEq(commitAfter, commitBefore + 800 * 1e18, "Committed USD should increase by 800 * 1e18");

        // Verify policy is marked triggered
        PolicyManagerV2.PolicyRecord memory prAfter = policyManager.getPolicy(PRODUCT_ID, policyId);
        assertTrue(prAfter.triggered, "Policy should be triggered");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 2: Policy expires without trigger - no bond issued
    // ═══════════════════════════════════════════════════════════

    function test_Flow_PolicyExpires_NoBond() public {
        uint256 coverageAmount = 1000e6;

        // Buy policy
        vm.startPrank(agent1);
        usdc.approve(address(coverRouter), type(uint256).max);
        uint256 policyId = coverRouter.purchasePolicy(PRODUCT_ID, coverageAmount, "BTC");
        vm.stopPrank();

        assertEq(policyManager.activePolicies(), 1, "Should have 1 active policy");

        // Warp past policy expiry (duration = 3600s)
        vm.warp(block.timestamp + 3601);

        // Mark expired
        policyManager.markExpired(PRODUCT_ID, policyId);

        // Verify state
        assertEq(policyManager.activePolicies(), 0, "No active policies after expiry");
        assertEq(bondVault.totalCommittedUSD(), 0, "No bonds should have been issued");

        PolicyManagerV2.PolicyRecord memory pr = policyManager.getPolicy(PRODUCT_ID, policyId);
        assertTrue(pr.expired, "Policy should be marked expired");
        assertFalse(pr.triggered, "Policy should not be triggered");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 3: ClaimBond redeemed at maturity
    // ═══════════════════════════════════════════════════════════

    function test_Flow_ClaimBond_AtMaturity() public {
        uint256 coverageAmount = 1000e6;

        // Buy and trigger policy => bonds issued
        (, uint256 epochId) = _buyAndTrigger(agent1, coverageAmount);

        // Verify bonds exist
        uint256 bondBalance = claimBond.balanceOf(agent1, epochId);
        assertEq(bondBalance, 800, "Should have 800 bond tokens");

        // Bonds should NOT be matured yet
        assertFalse(claimBond.isMatured(epochId), "Bonds should not be matured yet");

        // Warp to maturity (730 days + 1 day margin)
        vm.warp(block.timestamp + 731 days);
        assertTrue(claimBond.isMatured(epochId), "Bonds should be matured now");

        // Redeem all bonds
        uint256 luminaBefore = token.balanceOf(agent1);
        vm.prank(agent1);
        bondVault.redeemBond(epochId, 800);
        uint256 luminaAfter = token.balanceOf(agent1);

        // Verify LUMINA received: $800 / $0.036 per LUMINA
        uint256 oraclePrice = 0.036e18;
        uint256 expectedLumina = (800 * 1e36) / oraclePrice;
        assertEq(luminaAfter - luminaBefore, expectedLumina, "Should receive correct LUMINA for $800");

        // Bond tokens should be burned
        assertEq(claimBond.balanceOf(agent1, epochId), 0, "Bond tokens should be burned after redeem");

        // Commitments should decrease
        assertEq(bondVault.totalCommittedUSD(), 0, "Commitments should be 0 after full redemption");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 4: Partial redeem
    // ═══════════════════════════════════════════════════════════

    function test_Flow_PartialRedeem() public {
        // Coverage $1250 => payout = 1250 * 80% = $1000 => 1000 bond tokens
        uint256 coverageAmount = 1250e6;

        (, uint256 epochId) = _buyAndTrigger(agent1, coverageAmount);

        uint256 bondBalance = claimBond.balanceOf(agent1, epochId);
        assertEq(bondBalance, 1000, "Should have 1000 bond tokens ($1000)");

        // Warp to maturity
        vm.warp(block.timestamp + 731 days);
        assertTrue(claimBond.isMatured(epochId), "Bonds should be matured");

        // Redeem 500 of 1000
        uint256 luminaBefore = token.balanceOf(agent1);
        vm.prank(agent1);
        bondVault.redeemBond(epochId, 500);
        uint256 luminaAfter = token.balanceOf(agent1);

        // Verify partial LUMINA received
        uint256 oraclePrice = 0.036e18;
        uint256 expectedLumina = (500 * 1e36) / oraclePrice;
        assertEq(luminaAfter - luminaBefore, expectedLumina, "Should receive LUMINA for $500");

        // Verify remaining bonds
        assertEq(claimBond.balanceOf(agent1, epochId), 500, "Should have 500 bond tokens remaining");

        // Verify partial commitment reduction: 1000 * 1e18 - 500 * 1e18 = 500 * 1e18
        assertEq(bondVault.totalCommittedUSD(), 500 * 1e18, "Committed should be 500 * 1e18");

        // Redeem remaining 500
        vm.prank(agent1);
        bondVault.redeemBond(epochId, 500);

        assertEq(claimBond.balanceOf(agent1, epochId), 0, "All bonds should be redeemed");
        assertEq(bondVault.totalCommittedUSD(), 0, "Commitments should be 0 after full redemption");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 5: Multiple agents, independent policies
    // ═══════════════════════════════════════════════════════════

    function test_Flow_MultipleAgents_IndependentPolicies() public {
        // Agent1: $1000 coverage
        (, uint256 epochId1) = _buyAndTrigger(agent1, 1000e6);
        // Agent2: $2000 coverage
        (, uint256 epochId2) = _buyAndTrigger(agent2, 2000e6);
        // Agent3: $500 coverage
        (, uint256 epochId3) = _buyAndTrigger(agent3, 500e6);

        // All epoch IDs should be the same (issued at same timestamp)
        assertEq(epochId1, epochId2, "Epoch IDs should match");
        assertEq(epochId2, epochId3, "Epoch IDs should match");
        uint256 epochId = epochId1;

        // Verify each agent's bond balance independently
        // Agent1: 1000 * 80% = 800 bond tokens
        assertEq(claimBond.balanceOf(agent1, epochId), 800, "Agent1 should have 800 bonds");
        // Agent2: 2000 * 80% = 1600 bond tokens
        assertEq(claimBond.balanceOf(agent2, epochId), 1600, "Agent2 should have 1600 bonds");
        // Agent3: 500 * 80% = 400 bond tokens
        assertEq(claimBond.balanceOf(agent3, epochId), 400, "Agent3 should have 400 bonds");

        // Total committed = (800 + 1600 + 400) * 1e18 = 2800 * 1e18
        assertEq(bondVault.totalCommittedUSD(), 2800 * 1e18, "Total committed should be 2800 * 1e18");

        // Warp to maturity and redeem individually
        vm.warp(block.timestamp + 731 days);

        // Agent2 redeems first
        uint256 lumina2Before = token.balanceOf(agent2);
        vm.prank(agent2);
        bondVault.redeemBond(epochId, 1600);
        uint256 lumina2After = token.balanceOf(agent2);
        assertGt(lumina2After, lumina2Before, "Agent2 should receive LUMINA");
        assertEq(claimBond.balanceOf(agent2, epochId), 0, "Agent2 bonds should be 0");

        // Agent1 and Agent3 bonds should be unaffected
        assertEq(claimBond.balanceOf(agent1, epochId), 800, "Agent1 bonds unaffected");
        assertEq(claimBond.balanceOf(agent3, epochId), 400, "Agent3 bonds unaffected");

        // Committed should be reduced by agent2's share only
        assertEq(bondVault.totalCommittedUSD(), 1200 * 1e18, "Committed should be 1200 * 1e18 after agent2 redeem");

        // Agent1 redeems
        vm.prank(agent1);
        bondVault.redeemBond(epochId, 800);
        assertEq(bondVault.totalCommittedUSD(), 400 * 1e18, "Committed should be 400 * 1e18 after agent1 redeem");

        // Agent3 redeems
        vm.prank(agent3);
        bondVault.redeemBond(epochId, 400);
        assertEq(bondVault.totalCommittedUSD(), 0, "All commitments cleared");
    }
}
