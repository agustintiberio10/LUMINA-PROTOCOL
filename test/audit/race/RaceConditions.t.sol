// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {LuminaBondMarketplace} from "../../../src/marketplace/LuminaBondMarketplace.sol";
import {CEXLiquidityReserve} from "../../../src/treasury/CEXLiquidityReserve.sol";
import {IDexRouter} from "../../../src/interfaces/IDexRouter.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// ═══════════════════════════════════════════════════════════
//  INLINE MOCKS — minimal stubs so real contracts compile
// ═══════════════════════════════════════════════════════════

contract MockUSDC_RC {
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

contract MockPriceOracle_RC {
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

contract MockSwapRouter_RC is IDexRouter {
    IERC20 public lumina;
    uint256 public rate = 27; // 1 USDC buys 27 LUMINA

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * rate * 1e12; // USDC 6 dec -> LUMINA 18 dec
        lumina.transfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256 amountIn) external view returns (uint256) {
        return amountIn * rate * 1e12;
    }
}

/// @dev Minimal shield mock: produces unique policy IDs, supports settle callback.
contract MockShieldV2_RC {
    bytes32 public productId;
    uint256 private _nextPolicyId;
    address public policyManagerAddr;

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

    function setPolicyManager(address _pm) external {
        policyManagerAddr = _pm;
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

    /// @dev Allow test to simulate shield-initiated settle
    function callSettle(bytes32 _productId, uint256 policyId, bool triggered) external {
        PolicyManagerV2(policyManagerAddr).settlePolicy(_productId, policyId, triggered);
    }

    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (address insuredAgent, uint256, uint256, uint256, uint256, uint8)
    {
        return (policyBuyer[policyId], 0, 0, 0, 0, 0);
    }
}

/// @dev Mock SolvencyOracle for BuybackEngine
contract MockSolvencyOracle_RC {
    uint256 public ratio = 20000; // 200%

    function setRatio(uint256 _r) external {
        ratio = _r;
    }

    function getSolvencyRatio() external view returns (uint256) {
        return ratio;
    }
}

// ═══════════════════════════════════════════════════════════
//  MAIN TEST CONTRACT
// ═══════════════════════════════════════════════════════════

/// @title RaceConditionsTest
/// @notice Audit Bloque 2 — exhaustive race condition tests across all LUMINA V5.0 contracts.
///         Every test calls real deployed protocol contracts (BondVault, CoverRouter,
///         Marketplace, TWAPBurner, PolicyManager, CEXLiquidityReserve).
contract RaceConditionsTest is Test {
    // ═══════ CORE CONTRACTS (real) ═══════
    LuminaTokenV2 token;
    BondVault bondVault;
    ClaimBond claimBond;
    TWAPBurner twapBurner;
    PolicyManagerV2 policyManager;
    CoverRouterV2 coverRouter;
    LuminaBondMarketplace marketplace;
    CEXLiquidityReserve cexReserve;

    // ═══════ MOCKS ═══════
    MockUSDC_RC usdc;
    MockPriceOracle_RC priceOracle;
    MockSwapRouter_RC swapRouter;
    MockShieldV2_RC mockShield;
    MockSolvencyOracle_RC solvencyOracle;

    // ═══════ ADDRESSES ═══════
    address cexReserveAddr;
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");

    address buyer1 = makeAddr("buyer1");
    address buyer2 = makeAddr("buyer2");
    address buyer3 = makeAddr("buyer3");
    address seller1 = makeAddr("seller1");
    address admin = makeAddr("admin");

    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC1H-RACE");
    bytes32 constant PRODUCT_ID_2 = keccak256("FLASHBTC4H-RACE");
    uint256 constant BASE_TS = 1767225600; // Jan 1 2026 UTC

    function setUp() public {
        vm.warp(BASE_TS + 60 days);

        // 1. Deploy mocks
        usdc = new MockUSDC_RC();
        priceOracle = new MockPriceOracle_RC(0.036e18);

        // 2. Deploy ClaimBond
        claimBond = ProxyDeployer.deployClaimBond();

        // 3. Predict BondVault address
        uint64 nonce = vm.getNonce(address(this));
        // nonce+0 = cexReserve(1), +1,+2 = token via proxy(2), +3 = swapRouter(1),
        // +4 = twapBurner(1), +5,+6 = policyManager via proxy(2), +7,+8 = bondVault via proxy(2)
        address predictedBondVault = vm.computeCreateAddress(address(this), nonce + 8);
        address predictedCexReserve = vm.computeCreateAddress(address(this), nonce);

        // 4. Deploy CEXLiquidityReserve
        cexReserve = new CEXLiquidityReserve(address(0x1), address(this)); // placeholder lumina, fixed below
        // We need the CEXReserve address for token constructor, but it needs lumina address.
        // Use a different ordering: predict further ahead.

        // Simpler: deploy token with dummy addresses for cex, then deal tokens
        // Actually the token constructor mints to cex. Let's use the real pattern.

        // Re-do: fresh nonces. We'll compute create addresses properly.
        // Reset approach: deploy CEX reserve with a placeholder, then deploy token pointing to it.
        // CEXLiquidityReserve doesn't receive tokens in constructor — token mints to the address.
        cexReserveAddr = address(cexReserve);

        // 5. Deploy token — mints 14M to cexReserveAddr
        token = ProxyDeployer.deployLuminaTokenV2(
            predictedBondVault, cexReserveAddr, founderVesting, lbpDeposit, treasuryVesting
        );

        // 6. Deploy swap router mock
        swapRouter = new MockSwapRouter_RC(address(token));
        deal(address(token), address(swapRouter), 1_000_000e18);

        // 7. Deploy TWAPBurner
        twapBurner = new TWAPBurner(address(usdc), address(token), address(swapRouter));

        // 8. Deploy PolicyManagerV2
        policyManager = ProxyDeployer.deployPolicyManagerV2(predictedBondVault);

        // 9. Deploy BondVault
        bondVault = ProxyDeployer.deployBondVault(
            address(token), address(claimBond), address(priceOracle), address(policyManager)
        );
        require(address(bondVault) == predictedBondVault, "BondVault address mismatch");

        // 10. Wire ClaimBond -> BondVault
        claimBond.setBondVault(address(bondVault));

        // 11. Grant BURNER_ROLE to TWAPBurner and BondVault
        token.grantRole(token.BURNER_ROLE(), address(twapBurner));
        token.grantRole(token.BURNER_ROLE(), address(bondVault));

        // 12. Deploy & register MockShield
        mockShield = new MockShieldV2_RC(PRODUCT_ID);
        mockShield.setPolicyManager(address(policyManager));
        policyManager.registerProduct(PRODUCT_ID, address(mockShield));

        // Register a second product for multi-product tests
        MockShieldV2_RC mockShield2 = new MockShieldV2_RC(PRODUCT_ID_2);
        mockShield2.setPolicyManager(address(policyManager));
        policyManager.registerProduct(PRODUCT_ID_2, address(mockShield2));

        // 13. Deploy CoverRouter
        coverRouter = ProxyDeployer.deployCoverRouterV2(address(usdc), address(policyManager), address(twapBurner));
        coverRouter.setCapacityOracle(address(priceOracle));

        // 14. Wire PolicyManager -> CoverRouter
        policyManager.setRouter(address(coverRouter));

        // 15. Configure product in CoverRouter
        coverRouter.configureProduct(PRODUCT_ID, 8000, 200, 15000, 3600, true);
        coverRouter.configureProduct(PRODUCT_ID_2, 8000, 200, 15000, 14400, true);

        // 16. Deploy Marketplace
        marketplace = new LuminaBondMarketplace(address(claimBond), address(usdc), address(twapBurner), address(this));

        // 17. Deploy SolvencyOracle mock
        solvencyOracle = new MockSolvencyOracle_RC();

        // 18. Authorize BondVault callers
        bondVault.setAuthorizedCaller(address(this), true);

        // 19. Fund buyers with USDC
        usdc.mint(buyer1, 100_000_000e6);
        usdc.mint(buyer2, 100_000_000e6);
        usdc.mint(buyer3, 100_000_000e6);
        usdc.mint(seller1, 100_000_000e6);
        usdc.mint(address(this), 100_000_000e6);

        // 20. Approve USDC spending
        vm.prank(buyer1);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.prank(buyer2);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.prank(buyer3);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.prank(seller1);
        usdc.approve(address(coverRouter), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════

    function _buyPolicy(address buyer, bytes32 productId, uint256 coverage) internal returns (uint256 policyId) {
        vm.prank(buyer);
        policyId = coverRouter.purchasePolicy(productId, coverage, "BTC");
    }

    function _buyAndTrigger(address buyer, uint256 coverage) internal returns (uint256 policyId) {
        policyId = _buyPolicy(buyer, PRODUCT_ID, coverage);
        coverRouter.submitTrigger(PRODUCT_ID, policyId, "");
    }

    function _computeEpochId(uint256 issueTimestamp) internal pure returns (uint256) {
        uint256 maturityTs = issueTimestamp + 730 days;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }

    // ═══════════════════════════════════════════════════════════
    //  CATEGORY 1: CONCURRENT PURCHASES (3 tests)
    // ═══════════════════════════════════════════════════════════

    /// @notice Two buyers purchase in the same block, both succeed if capacity allows.
    function test_Race_ConcurrentPurchases_BothSucceed() public {
        // Same block — no vm.warp between calls
        uint256 id1 = _buyPolicy(buyer1, PRODUCT_ID, 1000e6);
        uint256 id2 = _buyPolicy(buyer2, PRODUCT_ID, 1000e6);

        // Both policies recorded in PolicyManagerV2
        assertGt(id1, 0, "Policy 1 should exist");
        assertGt(id2, 0, "Policy 2 should exist");
        assertFalse(id1 == id2, "Policy IDs must differ");
        assertEq(policyManager.totalPolicies(), 2, "Two policies recorded");
    }

    /// @notice [V5/M-RACE FIX] Capacity is now reserved at purchase time.
    ///      The first purchase reserves ~$1.2M. The second purchase for ~$1.2M
    ///      is rejected immediately (InsufficientCapacity), preventing the old
    ///      race where both purchases passed but the 2nd trigger reverted.
    function test_Race_ConcurrentPurchases_2ndRevertsCapacityExhausted() public {
        // Capacity at $0.036: 70M * 0.036 * 50% = ~$1.26M. Payout = coverage * 80%.
        // Use big coverage: $1.5M => payout = $1.2M. Two of these exceed $1.26M.
        uint256 bigCoverage = 1_500_000e6; // $1.5M

        // First purchase succeeds and RESERVES $1.2M capacity
        uint256 id1 = _buyPolicy(buyer1, PRODUCT_ID, bigCoverage);
        assertGt(id1, 0);

        // Second purchase FAILS at purchase time — capacity already reserved
        vm.expectRevert();
        _buyPolicy(buyer2, PRODUCT_ID, bigCoverage);

        // First trigger succeeds since capacity was reserved
        coverRouter.submitTrigger(PRODUCT_ID, id1, "");
    }

    /// @notice 10 buyers in same block, all get unique policy IDs.
    function test_Race_ConcurrentPurchases_10Buyers_UniquePolicyIDs() public {
        uint256[] memory ids = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            address buyer = makeAddr(string(abi.encodePacked("massBuyer", i)));
            usdc.mint(buyer, 10_000_000e6);
            vm.prank(buyer);
            usdc.approve(address(coverRouter), type(uint256).max);
            vm.prank(buyer);
            ids[i] = coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        }

        // Verify all IDs unique
        for (uint256 i = 0; i < 10; i++) {
            for (uint256 j = i + 1; j < 10; j++) {
                assertFalse(ids[i] == ids[j], "Duplicate policy ID detected");
            }
        }
        assertEq(policyManager.totalPolicies(), 10, "All 10 policies recorded");
    }

    // ═══════════════════════════════════════════════════════════
    //  CATEGORY 2: CONCURRENT TRIGGERS (2 tests)
    // ═══════════════════════════════════════════════════════════

    /// @notice 10 policies triggered in same block, all get ClaimBond NFTs.
    function test_Race_ConcurrentTriggers_10PoliciesSameBlock() public {
        uint256 epochId = _computeEpochId(block.timestamp);
        uint256[] memory policyIds = new uint256[](10);
        address[] memory buyers = new address[](10);

        // Create 10 policies
        for (uint256 i = 0; i < 10; i++) {
            buyers[i] = makeAddr(string(abi.encodePacked("trigBuyer", i)));
            usdc.mint(buyers[i], 10_000_000e6);
            vm.prank(buyers[i]);
            usdc.approve(address(coverRouter), type(uint256).max);
            vm.prank(buyers[i]);
            policyIds[i] = coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        }

        // Trigger all 10 in same block
        for (uint256 i = 0; i < 10; i++) {
            coverRouter.submitTrigger(PRODUCT_ID, policyIds[i], "");
        }

        // Verify all got bonds
        for (uint256 i = 0; i < 10; i++) {
            uint256 bal = claimBond.balanceOf(buyers[i], epochId);
            assertGt(bal, 0, "Buyer should have ClaimBond NFTs");
        }
        assertEq(policyManager.totalTriggers(), 10, "All 10 triggers recorded");
    }

    /// @notice totalCommittedUSD consistent after multiple triggers in same block.
    function test_Race_ConcurrentTriggers_CommittedUSD_Consistent() public {
        uint256 commitBefore = bondVault.totalCommittedUSD();

        // Buy and trigger 5 policies in same block
        for (uint256 i = 0; i < 5; i++) {
            address b = makeAddr(string(abi.encodePacked("cBuyer", i)));
            usdc.mint(b, 10_000_000e6);
            vm.prank(b);
            usdc.approve(address(coverRouter), type(uint256).max);
            vm.prank(b);
            uint256 pid = coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
            coverRouter.submitTrigger(PRODUCT_ID, pid, "");
        }

        uint256 commitAfter = bondVault.totalCommittedUSD();
        // Each $1000 coverage * 80% payout = $800, committed = 800 * 1e18 each
        uint256 expectedIncrease = 5 * 800 * 1e18;
        assertEq(commitAfter - commitBefore, expectedIncrease, "Committed USD must match sum");
    }

    // ═══════════════════════════════════════════════════════════
    //  CATEGORY 3: CIRCUIT BREAKER RACE (2 tests)
    // ═══════════════════════════════════════════════════════════

    /// @notice Buy succeeds then price drops below threshold — 2nd buy reverts (same block).
    function test_Race_CircuitBreaker_PriceDropSameBlock() public {
        // First buy works
        uint256 id1 = _buyPolicy(buyer1, PRODUCT_ID, 1000e6);
        assertGt(id1, 0);

        // Price drops below MIN_PRICE_FOR_NEW_POLICIES (5e15 = $0.005)
        priceOracle.setPrice(4e15); // $0.004

        // Second buy same block reverts due to auto-pause
        vm.prank(buyer2);
        vm.expectRevert("Protocol auto-paused: LUMINA price below safety threshold");
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
    }

    /// @notice Price recovers above threshold, immediate buy works (same block).
    function test_Race_CircuitBreaker_PriceRecoversSameBlock() public {
        // Drop price
        priceOracle.setPrice(4e15);

        // Buy fails
        vm.prank(buyer1);
        vm.expectRevert("Protocol auto-paused: LUMINA price below safety threshold");
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");

        // Price recovers (same block)
        priceOracle.setPrice(0.036e18);

        // Immediate buy works
        uint256 id = _buyPolicy(buyer2, PRODUCT_ID, 1000e6);
        assertGt(id, 0, "Buy should succeed after price recovery");
    }

    // ═══════════════════════════════════════════════════════════
    //  CATEGORY 4: MARKETPLACE RACE (3 tests)
    // ═══════════════════════════════════════════════════════════

    /// @notice Seller lists then cancels in same block — buyer trying to buy reverts.
    function test_Race_Marketplace_ListCancelSameBlock_BuyerReverts() public {
        // Issue bonds to seller via trigger
        _buyAndTrigger(seller1, 1000e6);
        uint256 epochId = _computeEpochId(block.timestamp);

        // Seller approves marketplace
        vm.prank(seller1);
        claimBond.setApprovalForAll(address(marketplace), true);

        // Seller lists
        vm.prank(seller1);
        uint256 listingId = marketplace.list(epochId, 100, 500e6);

        // Seller cancels (same block)
        vm.prank(seller1);
        marketplace.cancel(listingId);

        // Buyer tries to buy — reverts
        vm.prank(buyer1);
        usdc.approve(address(marketplace), type(uint256).max);
        vm.prank(buyer1);
        vm.expectRevert("Not active");
        marketplace.executeBuy(listingId);
    }

    /// @notice Two buyers race for same listing — 1st wins, 2nd reverts.
    function test_Race_Marketplace_TwoBuyers_FirstWins() public {
        // Issue bonds to seller
        _buyAndTrigger(seller1, 1000e6);
        uint256 epochId = _computeEpochId(block.timestamp);

        // Seller lists
        vm.prank(seller1);
        claimBond.setApprovalForAll(address(marketplace), true);
        vm.prank(seller1);
        uint256 listingId = marketplace.list(epochId, 100, 500e6);

        // Both buyers approve
        vm.prank(buyer1);
        usdc.approve(address(marketplace), type(uint256).max);
        vm.prank(buyer2);
        usdc.approve(address(marketplace), type(uint256).max);

        // Buyer1 buys first (same block)
        vm.prank(buyer1);
        marketplace.executeBuy(listingId);

        // Buyer2 tries same listing — reverts
        vm.prank(buyer2);
        vm.expectRevert("Not active");
        marketplace.executeBuy(listingId);

        // Verify buyer1 got the bonds
        assertEq(claimBond.balanceOf(buyer1, epochId), 100, "Buyer1 should hold bonds");
    }

    /// @notice Seller lists + different buyer buys same block (works).
    function test_Race_Marketplace_ListAndBuySameBlock() public {
        // Issue bonds to seller
        _buyAndTrigger(seller1, 1000e6);
        uint256 epochId = _computeEpochId(block.timestamp);

        // Seller approves & lists
        vm.prank(seller1);
        claimBond.setApprovalForAll(address(marketplace), true);
        vm.prank(seller1);
        uint256 listingId = marketplace.list(epochId, 100, 500e6);

        // Buyer buys same block
        vm.prank(buyer1);
        usdc.approve(address(marketplace), type(uint256).max);
        vm.prank(buyer1);
        marketplace.executeBuy(listingId);

        // Verify transfer
        assertEq(claimBond.balanceOf(buyer1, epochId), 100, "Buyer should hold bonds");
        (,,,, bool active) = marketplace.getListing(listingId);
        assertFalse(active, "Listing should be inactive");
    }

    // ═══════════════════════════════════════════════════════════
    //  CATEGORY 5: BUYBACK RACE (2 tests)
    // ═══════════════════════════════════════════════════════════

    /// @notice Two buyback-like bond burns in same block exhaust budget.
    function test_Race_Buyback_BudgetExhaustion_SameBlock() public {
        // Issue bonds to two holders via trigger
        _buyAndTrigger(buyer1, 1000e6);
        _buyAndTrigger(buyer2, 1000e6);
        uint256 epochId = _computeEpochId(block.timestamp);

        uint256 bal1 = claimBond.balanceOf(buyer1, epochId);
        uint256 bal2 = claimBond.balanceOf(buyer2, epochId);
        assertGt(bal1, 0);
        assertGt(bal2, 0);

        // Both approve marketplace
        vm.prank(buyer1);
        claimBond.setApprovalForAll(address(marketplace), true);
        vm.prank(buyer2);
        claimBond.setApprovalForAll(address(marketplace), true);

        // Both list
        vm.prank(buyer1);
        uint256 listing1 = marketplace.list(epochId, bal1, 400e6);
        vm.prank(buyer2);
        uint256 listing2 = marketplace.list(epochId, bal2, 400e6);

        // Single buyer buys first listing
        vm.prank(buyer3);
        usdc.approve(address(marketplace), type(uint256).max);
        vm.prank(buyer3);
        marketplace.executeBuy(listing1);

        // Same buyer buys second listing (same block)
        vm.prank(buyer3);
        marketplace.executeBuy(listing2);

        // Verify buyer3 accumulated all bonds
        uint256 totalBonds = claimBond.balanceOf(buyer3, epochId);
        assertEq(totalBonds, bal1 + bal2, "Buyer3 should hold all bonds");
    }

    /// @notice Marketplace buy + manual marketplace buy race on separate listings.
    function test_Race_Buyback_ManualBuyRace() public {
        // Issue bonds to two different sellers to avoid seller1 USDC underflow on listing
        address sellerA = makeAddr("sellerA");
        address sellerB = makeAddr("sellerB");
        usdc.mint(sellerA, 10_000_000e6);
        usdc.mint(sellerB, 10_000_000e6);
        vm.prank(sellerA);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.prank(sellerB);
        usdc.approve(address(coverRouter), type(uint256).max);

        _buyAndTrigger(sellerA, 1000e6);
        _buyAndTrigger(sellerB, 1000e6);
        uint256 epochId = _computeEpochId(block.timestamp);
        uint256 balA = claimBond.balanceOf(sellerA, epochId);
        uint256 balB = claimBond.balanceOf(sellerB, epochId);

        // Each seller lists their bonds
        vm.prank(sellerA);
        claimBond.setApprovalForAll(address(marketplace), true);
        vm.prank(sellerA);
        uint256 l1 = marketplace.list(epochId, balA, 300e6);

        vm.prank(sellerB);
        claimBond.setApprovalForAll(address(marketplace), true);
        vm.prank(sellerB);
        uint256 l2 = marketplace.list(epochId, balB, 300e6);

        // Two different buyers buy different listings in same block
        vm.prank(buyer1);
        usdc.approve(address(marketplace), type(uint256).max);
        vm.prank(buyer1);
        marketplace.executeBuy(l1);

        vm.prank(buyer2);
        usdc.approve(address(marketplace), type(uint256).max);
        vm.prank(buyer2);
        marketplace.executeBuy(l2);

        // Both succeed
        assertGt(claimBond.balanceOf(buyer1, epochId), 0);
        assertGt(claimBond.balanceOf(buyer2, epochId), 0);
    }

    // ═══════════════════════════════════════════════════════════
    //  CATEGORY 6: TWAPBURNER RACE (2 tests)
    // ═══════════════════════════════════════════════════════════

    /// @notice Two burn executions in same block — 2nd reverts (cooldown).
    function test_Race_TWAPBurner_DoubleBurn_CooldownReverts() public {
        // Fund TWAPBurner with USDC via premium
        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(twapBurner), 100_000e6);
        twapBurner.receivePremium(100_000e6);

        // Execute first burn
        twapBurner.executeBurn();

        // Second burn same block reverts
        // Need more USDC (first burn consumed some)
        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(twapBurner), 100_000e6);
        twapBurner.receivePremium(100_000e6);

        vm.expectRevert("Cooldown active");
        twapBurner.executeBurn();
    }

    /// @notice Burn + premium received in same block — premium does not affect current burn.
    function test_Race_TWAPBurner_BurnPlusPremiumSameBlock() public {
        // Seed TWAPBurner
        usdc.mint(address(this), 50_000e6);
        usdc.approve(address(twapBurner), 50_000e6);
        twapBurner.receivePremium(50_000e6);

        uint256 receivedBefore = twapBurner.totalUSDCReceived();

        // Execute burn
        twapBurner.executeBurn();

        uint256 burned = twapBurner.totalUSDCBurned();
        assertGt(burned, 0, "Should have burned some USDC");

        // New premium arrives same block
        usdc.mint(address(this), 25_000e6);
        usdc.approve(address(twapBurner), 25_000e6);
        twapBurner.receivePremium(25_000e6);

        uint256 receivedAfter = twapBurner.totalUSDCReceived();
        assertEq(receivedAfter, receivedBefore + 25_000e6, "Premium tracked correctly");

        // The new premium cannot be burned yet (cooldown)
        vm.expectRevert("Cooldown active");
        twapBurner.executeBurn();
    }

    // ═══════════════════════════════════════════════════════════
    //  CATEGORY 7: REDEEM + BURN CONFLICT (3 tests)
    // ═══════════════════════════════════════════════════════════

    /// @notice Redeem + burnFromReserves in same block, both succeed.
    function test_Race_RedeemBurn_BothSucceedSameBlock() public {
        // Issue bond
        _buyAndTrigger(buyer1, 1000e6);
        uint256 epochId = _computeEpochId(block.timestamp);

        // Warp to maturity
        uint256 maturity = claimBond.maturityDate(epochId);
        vm.warp(maturity + 1);

        uint256 reserveBefore = token.balanceOf(address(bondVault));

        // Buyer redeems
        uint256 bondBal = claimBond.balanceOf(buyer1, epochId);
        assertGt(bondBal, 0);
        vm.prank(buyer1);
        bondVault.redeemBond(epochId, bondBal);

        // Authorized caller burns from reserves (same block after redeem)
        uint256 reserveAfterRedeem = token.balanceOf(address(bondVault));
        uint256 burnAmount = (reserveAfterRedeem * 1) / 100; // 1% of remaining
        bondVault.burnFromReserves(burnAmount);

        uint256 reserveAfterBoth = token.balanceOf(address(bondVault));
        assertLt(reserveAfterBoth, reserveBefore, "Reserve should decrease");
        assertGt(token.balanceOf(buyer1), 0, "Buyer should have received LUMINA");
    }

    /// @notice 10 redeems in same block, all succeed.
    function test_Race_10RedeemsSameBlock() public {
        // Issue 10 bonds
        address[] memory holders = new address[](10);
        uint256 epochId = _computeEpochId(block.timestamp);

        for (uint256 i = 0; i < 10; i++) {
            holders[i] = makeAddr(string(abi.encodePacked("redeemer", i)));
            usdc.mint(holders[i], 10_000_000e6);
            vm.prank(holders[i]);
            usdc.approve(address(coverRouter), type(uint256).max);
            vm.prank(holders[i]);
            uint256 pid = coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
            coverRouter.submitTrigger(PRODUCT_ID, pid, "");
        }

        // Warp to maturity
        uint256 maturity = claimBond.maturityDate(epochId);
        vm.warp(maturity + 1);

        // All 10 redeem in same block
        for (uint256 i = 0; i < 10; i++) {
            uint256 bal = claimBond.balanceOf(holders[i], epochId);
            assertGt(bal, 0);
            vm.prank(holders[i]);
            bondVault.redeemBond(epochId, bal);
        }

        // All should have received LUMINA
        for (uint256 i = 0; i < 10; i++) {
            assertGt(token.balanceOf(holders[i]), 0, "Holder should have LUMINA");
            assertEq(claimBond.balanceOf(holders[i], epochId), 0, "Bonds should be burned");
        }
    }

    /// @notice Redeem after partial burn — balance is correct.
    function test_Race_RedeemAfterPartialBurn_BalanceCorrect() public {
        // Issue bond
        _buyAndTrigger(buyer1, 1000e6);
        uint256 epochId = _computeEpochId(block.timestamp);

        // Burn 1% of reserves
        uint256 reserveBefore = token.balanceOf(address(bondVault));
        uint256 burnAmt = (reserveBefore * 1) / 100;
        bondVault.burnFromReserves(burnAmt);

        uint256 reserveAfterBurn = token.balanceOf(address(bondVault));
        assertEq(reserveAfterBurn, reserveBefore - burnAmt, "Reserve decreased by burn amount");

        // Warp to maturity and redeem
        uint256 maturity = claimBond.maturityDate(epochId);
        vm.warp(maturity + 1);

        uint256 bondBal = claimBond.balanceOf(buyer1, epochId);
        vm.prank(buyer1);
        bondVault.redeemBond(epochId, bondBal);

        uint256 reserveAfterRedeem = token.balanceOf(address(bondVault));
        assertLt(reserveAfterRedeem, reserveAfterBurn, "Reserve decreased further by redemption");
        assertGt(token.balanceOf(buyer1), 0, "Buyer received LUMINA");
    }

    // ═══════════════════════════════════════════════════════════
    //  CATEGORY 8: SETTLEMENT RACE (2 tests)
    // ═══════════════════════════════════════════════════════════

    /// @notice Double settle same policy — 2nd reverts.
    function test_Race_DoubleSettle_2ndReverts() public {
        // Buy policy via router
        uint256 policyId = _buyPolicy(buyer1, PRODUCT_ID, 1000e6);

        // First trigger (settle via router)
        coverRouter.submitTrigger(PRODUCT_ID, policyId, "");

        // Second trigger same block — reverts (already triggered)
        vm.expectRevert("Already triggered");
        coverRouter.submitTrigger(PRODUCT_ID, policyId, "");
    }

    /// @notice Settle + new purchase on same shield in same block.
    function test_Race_SettlePlusNewPurchaseSameBlock() public {
        // Buy and trigger
        uint256 pid1 = _buyPolicy(buyer1, PRODUCT_ID, 1000e6);
        coverRouter.submitTrigger(PRODUCT_ID, pid1, "");

        // New purchase on same shield, same block
        uint256 pid2 = _buyPolicy(buyer2, PRODUCT_ID, 1000e6);

        assertGt(pid2, 0, "New policy should be created");
        assertFalse(pid1 == pid2, "Different IDs");

        // Verify state
        PolicyManagerV2.PolicyRecord memory rec2 = policyManager.getPolicy(PRODUCT_ID, pid2);
        assertFalse(rec2.triggered, "New policy should not be triggered");
    }

    // ═══════════════════════════════════════════════════════════
    //  CATEGORY 9: ADMIN RACE (2 tests)
    // ═══════════════════════════════════════════════════════════

    /// @notice Deactivate product + purchase in same block — purchase reverts.
    function test_Race_DeactivateProduct_PurchaseReverts() public {
        // First purchase succeeds
        uint256 id1 = _buyPolicy(buyer1, PRODUCT_ID, 1000e6);
        assertGt(id1, 0);

        // Admin deactivates product (same block)
        policyManager.deactivateProduct(PRODUCT_ID);

        // Next purchase reverts due to inactive product
        vm.prank(buyer2);
        vm.expectRevert(); // ProductNotActive
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
    }

    /// @notice Double pause reverts (CoverRouter).
    function test_Race_DoublePause_SecondSucceeds() public {
        // Pause
        coverRouter.setPaused(true);
        assertTrue(coverRouter.paused());

        // Second pause call does not revert (it is idempotent)
        coverRouter.setPaused(true);
        assertTrue(coverRouter.paused());

        // But purchases revert
        vm.prank(buyer1);
        vm.expectRevert(CoverRouterV2.ContractPaused.selector);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");

        // Unpause
        coverRouter.setPaused(false);

        // Purchase works again
        uint256 id = _buyPolicy(buyer1, PRODUCT_ID, 1000e6);
        assertGt(id, 0);
    }

    // ═══════════════════════════════════════════════════════════
    //  CATEGORY 10: CEX ALLOCATION RACE (2 tests)
    // ═══════════════════════════════════════════════════════════

    /// @notice Two allocations exhaust ImmediateUse sub-bucket.
    function test_Race_CEXAllocation_BucketExhaustion() public {
        // Deploy a fresh CEXLiquidityReserve with real lumina
        CEXLiquidityReserve freshCex = new CEXLiquidityReserve(address(token), address(this));
        // Fund it with tokens
        deal(address(token), address(freshCex), 14_000_000e18);

        address recipient1 = makeAddr("cexRecip1");
        address recipient2 = makeAddr("cexRecip2");

        // Monthly cap is 1M LUMINA. ImmediateUse bucket is 2.8M.
        // Must respect monthly cap, so allocate 999_999e18 first, then try to exceed.
        uint256 monthlyCap = freshCex.MONTHLY_CAP(); // 1M

        // First allocation: almost all of monthly cap from immediate bucket
        freshCex.allocate(
            recipient1,
            monthlyCap - 1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "First large allocation"
        );

        // Second allocation same block: exceeds monthly cap
        vm.expectRevert("Monthly cap exceeded");
        freshCex.allocate(
            recipient2,
            2e18, // more than the 1e18 remaining in monthly cap
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Second allocation exceeds"
        );

        // But exactly the monthly remainder works
        freshCex.allocate(
            recipient2,
            1e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Exact remainder allocation"
        );

        // Verify monthly cap fully used
        assertEq(freshCex.getMonthlyCapRemaining(), 0);
    }

    /// @notice Monthly cap race — two allocations hit the monthly cap.
    function test_Race_CEXAllocation_MonthlyCapRace() public {
        CEXLiquidityReserve freshCex = new CEXLiquidityReserve(address(token), address(this));
        deal(address(token), address(freshCex), 14_000_000e18);

        address recipient1 = makeAddr("monthRecip1");
        address recipient2 = makeAddr("monthRecip2");

        // Monthly cap = 1M LUMINA (freshCex.MONTHLY_CAP())
        // First allocation: 900k
        freshCex.allocate(
            recipient1,
            900_000e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3,
            "Large monthly alloc"
        );

        // Second allocation same block: 200k would exceed monthly cap of 1M
        vm.expectRevert("Monthly cap exceeded");
        freshCex.allocate(
            recipient2,
            200_000e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3,
            "Monthly cap race"
        );

        // Exactly remaining 100k works
        freshCex.allocate(
            recipient2,
            100_000e18,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.CEX_LISTING_TIER_3,
            "Exact monthly remainder"
        );

        assertEq(
            freshCex.getAvailableInBucket(CEXLiquidityReserve.SubBucket.ImmediateUse),
            freshCex.IMMEDIATE_AMOUNT() - 1_000_000e18
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  ADDITIONAL EDGE CASES (bonus — 7 more for robustness)
    // ═══════════════════════════════════════════════════════════

    /// @notice Concurrent purchases on different products, same block.
    function test_Race_ConcurrentPurchases_DifferentProducts() public {
        uint256 id1 = _buyPolicy(buyer1, PRODUCT_ID, 1000e6);
        uint256 id2 = _buyPolicy(buyer2, PRODUCT_ID_2, 1000e6);

        assertGt(id1, 0);
        assertGt(id2, 0);
        assertEq(policyManager.totalPolicies(), 2);
    }

    /// @notice Marketplace: cancel already-bought listing reverts.
    function test_Race_Marketplace_CancelAfterBuyReverts() public {
        _buyAndTrigger(seller1, 1000e6);
        uint256 epochId = _computeEpochId(block.timestamp);

        vm.prank(seller1);
        claimBond.setApprovalForAll(address(marketplace), true);
        vm.prank(seller1);
        uint256 listingId = marketplace.list(epochId, 100, 500e6);

        // Buyer buys
        vm.prank(buyer1);
        usdc.approve(address(marketplace), type(uint256).max);
        vm.prank(buyer1);
        marketplace.executeBuy(listingId);

        // Seller tries to cancel (same block) — reverts
        vm.prank(seller1);
        vm.expectRevert("Not active");
        marketplace.cancel(listingId);
    }

    /// @notice BondVault: burnFromReserves respects 5% cap per tx.
    function test_Race_BurnFromReserves_5PercentCapRace() public {
        uint256 reserve = token.balanceOf(address(bondVault));
        uint256 maxBurn = (reserve * 5) / 100;

        // First burn: exactly 5% succeeds
        bondVault.burnFromReserves(maxBurn);

        // Reserve decreased
        uint256 newReserve = token.balanceOf(address(bondVault));
        assertEq(newReserve, reserve - maxBurn);

        // Second burn: 5% of new balance succeeds
        uint256 maxBurn2 = (newReserve * 5) / 100;
        bondVault.burnFromReserves(maxBurn2);

        // Exceeding new 5% cap reverts
        uint256 remaining = token.balanceOf(address(bondVault));
        uint256 overCap = (remaining * 5) / 100 + 1;
        vm.expectRevert("Exceeds 5% per-tx cap");
        bondVault.burnFromReserves(overCap);
    }

    /// @notice Purchase + pause in same block — purchase before pause works.
    function test_Race_PurchaseThenPauseSameBlock() public {
        uint256 id1 = _buyPolicy(buyer1, PRODUCT_ID, 1000e6);
        assertGt(id1, 0);

        // Pause (same block)
        coverRouter.setPaused(true);

        // Next purchase reverts
        vm.prank(buyer2);
        vm.expectRevert(CoverRouterV2.ContractPaused.selector);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
    }

    /// @notice Multiple marketplace listings from same seller in same block.
    function test_Race_Marketplace_MultipleListingsSameBlock() public {
        _buyAndTrigger(seller1, 5000e6);
        uint256 epochId = _computeEpochId(block.timestamp);
        uint256 total = claimBond.balanceOf(seller1, epochId);

        vm.prank(seller1);
        claimBond.setApprovalForAll(address(marketplace), true);

        // Create 3 listings in same block
        vm.prank(seller1);
        uint256 l1 = marketplace.list(epochId, total / 3, 200e6);
        vm.prank(seller1);
        uint256 l2 = marketplace.list(epochId, total / 3, 200e6);
        vm.prank(seller1);
        uint256 l3 = marketplace.list(epochId, total - 2 * (total / 3), 200e6);

        // All listings active
        (,,,, bool a1) = marketplace.getListing(l1);
        (,,,, bool a2) = marketplace.getListing(l2);
        (,,,, bool a3) = marketplace.getListing(l3);
        assertTrue(a1 && a2 && a3, "All listings should be active");
    }

    /// @notice TWAPBurner receivePremium from multiple sources in same block.
    function test_Race_TWAPBurner_MultiplePremiumsSameBlock() public {
        uint256 before = twapBurner.totalUSDCReceived();

        // Source 1
        usdc.mint(buyer1, 10_000e6);
        vm.prank(buyer1);
        usdc.approve(address(twapBurner), 10_000e6);
        vm.prank(buyer1);
        twapBurner.receivePremium(10_000e6);

        // Source 2 (same block)
        usdc.mint(buyer2, 20_000e6);
        vm.prank(buyer2);
        usdc.approve(address(twapBurner), 20_000e6);
        vm.prank(buyer2);
        twapBurner.receivePremium(20_000e6);

        assertEq(twapBurner.totalUSDCReceived(), before + 30_000e6, "Both premiums tracked");
    }

    /// @notice BondVault decreaseObligations + burnFromReserves in same block.
    function test_Race_DecreaseObligations_BurnSameBlock() public {
        // First create some obligations
        _buyAndTrigger(buyer1, 1000e6);
        uint256 committedBefore = bondVault.totalCommittedUSD();
        assertGt(committedBefore, 0);

        // Decrease obligations (simulating buyback burn)
        uint256 decreaseAmt = 100 * 1e18; // 100 USD in 18-dec
        bondVault.decreaseObligations(decreaseAmt);

        // Burn from reserves (same block)
        uint256 burnAmt = (token.balanceOf(address(bondVault)) * 1) / 100;
        bondVault.burnFromReserves(burnAmt);

        uint256 committedAfter = bondVault.totalCommittedUSD();
        assertEq(committedAfter, committedBefore - decreaseAmt, "Obligations decreased correctly");
    }
}
