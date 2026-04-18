// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {TWAPBurner, ISwapRouter} from "../../../src/core/TWAPBurner.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";
import {CapacityOracle} from "../../../src/oracles/CapacityOracle.sol";

// ═══════ INLINE MOCKS (external dependencies only) ═══════

contract MockUSDC {
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

contract MockSwapRouter {
    IERC20 public lumina;
    uint256 public rate = 27; // 1 USDC = 27 LUMINA

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn * rate * 1e12;
        lumina.transfer(params.recipient, amountOut);
    }
}

/// @dev Mock shield conforming to PolicyManagerV2's IShieldV2 interface
contract MockShieldV2 {
    bytes32 public productId;
    uint256 private _nextPolicyId;

    struct PolicyData {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumPaid;
        uint256 maxPayout;
        uint256 expiresAt;
        uint8 status; // 0=active, 1=triggered, 2=expired
    }

    mapping(uint256 => PolicyData) public policyData;

    constructor(bytes32 _productId) {
        productId = _productId;
    }

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

    function createPolicy(CreatePolicyParams calldata params) external returns (uint256 policyId) {
        _nextPolicyId++;
        policyId = _nextPolicyId;
        uint256 maxPayout = (params.coverageAmount * 8000) / 10000;
        policyData[policyId] = PolicyData({
            buyer: params.buyer,
            coverageAmount: params.coverageAmount,
            premiumPaid: params.premiumAmount,
            maxPayout: maxPayout,
            expiresAt: block.timestamp + params.durationSeconds,
            status: 0
        });
    }

    function verifyAndCalculate(uint256 policyId, bytes calldata) external returns (PayoutResult memory result) {
        PolicyData storage pd = policyData[policyId];
        pd.status = 1;
        result =
            PayoutResult({triggered: true, payoutAmount: pd.maxPayout, recipient: pd.buyer, reason: "MOCK_TRIGGER"});
    }

    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (
            address insuredAgent,
            uint256 coverageAmount,
            uint256 premiumPaid,
            uint256 maxPayout,
            uint256 expiresAt,
            uint8 status
        )
    {
        PolicyData storage pd = policyData[policyId];
        return (pd.buyer, pd.coverageAmount, pd.premiumPaid, pd.maxPayout, pd.expiresAt, pd.status);
    }
}

/// @dev Mock price oracle for BondVault
contract MockPriceOracle {
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

/// @title FullPolicyLifecycleTest
/// @notice Integration tests using REAL core contracts, mock external deps only.
contract FullPolicyLifecycleTest is Test {
    // ═══════ CORE CONTRACTS (real) ═══════
    LuminaTokenV2 token;
    BondVault bondVault;
    ClaimBond claimBond;
    TWAPBurner twapBurner;
    PolicyManagerV2 policyManager;
    CoverRouterV2 coverRouter;

    // ═══════ MOCKS (external deps only) ═══════
    MockUSDC usdc;
    MockSwapRouter swapRouter;
    MockShieldV2 mockShield;
    MockPriceOracle priceOracle;

    // ═══════ ADDRESSES ═══════
    address bondVaultAddr;
    address cexReserve = makeAddr("cexReserve");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");
    address buyer = makeAddr("buyer");

    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC1H-MOCK");

    // ═══════ SETUP ═══════
    function setUp() public {
        // Warp to Jan 2 2026 to satisfy BondVault epoch math (BASE_TS = Jan 1 2026)
        vm.warp(1767312000);

        // 1. Deploy mocks for external deps
        usdc = new MockUSDC();
        priceOracle = new MockPriceOracle(0.036e18); // $0.036

        // 2. Deploy ClaimBond (needs to exist before BondVault)
        claimBond = new ClaimBond();

        // 3. Deploy PolicyManagerV2 with a placeholder, we'll set real bondVault after
        //    BondVault needs policyManager in constructor, so we use address(this) as policyManager
        //    then deploy the real PolicyManagerV2 after.

        // We need to break the circular dep: BondVault(policyManager) <-> PolicyManagerV2(bondVault)
        // Solution: BondVault takes policyManager in constructor. Deploy BondVault with address(this)
        // as temp policyManager. Then deploy PolicyManagerV2 with real bondVault.
        // But BondVault.policyManager is immutable, so we deploy PolicyManagerV2 first with a
        // placeholder bondVault... No — PolicyManagerV2.bondVault is also immutable.
        //
        // The trick: predict the BondVault address. Or just deploy in the right order:
        //   a) Deploy token with predicted bondVault address? No, too complex.
        //   b) Use address(this) as policyManager for BondVault (test contract acts as PM).
        //
        // For integration tests, we deploy BondVault with `address(this)` as policyManager
        // so we can call issueBond directly for bond tests. For the CoverRouter flow,
        // PolicyManagerV2 calls BondVault — but PM requires msg.sender == router.
        // We need TWO separate bondVaults or we accept that the full pipeline can't
        // call issueBond from PM (since PM won't be the policyManager).
        //
        // Simplest approach: deploy BondVault with policyManager = the PolicyManagerV2 address.
        // We predict PM address using CREATE nonce.

        // Deploy token first (needs bondVault address — predict it)
        // Nonce tracking: deployer = address(this)
        // nonces used so far: usdc (0), priceOracle (1), claimBond (2)
        // Next deploys: token (3), swapRouter (4), twapBurner (5), policyManager (6), bondVault(7)
        // We need bondVault address at token deploy time.
        // Let's restructure: deploy things that don't need each other first.

        // Actually LuminaTokenV2 just needs 5 recipient addresses. BondVault is one of them.
        // We can predict BondVault address or use a temp address for the token recipient,
        // then transfer the tokens.

        // Simplest: use makeAddr addresses for token recipients, then transfer LUMINA to real bondVault.
        // Token already mints to bondVaultAddr in constructor. We'll use the real bondVault address.

        // Let's just deploy in the right order by predicting addresses.
        // address(this) nonce: usdc=1, priceOracle=2, claimBond=3
        // We'll compute future addresses.

        uint64 currentNonce = vm.getNonce(address(this));
        // token will be deployed at nonce currentNonce
        // swapRouter at currentNonce+1
        // twapBurner at currentNonce+2
        // policyManager at currentNonce+3
        // bondVault at currentNonce+4

        address predictedBondVault = vm.computeCreateAddress(address(this), currentNonce + 4);
        bondVaultAddr = predictedBondVault;

        // 3. Deploy token with predicted bondVault
        token = new LuminaTokenV2(predictedBondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);

        // 4. Deploy swap router mock
        swapRouter = new MockSwapRouter(address(token));
        deal(address(token), address(swapRouter), 1_000_000e18);

        // 5. Deploy TWAPBurner
        twapBurner = new TWAPBurner(address(usdc), address(token), address(swapRouter));

        // 6. Deploy PolicyManagerV2 with predicted bondVault
        policyManager = new PolicyManagerV2(predictedBondVault);

        // 7. Deploy BondVault with real policyManager
        bondVault = new BondVault(address(token), address(claimBond), address(priceOracle), address(policyManager));
        require(address(bondVault) == predictedBondVault, "BondVault address mismatch");

        // 8. Wire ClaimBond → BondVault
        claimBond.setBondVault(address(bondVault));

        // 9. Grant BURNER_ROLE to TWAPBurner
        token.grantRole(token.BURNER_ROLE(), address(twapBurner));

        // 10. Deploy MockShield and register it
        mockShield = new MockShieldV2(PRODUCT_ID);

        // 11. Wire PolicyManagerV2
        policyManager.setRouter(address(this)); // temp: let test contract act as router for setup
        policyManager.registerProduct(PRODUCT_ID, address(mockShield));

        // 12. Deploy CoverRouter
        coverRouter = new CoverRouterV2(address(usdc), address(policyManager), address(twapBurner));

        // 13. Set CoverRouter as the real router in PolicyManager
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

        // 15. Give buyer some USDC
        usdc.mint(buyer, 1_000_000e6);
    }

    // ═══════ TEST 1: Token Distribution ═══════

    function test_FullSystem_Deploy_CorrectDistribution() public view {
        assertEq(token.balanceOf(address(bondVault)), 70_000_000e18, "BondVault should have 70M");
        assertEq(token.balanceOf(cexReserve), 14_000_000e18, "CEX should have 14M");
        assertEq(token.balanceOf(founderVesting), 8_000_000e18, "Founder should have 8M");
        assertEq(token.balanceOf(lbpDeposit), 5_000_000e18, "LBP should have 5M");
        assertEq(token.balanceOf(treasuryVesting), 3_000_000e18, "Treasury should have 3M");
        assertEq(token.totalSupply(), 100_000_000e18, "Total supply should be 100M");
    }

    // ═══════ TEST 2: Premium Flow — Legacy Mode 100% Burn ═══════

    function test_PremiumFlow_LegacyMode_100PercentBurn() public {
        uint256 coverageAmount = 1000e6; // $1,000

        // Buyer approves and purchases policy
        vm.startPrank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);
        coverRouter.purchasePolicy(PRODUCT_ID, coverageAmount, "BTC");
        vm.stopPrank();

        // Premium should be in TWAPBurner
        // premium = coverage * payoutRatio * triggerProb * margin / 10000^3
        // = 1000e6 * 8000 * 200 * 15000 / 1e12 = 2_400_000_000_000_000 / 1e12 = 2400e6... no
        // = 1000e6 * 8000 * 200 * 15000 = 2.4e18 / 1e12 = 2_400_000 = 2.4 USDC
        uint256 expectedPremium = (coverageAmount * 8000 * 200 * 15000) / (10000 * 10000 * 10000);
        assertEq(usdc.balanceOf(address(twapBurner)), expectedPremium, "TWAPBurner should hold premium USDC");

        // Execute burn (legacy mode = 100% burn)
        uint256 supplyBefore = token.totalSupply();
        twapBurner.executeBurn();
        uint256 supplyAfter = token.totalSupply();

        assertTrue(supplyAfter < supplyBefore, "LUMINA supply should decrease after burn");
        assertGt(twapBurner.totalLUMINABurned(), 0, "Should have burned some LUMINA");
        assertEq(twapBurner.totalUSDCBurned(), expectedPremium, "Should have burned all premium USDC");
        assertEq(usdc.balanceOf(address(twapBurner)), 0, "TWAPBurner USDC should be 0 after burn");
    }

    // ═══════ TEST 3: Bond Issuance Increases Commitments ═══════

    function test_BondIssuance_IncreasesCommitments() public {
        // Use policyManager to call issueBond (since bondVault.policyManager == policyManager)
        // We need to go through the full flow: CoverRouter -> PolicyManager -> BondVault
        // But issueBond is only called on triggerPayout. For a simpler test,
        // we set this test contract as the policyManager isn't possible (immutable).
        // Instead, trigger a real policy.

        // Buy a policy
        vm.startPrank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        uint256 commitBefore = bondVault.totalCommittedUSD();
        assertEq(commitBefore, 0, "No commitments initially");

        // Submit trigger — this calls PM.triggerPayout -> BondVault.issueBond
        // The MockShield always returns triggered=true
        coverRouter.submitTrigger(PRODUCT_ID, 1, "");

        uint256 commitAfter = bondVault.totalCommittedUSD();
        // payout = coverage * 80% = 1000e6 * 0.8 = 800e6 USDC
        // payoutUSD = 800e6 / 1e6 = 800 integer dollars
        // totalCommittedUSD += 800 * 1e18
        assertEq(commitAfter, 800 * 1e18, "Commitment should be 800 USD in 18-dec");
        assertGt(commitAfter, commitBefore, "Commitments should increase");
    }

    // ═══════ TEST 4: Bond Redemption Pays Full ═══════

    function test_BondRedemption_PaysFull() public {
        // Buy policy and trigger it
        vm.startPrank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        coverRouter.submitTrigger(PRODUCT_ID, 1, "");

        // Find the epoch ID: maturity = block.timestamp + 730 days
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Verify buyer has bonds
        uint256 bondBalance = claimBond.balanceOf(buyer, epochId);
        assertEq(bondBalance, 800, "Buyer should have 800 bond tokens ($800)");

        // Warp past maturity (730 days + 1 day margin)
        vm.warp(block.timestamp + 731 days);

        // Verify bonds are matured
        assertTrue(claimBond.isMatured(epochId), "Bonds should be matured");

        // Redeem bonds
        uint256 luminaBefore = token.balanceOf(buyer);
        vm.prank(buyer);
        bondVault.redeemBond(epochId, 800);
        uint256 luminaAfter = token.balanceOf(buyer);

        // At $0.036/LUMINA, $800 worth of LUMINA
        uint256 oraclePrice = 36e15; // $0.036
        uint256 expectedLumina = (800 * 1e36) / oraclePrice;
        assertEq(luminaAfter - luminaBefore, expectedLumina, "Should receive correct LUMINA for $800");
        assertGt(luminaAfter, luminaBefore, "Buyer should have more LUMINA after redemption");

        // Commitments should decrease
        assertEq(bondVault.totalCommittedUSD(), 0, "Commitments should be 0 after full redemption");
    }

    // ═══════ TEST 5: Policy Expires Without Trigger ═══════

    function test_FullPolicyLifecycle_ExpireWithoutTrigger() public {
        // Buy a policy
        vm.startPrank(buyer);
        usdc.approve(address(coverRouter), type(uint256).max);
        coverRouter.purchasePolicy(PRODUCT_ID, 1000e6, "BTC");
        vm.stopPrank();

        // Verify policy recorded
        assertEq(policyManager.totalPolicies(), 1, "Should have 1 policy");
        assertEq(policyManager.activePolicies(), 1, "Should have 1 active policy");

        // Warp past expiry (duration = 3600s = 1 hour)
        vm.warp(block.timestamp + 3601);

        // Mark as expired
        policyManager.markExpired(PRODUCT_ID, 1);

        // Verify state
        assertEq(policyManager.activePolicies(), 0, "No active policies after expiry");
        assertEq(bondVault.totalCommittedUSD(), 0, "No bonds should have been issued");
        assertEq(policyManager.totalTriggers(), 0, "No triggers should have occurred");

        // Verify no bond tokens minted for buyer
        // (We don't know the exact epochId but totalCommittedUSD=0 proves no bonds)
    }
}
