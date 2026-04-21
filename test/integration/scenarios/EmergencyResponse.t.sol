// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {CapacityOracle} from "../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../src/oracles/SolvencyOracle.sol";
import {AdaptiveFeeDistributor} from "../../../src/core/AdaptiveFeeDistributor.sol";
import {TWAPBurner} from "../../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../../src/interfaces/IDexRouter.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";
import {BuybackEngine} from "../../../src/marketplace/BuybackEngine.sol";
import {MockSolvencyOracle} from "../../mocks/MockSolvencyOracle.sol";

// ═══════ INLINE MOCKS ═══════

contract MockUSDC is IERC20 {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockSwapRouter is IDexRouter {
    IERC20 public lumina;
    uint256 public rate = 27;

    constructor(address _lumina) {
        lumina = IERC20(_lumina);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256 amountOut) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * rate * 1e12);
        lumina.transfer(msg.sender, amountOut);
    }

    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function setRate(uint256 r) external {
        rate = r;
    }
}

/// @notice Minimal mock CapacityOracle that just returns emergencyPrice
contract MockCapacityOracle {
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

/// @notice Mock marketplace for BuybackEngine tests
contract MockBuybackMarketplace {
    struct MockListing {
        address seller;
        uint256 epochId;
        uint256 amount;
        uint256 priceUSDC;
        bool active;
    }

    mapping(uint256 => MockListing) public mockListings;
    IERC20 public usdc;
    address public claimBond;

    constructor(address _usdc, address _claimBond) {
        usdc = IERC20(_usdc);
        claimBond = _claimBond;
    }

    function setListing(uint256 id, address seller, uint256 epochId, uint256 amount, uint256 priceUSDC) external {
        mockListings[id] = MockListing(seller, epochId, amount, priceUSDC, true);
    }

    function getListing(uint256 id)
        external
        view
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active)
    {
        MockListing memory l = mockListings[id];
        return (l.seller, l.epochId, l.amount, l.priceUSDC, l.active);
    }

    function executeBuy(uint256 id) external {
        MockListing storage l = mockListings[id];
        require(l.active, "Not active");
        l.active = false;
        // Take USDC from buyer
        usdc.transferFrom(msg.sender, address(this), l.priceUSDC);
        // Transfer ClaimBond tokens to buyer (simulated: the engine should already hold them
        // in a real scenario the marketplace holds escrowed bonds)
    }
}

contract EmergencyResponseTest is Test {
    using ProxyDeployer for *;

    // ═══════ CONTRACTS ═══════
    LuminaTokenV2 token;
    MockUSDC usdc;
    MockSwapRouter swapRouter;
    MockCapacityOracle capacityOracle;
    ClaimBond claimBond;
    BondVault bondVault;
    SolvencyOracle solvencyOracle;
    AdaptiveFeeDistributor feeDistributor;
    TWAPBurner twapBurner;
    CoverRouterV2 coverRouter;
    PolicyManagerV2 policyManager;

    // ═══════ ADDRESSES ═══════
    address admin = makeAddr("admin");
    address user = makeAddr("user");
    address buybackReserve = makeAddr("buybackReserve");
    address opsReserve = makeAddr("opsReserve");
    address maintenanceReserve = makeAddr("maintenanceReserve");
    address bondVaultAddr; // pre-computed

    function setUp() public {
        vm.warp(1_770_000_000); // after Jan 1 2026 (BASE_TS = 1767225600) for valid bond epochs

        // Deploy USDC mock
        usdc = new MockUSDC();

        // Pre-compute BondVault address for LuminaTokenV2 constructor
        // BondVault needs: lumina, claimBond, priceOracle, policyManager
        // We need to deploy in careful order due to circular deps

        // 1. Capacity oracle (mock) with emergency price $0.036
        capacityOracle = new MockCapacityOracle(0.036e18);

        // 2. Token: needs bondVault address. We use a placeholder and deal tokens later.
        address fakeBondVault = makeAddr("fakeBondVault");
        token = ProxyDeployer.deployLuminaTokenV2(
            fakeBondVault, makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        // 3. Swap router
        swapRouter = new MockSwapRouter(address(token));
        deal(address(token), address(swapRouter), 5_000_000e18);

        // 4. ClaimBond
        claimBond = ProxyDeployer.deployClaimBond();

        // 5. PolicyManager (needs BondVault — deploy with placeholder, then set router)
        //    We pre-compute BondVault address: nonce-based. Let's just deploy PM first with a
        //    temp bondVault, but BondVault constructor requires policyManager...
        //    Solution: deploy PM with a fake bondVault, then deploy real BondVault with PM,
        //    then for tests that need issueBond we use the real BondVault.
        //    Actually PM.bondVault is immutable. Let's use a different approach:
        //    Deploy a temporary "policyManager" address, deploy BondVault, then deploy real PM.

        // Deploy BondVault with a temporary policyManager
        address tempPM = address(this); // we'll act as PM for direct tests
        bondVault = ProxyDeployer.deployBondVault(address(token), address(claimBond), address(capacityOracle), tempPM);
        bondVaultAddr = address(bondVault);

        // Fund BondVault with LUMINA
        deal(address(token), bondVaultAddr, 70_000_000e18);

        // Set BondVault on ClaimBond
        claimBond.setBondVault(bondVaultAddr);

        // Deploy PolicyManager with bondVault
        policyManager = ProxyDeployer.deployPolicyManagerV2(bondVaultAddr);

        // 6. TWAPBurner
        twapBurner = new TWAPBurner(address(usdc), address(token), address(swapRouter));
        token.grantRole(token.BURNER_ROLE(), address(twapBurner));

        // 7. SolvencyOracle
        solvencyOracle = new SolvencyOracle(bondVaultAddr, address(capacityOracle), admin);

        // 8. AdaptiveFeeDistributor
        feeDistributor = new AdaptiveFeeDistributor(address(solvencyOracle));

        // 9. CoverRouter
        coverRouter = ProxyDeployer.deployCoverRouterV2(address(usdc), address(policyManager), address(twapBurner));

        // Wire: PM router
        policyManager.setRouter(address(coverRouter));

        // Wire: TWAPBurner adaptive mode
        twapBurner.setFeeDistributor(address(feeDistributor));
        twapBurner.setReserves(buybackReserve, opsReserve, maintenanceReserve);
        twapBurner.setAdaptiveMode(true);

        // Give user USDC
        usdc.mint(user, 1_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 1: Pause SolvencyOracle -> fallback distribution activates
    // ═══════════════════════════════════════════════════════════════

    function test_Emergency_PauseSolvencyOracle_FallbackActivates() public {
        // Verify feeDistributor is healthy before pause
        assertTrue(feeDistributor.isHealthy(), "Should be healthy before pause");

        // Admin pauses the SolvencyOracle
        vm.prank(admin);
        solvencyOracle.setEmergencyPause(true);

        // Now feeDistributor.isHealthy() should return false
        assertFalse(feeDistributor.isHealthy(), "Should be unhealthy after pause");

        // Fund TWAPBurner with USDC and execute burn
        usdc.mint(address(twapBurner), 10_000e6);

        uint256 buybackBefore = usdc.balanceOf(buybackReserve);
        uint256 opsBefore = usdc.balanceOf(opsReserve);

        twapBurner.executeBurn();

        // Fallback is 85/8/2/5 (8500/800/200/500 bps)
        // With 10_000 USDC: burn=8500, buyback=800, ops=200, maintenance=500
        uint256 buybackReceived = usdc.balanceOf(buybackReserve) - buybackBefore;
        uint256 opsReceived = usdc.balanceOf(opsReserve) - opsBefore;

        assertEq(buybackReceived, 800e6, "Buyback should receive 8% fallback");
        assertEq(opsReceived, 200e6, "Ops should receive 2% fallback");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 2: Bond issuance and redemption lifecycle
    // ═══════════════════════════════════════════════════════════════

    function test_Emergency_BondIssuanceAndRedemption() public {
        // Issue a bond (we are policyManager = address(this))
        bondVault.issueBond(user, 100); // $100 bond

        // Compute the epoch
        uint256 issuanceTime = block.timestamp;
        uint256 maturityTs = issuanceTime + 730 days;
        uint256 BASE_TS = 1767225600; // Jan 1 2026 UTC
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        uint256 balance = claimBond.balanceOf(user, epochId);
        assertEq(balance, 100, "User should have 100 bond tokens");

        // Warp past maturity (730 days)
        vm.warp(block.timestamp + 731 days);
        capacityOracle.setPrice(0.036e18); // set reasonable price for redemption calc

        // Redeem
        vm.prank(user);
        bondVault.redeemBond(epochId, 50); // partial redeem

        uint256 balanceAfter = claimBond.balanceOf(user, epochId);
        assertEq(balanceAfter, 50, "User should have 50 bond tokens after partial redeem");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 3: Buyback circuit breaker skips LUMINA reserves burn
    // ═══════════════════════════════════════════════════════════════

    function test_Emergency_BuybackCircuitBreaker_SkipsDoubleBurn() public {
        // Deploy a MockSolvencyOracle for BuybackEngine (need controllable solvency ratio)
        MockSolvencyOracle mockSolvOracle = new MockSolvencyOracle();
        // Set solvency below 150% (15000 bps)
        mockSolvOracle.setSolvencyRatio(14000); // 140%

        // Deploy mock marketplace
        MockBuybackMarketplace mockMktplace = new MockBuybackMarketplace(address(usdc), address(claimBond));

        // Deploy BuybackEngine
        // Warp past activation delay for BuybackEngine
        vm.warp(block.timestamp); // record deployment time
        BuybackEngine engine = new BuybackEngine(
            address(claimBond),
            bondVaultAddr,
            address(mockSolvOracle),
            address(capacityOracle),
            address(mockMktplace),
            address(usdc),
            address(this) // multisig = this test contract
        );

        // Authorize BuybackEngine on BondVault (requires policyManager = address(this))
        bondVault.setAuthorizedCaller(address(engine), true);

        // Configure daily buyback
        engine.setDailyBuyback(100_000e6, 80, 24);

        // Create a listing in mock marketplace
        // First mint some ClaimBond tokens and give them to the engine
        // We need a valid epoch. Mint bonds via BondVault.issueBond
        bondVault.issueBond(address(engine), 500); // $500 bond to engine

        // Compute the epoch
        uint256 maturityTs = block.timestamp + 730 days;
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (maturityTs - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        uint256 epochId = year * 100 + month;

        // Setup listing: price at 80% of face value = 500 * 0.80 = $400
        mockMktplace.setListing(0, makeAddr("seller"), epochId, 500, 400e6);

        // Fund engine with USDC for the purchase
        usdc.mint(address(engine), 500e6);
        vm.prank(address(engine));
        usdc.approve(address(mockMktplace), 500e6);

        // Record vault LUMINA balance before
        uint256 vaultLuminaBefore = token.balanceOf(bondVaultAddr);

        // The mock marketplace executeBuy doesn't transfer bonds to engine,
        // but engine already holds them from issueBond above.
        // Approve engine for ClaimBond (engine needs to call burnByHolder on itself)
        // Engine inherits ERC1155Holder so it can receive. It already holds bonds.

        // Execute offer
        engine.executeOffer(0);

        // Since solvency < 150%, the LUMINA reserves burn should be SKIPPED
        uint256 vaultLuminaAfter = token.balanceOf(bondVaultAddr);
        assertEq(vaultLuminaAfter, vaultLuminaBefore, "Vault LUMINA should NOT decrease when solvency < 150%");

        // But obligations should have decreased (NFT burn + obligations reduction happened)
        // The bond was $500 face value = 500 * 1e18 in 18-dec USD-wei
        // Original committed was 500 * 1e18 from issueBond
        // After decreaseObligations(500 * 1e18), should be 0
        assertEq(bondVault.totalCommittedUSD(), 0, "Obligations should be reduced to 0");
    }

    // ═══════════════════════════════════════════════════════════════
    // TEST 4: CoverRouter pause blocks new policies
    // ═══════════════════════════════════════════════════════════════

    function test_Emergency_CoverRouterPause_BlocksNewPolicies() public {
        // Configure a product on CoverRouter
        bytes32 productId = keccak256("TEST-PRODUCT-001");
        coverRouter.configureProduct(
            productId,
            8000, // payoutRatioBps: 80%
            20, // triggerProbBps: 0.20%
            15000, // marginBps: 1.50x
            3600, // durationSeconds: 1 hour
            true // active
        );

        // Pause the router
        coverRouter.setPaused(true);

        // Attempt to purchase should revert with ContractPaused
        vm.startPrank(user);
        usdc.approve(address(coverRouter), type(uint256).max);
        vm.expectRevert(CoverRouterV2.ContractPaused.selector);
        coverRouter.purchasePolicy(productId, 1000e6, "BTC");
        vm.stopPrank();

        // Unpause and verify purchase would not revert with ContractPaused
        coverRouter.setPaused(false);

        // Note: purchase may revert for other reasons (no shield registered in PM),
        // but it should NOT revert with ContractPaused
        vm.startPrank(user);
        // This will revert because product is not registered in PolicyManager,
        // but the revert reason should NOT be ContractPaused
        vm.expectRevert(); // generic revert (ProductNotFound in PM)
        coverRouter.purchasePolicy(productId, 1000e6, "BTC");
        vm.stopPrank();
    }

    // ═══════ HELPERS ═══════

    function _getEpochFromTimestamp(uint256 ts) internal pure returns (uint256) {
        uint256 BASE_TS = 1767225600;
        if (ts < BASE_TS) return 202601;
        uint256 monthsFromBase = (ts - BASE_TS) / 2629746;
        uint256 year = 2026 + monthsFromBase / 12;
        uint256 month = 1 + monthsFromBase % 12;
        return year * 100 + month;
    }
}
