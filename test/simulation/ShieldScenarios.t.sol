// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/products/FlashBTCShield1h.sol";
import "../../src/products/FlashBTCShield4h.sol";
import "../../src/products/FlashBTCShield24h.sol";
import "../../src/products/FlashBTCShield48h.sol";
import "../../src/products/FlashETHShield1h.sol";
import "../../src/products/FlashETHShield24h.sol";
import "../../src/products/FlashETHShield48h.sol";
import "../../src/products/RateShockShield.sol";
import "../../src/products/BaseShield.sol";
import "../../src/core/CoverRouterV2.sol";
import "../../src/core/PolicyManagerV2.sol";
import "../../src/bonds/BondVault.sol";
import "../../src/bonds/ClaimBond.sol";
import "../../src/token/LuminaTokenV2.sol";
import "../../src/interfaces/IOracle.sol";
import "../../src/interfaces/IShield.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════════════════════════════════════════════════════════
//  INLINE MOCKS
// ═══════════════════════════════════════════════════════════

contract MockShieldOracle is IOracle {
    mapping(bytes32 => int256) private _prices;
    address private _oracleKey;

    constructor() {
        _oracleKey = address(this);
    }

    function setPrice(bytes32 asset, int256 price) external {
        _prices[asset] = price;
    }

    function getLatestPrice(bytes32 asset) external view override returns (int256) {
        return _prices[asset];
    }

    function getSequencerDowntime(uint256) external pure override returns (uint256) {
        return 0;
    }

    function verifySignature(bytes32, bytes calldata) external view override returns (address) {
        return _oracleKey;
    }

    function oracleKey() external view override returns (address) {
        return _oracleKey;
    }
}

contract MockCapacityOracle {
    uint256 private _price;

    constructor(uint256 price_) {
        _price = price_;
    }

    function getLuminaPrice() external view returns (uint256) {
        return _price;
    }
}

contract MockAavePool {
    uint128 private _variableBorrowRate;

    function setVariableBorrowRate(uint128 rate) external {
        _variableBorrowRate = rate;
    }

    function getReserveData(address) external view returns (IAaveV3Pool.ReserveData memory data) {
        data.currentVariableBorrowRate = _variableBorrowRate;
    }
}

contract MockTWAPBurner {
    function receivePremium(uint256) external {}
}

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // SafeERC20 compatibility: forceApprove calls approve
    function totalSupply() external pure returns (uint256) {
        return 1e12;
    }
}

// ═══════════════════════════════════════════════════════════
//  TEST CONTRACT
// ═══════════════════════════════════════════════════════════

contract ShieldScenariosTest is Test {
    // ═══════ SYSTEM CONTRACTS ═══════
    LuminaTokenV2 lumina;
    ClaimBond claimBond;
    BondVault bondVault;
    MockShieldOracle oracle;
    MockCapacityOracle capacityOracle;
    PolicyManagerV2 policyManager;
    CoverRouterV2 coverRouter;
    MockTWAPBurner twapBurner;
    MockUSDC usdc;
    MockAavePool aavePool;

    // ═══════ SHIELDS ═══════
    FlashBTCShield1h btc1h;
    FlashBTCShield4h btc4h;
    FlashBTCShield24h btc24h;
    FlashBTCShield48h btc48h;
    FlashETHShield1h eth1h;
    FlashETHShield24h eth24h;
    FlashETHShield48h eth48h;
    RateShockShield rateShock;

    // ═══════ CONSTANTS ═══════
    uint256 constant BASE_TS = 1767225600; // Jan 1 2026 UTC
    uint256 constant START_TIME = BASE_TS + 60 days;
    address constant BUYER = address(0xBEEF);
    address constant CEX_RESERVE = address(0xCE1);
    address constant FOUNDER = address(0xF01);
    address constant LBP = address(0x1B9);
    address constant TREASURY = address(0x7EA);

    // BTC = $60,000 (8 decimals Chainlink)
    int256 constant BTC_PRICE = 60_000_0000_0000; // 6000000000000 = $60,000
    // ETH = $3,000 (8 decimals)
    int256 constant ETH_PRICE = 3_000_0000_0000; // 300000000000 = $3,000
    // USDT = $1.00 (8 decimals)
    int256 constant USDT_PRICE = 1_0000_0000; // 100000000 = $1.00
    // Coverage = $1,000 USDC (6 decimals)
    uint256 constant COVERAGE = 1000e6;

    function setUp() public {
        vm.chainId(8453);
        vm.warp(START_TIME);

        // Deploy mocks
        oracle = new MockShieldOracle();
        capacityOracle = new MockCapacityOracle(0.05e18); // $0.05
        aavePool = new MockAavePool();
        aavePool.setVariableBorrowRate(5e25); // 5% APY — below trigger
        twapBurner = new MockTWAPBurner();
        usdc = new MockUSDC();

        // Set oracle prices
        oracle.setPrice("BTC", BTC_PRICE);
        oracle.setPrice("ETH", ETH_PRICE);
        oracle.setPrice("USDT", USDT_PRICE);
        oracle.setPrice("USDC", 1_0000_0000);

        // Deploy ClaimBond
        claimBond = ProxyDeployer.deployClaimBond();

        // Deploy LuminaTokenV2 (need 5 distinct nonzero addresses)
        // LuminaTokenV2 via proxy (+2 nonces), then BondVault via proxy: impl at +2, proxy at +3
        address bondVaultAddr = computeCreateAddress(address(this), vm.getNonce(address(this)) + 3);
        lumina = ProxyDeployer.deployLuminaTokenV2(bondVaultAddr, CEX_RESERVE, FOUNDER, LBP, TREASURY);

        // Deploy BondVault (policyManager = address(0) for 2-step pattern)
        bondVault =
            ProxyDeployer.deployBondVault(address(lumina), address(claimBond), address(capacityOracle), address(0));
        require(address(bondVault) == bondVaultAddr, "BondVault address mismatch");

        // Wire ClaimBond -> BondVault
        claimBond.setBondVault(address(bondVault));

        // Deploy PolicyManagerV2
        policyManager = ProxyDeployer.deployPolicyManagerV2(address(bondVault));

        // Wire BondVault -> PolicyManager
        bondVault.setPolicyManager(address(policyManager));

        // Deploy CoverRouterV2
        coverRouter = ProxyDeployer.deployCoverRouterV2(address(usdc), address(policyManager), address(twapBurner));
        coverRouter.setCapacityOracle(address(capacityOracle));

        // Wire PolicyManager -> Router
        policyManager.setRouter(address(coverRouter));

        // Deploy all 8 shields (router_ = policyManager per H-1 pattern)
        address pm = address(policyManager);
        address orc = address(oracle);

        btc1h = ProxyDeployer.deployFlashBTCShield1h(pm, orc);
        btc4h = ProxyDeployer.deployFlashBTCShield4h(pm, orc);
        btc24h = ProxyDeployer.deployFlashBTCShield24h(pm, orc);
        btc48h = ProxyDeployer.deployFlashBTCShield48h(pm, orc);
        eth1h = ProxyDeployer.deployFlashETHShield1h(pm, orc);
        eth24h = ProxyDeployer.deployFlashETHShield24h(pm, orc);
        eth48h = ProxyDeployer.deployFlashETHShield48h(pm, orc);
        rateShock = ProxyDeployer.deployRateShockShield(pm, orc, address(aavePool), address(usdc));

        // Register all shields in PolicyManager
        policyManager.registerProduct(keccak256("FLASHBTC1H-001"), address(btc1h));
        policyManager.registerProduct(keccak256("FLASHBTC4H-001"), address(btc4h));
        policyManager.registerProduct(keccak256("FLASHBTC24-001"), address(btc24h));
        policyManager.registerProduct(keccak256("FLASHBTC48-001"), address(btc48h));
        policyManager.registerProduct(keccak256("FLASHETH1H-001"), address(eth1h));
        policyManager.registerProduct(keccak256("FLASHETH24-001"), address(eth24h));
        policyManager.registerProduct(keccak256("FLASHETH48-001"), address(eth48h));
        policyManager.registerProduct(keccak256("RATESHOCK-001"), address(rateShock));

        // Configure products in CoverRouter (pricing params)
        // payoutRatioBps=8000, triggerProbBps varies, marginBps=15000
        coverRouter.configureProduct(keccak256("FLASHBTC1H-001"), 8000, 20, 15000, 3600, true);
        coverRouter.configureProduct(keccak256("FLASHBTC4H-001"), 8000, 30, 15000, 14400, true);
        coverRouter.configureProduct(keccak256("FLASHBTC24-001"), 8000, 50, 15000, 86400, true);
        coverRouter.configureProduct(keccak256("FLASHBTC48-001"), 8000, 70, 15000, 172800, true);
        coverRouter.configureProduct(keccak256("FLASHETH1H-001"), 8000, 25, 15000, 3600, true);
        coverRouter.configureProduct(keccak256("FLASHETH24-001"), 8000, 60, 15000, 86400, true);
        coverRouter.configureProduct(keccak256("FLASHETH48-001"), 8000, 80, 15000, 172800, true);
        coverRouter.configureProduct(keccak256("RATESHOCK-001"), 8000, 10, 15000, 604800, true);

        // Fund BUYER with USDC for purchases
        usdc.mint(BUYER, 100_000e6);
        vm.prank(BUYER);
        usdc.approve(address(coverRouter), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPER: Create policy via CoverRouter (full flow)
    // ═══════════════════════════════════════════════════════════

    function _createPolicy(bytes32 productId, bytes32 asset) internal returns (uint256 policyId) {
        vm.prank(BUYER);
        policyId = coverRouter.purchasePolicy(productId, COVERAGE, asset);
    }

    // ═══════════════════════════════════════════════════════════
    //  PART 1A: NO TRIGGER — POLICY EXPIRES (8 tests)
    // ═══════════════════════════════════════════════════════════

    function test_Shield_FlashBTC1h_NoTrigger_Expires() public {
        uint256 pid = _createPolicy(keccak256("FLASHBTC1H-001"), "BTC");
        // Warp past endTime + SAFETY_WINDOW (1h + 24h)
        vm.warp(block.timestamp + 3600 + 24 hours + 1);
        btc1h.checkAndSettlePolicy(pid);
        assertEq(uint8(btc1h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    function test_Shield_FlashBTC4h_NoTrigger_Expires() public {
        uint256 pid = _createPolicy(keccak256("FLASHBTC4H-001"), "BTC");
        vm.warp(block.timestamp + 14400 + 24 hours + 1);
        btc4h.checkAndSettlePolicy(pid);
        assertEq(uint8(btc4h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    function test_Shield_FlashBTC24h_NoTrigger_Expires() public {
        uint256 pid = _createPolicy(keccak256("FLASHBTC24-001"), "BTC");
        vm.warp(block.timestamp + 86400 + 24 hours + 1);
        btc24h.checkAndSettlePolicy(pid);
        assertEq(uint8(btc24h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    function test_Shield_FlashBTC48h_NoTrigger_Expires() public {
        uint256 pid = _createPolicy(keccak256("FLASHBTC48-001"), "BTC");
        vm.warp(block.timestamp + 172800 + 24 hours + 1);
        btc48h.checkAndSettlePolicy(pid);
        assertEq(uint8(btc48h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    function test_Shield_FlashETH1h_NoTrigger_Expires() public {
        uint256 pid = _createPolicy(keccak256("FLASHETH1H-001"), "ETH");
        vm.warp(block.timestamp + 3600 + 24 hours + 1);
        eth1h.checkAndSettlePolicy(pid);
        assertEq(uint8(eth1h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    function test_Shield_FlashETH24h_NoTrigger_Expires() public {
        uint256 pid = _createPolicy(keccak256("FLASHETH24-001"), "ETH");
        vm.warp(block.timestamp + 86400 + 24 hours + 1);
        eth24h.checkAndSettlePolicy(pid);
        assertEq(uint8(eth24h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    function test_Shield_FlashETH48h_NoTrigger_Expires() public {
        uint256 pid = _createPolicy(keccak256("FLASHETH48-001"), "ETH");
        vm.warp(block.timestamp + 172800 + 24 hours + 1);
        eth48h.checkAndSettlePolicy(pid);
        assertEq(uint8(eth48h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    function test_Shield_RateShock_NoTrigger_Expires() public {
        uint256 pid = _createPolicy(keccak256("RATESHOCK-001"), "USDC");
        vm.warp(block.timestamp + 604800 + 24 hours + 1);
        rateShock.checkAndSettlePolicy(pid);
        assertEq(uint8(rateShock.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // ═══════════════════════════════════════════════════════════
    //  PART 1B: TRIGGERED — POLICY PAID OUT (8 tests)
    // ═══════════════════════════════════════════════════════════

    function test_Shield_FlashBTC1h_Triggered_PaidOut() public {
        uint256 pid = _createPolicy(keccak256("FLASHBTC1H-001"), "BTC");
        // Drop BTC price by >5%: 60000 * 0.94 = 56400 (below 95% trigger)
        oracle.setPrice("BTC", 56_000_0000_0000); // $56,000
        vm.warp(block.timestamp + 3600 + 24 hours + 1);
        btc1h.checkAndSettlePolicy(pid);
        assertEq(uint8(btc1h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    function test_Shield_FlashBTC4h_Triggered_PaidOut() public {
        uint256 pid = _createPolicy(keccak256("FLASHBTC4H-001"), "BTC");
        // Drop BTC >8%: 60000 * 0.91 = 54600 (below 92% trigger)
        oracle.setPrice("BTC", 54_000_0000_0000); // $54,000
        vm.warp(block.timestamp + 14400 + 24 hours + 1);
        btc4h.checkAndSettlePolicy(pid);
        assertEq(uint8(btc4h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    function test_Shield_FlashBTC24h_Triggered_PaidOut() public {
        uint256 pid = _createPolicy(keccak256("FLASHBTC24-001"), "BTC");
        // Drop BTC >10%: trigger at 54000, set to 53000
        oracle.setPrice("BTC", 53_000_0000_0000); // $53,000
        vm.warp(block.timestamp + 86400 + 24 hours + 1);
        btc24h.checkAndSettlePolicy(pid);
        assertEq(uint8(btc24h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    function test_Shield_FlashBTC48h_Triggered_PaidOut() public {
        uint256 pid = _createPolicy(keccak256("FLASHBTC48-001"), "BTC");
        // Drop BTC >15%: trigger at 51000, set to 50000
        oracle.setPrice("BTC", 50_000_0000_0000); // $50,000
        vm.warp(block.timestamp + 172800 + 24 hours + 1);
        btc48h.checkAndSettlePolicy(pid);
        assertEq(uint8(btc48h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    function test_Shield_FlashETH1h_Triggered_PaidOut() public {
        uint256 pid = _createPolicy(keccak256("FLASHETH1H-001"), "ETH");
        // Drop ETH >7%: 3000 * 0.92 = 2760 (below 93% trigger = 2790)
        oracle.setPrice("ETH", 2_750_0000_0000); // $2,750
        vm.warp(block.timestamp + 3600 + 24 hours + 1);
        eth1h.checkAndSettlePolicy(pid);
        assertEq(uint8(eth1h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    function test_Shield_FlashETH24h_Triggered_PaidOut() public {
        uint256 pid = _createPolicy(keccak256("FLASHETH24-001"), "ETH");
        // Drop ETH >12%: trigger at 2640, set to 2600
        oracle.setPrice("ETH", 2_600_0000_0000); // $2,600
        vm.warp(block.timestamp + 86400 + 24 hours + 1);
        eth24h.checkAndSettlePolicy(pid);
        assertEq(uint8(eth24h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    function test_Shield_FlashETH48h_Triggered_PaidOut() public {
        uint256 pid = _createPolicy(keccak256("FLASHETH48-001"), "ETH");
        // Drop ETH >18%: trigger at 2460, set to 2400
        oracle.setPrice("ETH", 2_400_0000_0000); // $2,400
        vm.warp(block.timestamp + 172800 + 24 hours + 1);
        eth48h.checkAndSettlePolicy(pid);
        assertEq(uint8(eth48h.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    function test_Shield_RateShock_Triggered_PaidOut() public {
        uint256 pid = _createPolicy(keccak256("RATESHOCK-001"), "USDC");
        // Set borrow rate above 10% APY (10e25 in RAY)
        aavePool.setVariableBorrowRate(12e25); // 12% APY
        vm.warp(block.timestamp + 604800 + 24 hours + 1);
        rateShock.checkAndSettlePolicy(pid);
        assertEq(uint8(rateShock.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    // ═══════════════════════════════════════════════════════════
    //  PART 2: PREMIUM MATRIX — 8 shields x 5 coverage levels
    // ════════��══════════════════════════════════════════════════

    function test_PremiumMatrix_All8Shields_5Coverages() public view {
        bytes32[8] memory productIds = [
            keccak256("FLASHBTC1H-001"),
            keccak256("FLASHBTC4H-001"),
            keccak256("FLASHBTC24-001"),
            keccak256("FLASHBTC48-001"),
            keccak256("FLASHETH1H-001"),
            keccak256("FLASHETH24-001"),
            keccak256("FLASHETH48-001"),
            keccak256("RATESHOCK-001")
        ];

        // triggerProbBps per product (from configureProduct calls in setUp)
        uint256[8] memory triggerProbs = [uint256(20), 30, 50, 70, 25, 60, 80, 10];
        // All products share: payoutRatioBps=8000, marginBps=15000
        uint256 payoutRatioBps = 8000;
        uint256 marginBps = 15000;

        uint256[5] memory coverages = [uint256(100e6), 1000e6, 10_000e6, 100_000e6, 1_000_000e6];

        for (uint256 i = 0; i < 8; i++) {
            for (uint256 j = 0; j < 5; j++) {
                (uint256 premium, uint256 payout) = coverRouter.quotePremium(productIds[i], coverages[j]);

                // Compute expected premium: coverage * payoutRatio * triggerProb * margin / 1e12
                uint256 expectedPremium =
                    (coverages[j] * payoutRatioBps * triggerProbs[i] * marginBps) / (10000 * 10000 * 10000);
                if (expectedPremium == 0) expectedPremium = 1; // floor at 1

                // Exact match with the formula
                assertEq(premium, expectedPremium, "Premium must match formula exactly");

                // Premium must be > 0 and less than coverage
                assert(premium > 0);
                assert(premium < coverages[j]);

                // Payout must be 80% of coverage
                assertEq(payout, (coverages[j] * payoutRatioBps) / 10000, "Payout must be 80% of coverage");
            }
        }
    }
}
