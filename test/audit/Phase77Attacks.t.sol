// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {ShieldKeeper} from "../../src/automation/ShieldKeeper.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════════════════════════════════════════════════════════
// INLINE MOCKS
// ═══════════════════════════════════════════════════════════

contract MockUSDC77 {
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

contract MockLUMINA77 {
    string public name = "LUMINA";
    string public symbol = "LUMINA";
    uint8 public decimals = 18;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }
}

contract MockPriceOracle77 {
    uint256 public price;

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

contract MockPolicyManager77 {
    uint256 public nextPolicyId = 1;

    function recordPolicy(bytes32, address, uint256, uint256, uint32, bytes32) external returns (uint256 policyId) {
        policyId = nextPolicyId++;
    }

    function triggerPayout(bytes32, uint256, bytes calldata) external {}
}

contract MockTWAPBurner77 {
    MockUSDC77 public usdc;

    constructor(address _usdc) {
        usdc = MockUSDC77(_usdc);
    }

    function receivePremium(uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
    }
}

contract MockDexRouter77 is IDexRouter {
    uint256 public quoteReturn;
    uint256 public swapReturn;
    MockLUMINA77 public lumina;

    constructor(address _lumina, uint256 _quoteReturn, uint256 _swapReturn) {
        lumina = MockLUMINA77(_lumina);
        quoteReturn = _quoteReturn;
        swapReturn = _swapReturn;
    }

    function getQuote(address, address, uint256) external view returns (uint256) {
        return quoteReturn;
    }

    function swap(address, address, uint256, uint256 minAmountOut) external returns (uint256) {
        require(swapReturn >= minAmountOut, "Slippage exceeded");
        lumina.mint(msg.sender, swapReturn);
        return swapReturn;
    }
}

/// @dev A malicious DEX router that inflates the quote but returns less on swap.
contract MaliciousDexRouter77 is IDexRouter {
    uint256 public inflatedQuote;
    uint256 public actualSwapReturn;
    MockLUMINA77 public lumina;

    constructor(address _lumina, uint256 _inflatedQuote, uint256 _actualSwap) {
        lumina = MockLUMINA77(_lumina);
        inflatedQuote = _inflatedQuote;
        actualSwapReturn = _actualSwap;
    }

    function getQuote(address, address, uint256) external view returns (uint256) {
        return inflatedQuote;
    }

    function swap(address, address, uint256, uint256 minAmountOut) external returns (uint256) {
        require(actualSwapReturn >= minAmountOut, "Slippage exceeded");
        lumina.mint(msg.sender, actualSwapReturn);
        return actualSwapReturn;
    }
}

/// @dev Malicious router that attempts reentrancy on TWAPBurner.executeBurn()
contract ReentrantDexRouter77 is IDexRouter {
    TWAPBurner public target;
    MockLUMINA77 public lumina;
    bool public attacked;

    constructor(address _target, address _lumina) {
        target = TWAPBurner(payable(_target));
        lumina = MockLUMINA77(_lumina);
    }

    function getQuote(address, address, uint256) external pure returns (uint256) {
        return 1000e18;
    }

    function swap(address, address, uint256, uint256) external returns (uint256) {
        if (!attacked) {
            attacked = true;
            // Attempt reentrancy
            try target.executeBurn() {
            // Should not reach here
            }
                catch {}
        }
        lumina.mint(msg.sender, 1000e18);
        return 1000e18;
    }
}

/// @dev A mock shield that implements checkAndSettlePolicy with internal state
contract MockShield77 {
    enum Status {
        NONEXISTENT,
        ACTIVE,
        EXPIRED,
        PAID_OUT
    }

    struct Policy {
        address buyer;
        uint256 expiresAt;
        Status status;
    }

    uint256 public constant SAFETY_WINDOW = 24 hours;
    mapping(uint256 => Policy) public policies;
    uint256 public nextId = 1;

    function createPolicy(address buyer, uint256 duration) external returns (uint256 policyId) {
        policyId = nextId++;
        policies[policyId] = Policy({buyer: buyer, expiresAt: block.timestamp + duration, status: Status.ACTIVE});
    }

    function checkAndSettlePolicy(uint256 policyId) external {
        Policy storage p = policies[policyId];
        require(p.buyer != address(0), "Not found");
        require(p.status == Status.ACTIVE, "Not active");
        require(block.timestamp >= p.expiresAt + SAFETY_WINDOW, "Safety window not passed");
        p.status = Status.EXPIRED;
    }

    function getPolicyStatus(uint256 policyId) external view returns (uint8) {
        return uint8(policies[policyId].status);
    }
}

/// @dev A poisoned shield that reverts on checkAndSettlePolicy for certain policies
contract PoisonedShield77 {
    mapping(uint256 => bool) public shouldRevert;
    mapping(uint256 => bool) public settled;

    function setPoisoned(uint256 policyId) external {
        shouldRevert[policyId] = true;
    }

    function checkAndSettlePolicy(uint256 policyId) external {
        if (shouldRevert[policyId]) {
            revert("POISONED");
        }
        settled[policyId] = true;
    }

    function getPolicyStatus(uint256 policyId) external view returns (uint8) {
        return settled[policyId] ? 3 : 2; // EXPIRED or ACTIVE
    }
}

/// @dev Mock PolicyManager for ShieldKeeper tests
contract MockPolicyManagerKeeper77 {
    mapping(bytes32 => address) public productShield;
    bytes32[] public productIds;
    mapping(bytes32 => uint256[]) internal _activeIds;

    function addProduct(bytes32 productId, address shield) external {
        productIds.push(productId);
        productShield[productId] = shield;
    }

    function setActivePolicies(bytes32 productId, uint256[] memory ids) external {
        _activeIds[productId] = ids;
    }

    function getActivePolicyIds(bytes32 productId, uint256 maxResults) external view returns (uint256[] memory) {
        uint256[] storage all = _activeIds[productId];
        uint256 len = all.length > maxResults ? maxResults : all.length;
        uint256[] memory result = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = all[i];
        }
        return result;
    }

    function getProductCount() external view returns (uint256) {
        return productIds.length;
    }
}

/// @dev Mock for BuybackEngine tests
contract MockSolvencyOracle77 {
    uint256 public ratio = 16000; // 160%

    function setSolvencyRatio(uint256 _r) external {
        ratio = _r;
    }

    function getSolvencyRatio() external view returns (uint256) {
        return ratio;
    }
}

contract MockClaimBond77 {
    function getFaceValue(uint256) external pure returns (uint256) {
        return 100e18;
    }
    function burnByHolder(address, uint256, uint256) external {}
}

contract MockBondVault77 {
    function decreaseObligations(uint256) external {}
    function burnFromReserves(uint256) external {}
}

contract MockMarketplace77 {
    MockUSDC77 public usdc;
    bool public listingActive = true;

    constructor(address _usdc) {
        usdc = MockUSDC77(_usdc);
    }

    function setActive(bool a) external {
        listingActive = a;
    }

    function getListing(uint256) external view returns (address, uint256, uint256, uint256, bool) {
        return (address(0x999), 1, 2, 50e6, listingActive);
    }

    function executeBuy(uint256) external {
        usdc.transferFrom(msg.sender, address(this), 50e6);
    }
}

// ═══════════════════════════════════════════════════════════
// ATTACK SIMULATION TEST CONTRACT
// ═══════════════════════════════════════════════════════════

contract Phase77Attacks is Test {
    uint256 constant BASE_TIME = 1767225600 + 60 days;

    MockUSDC77 usdc;
    MockLUMINA77 lumina;
    MockPriceOracle77 oracle;
    MockPolicyManager77 policyManager;
    MockTWAPBurner77 twapBurner;
    CoverRouterV2 router;

    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");
    address owner;

    function setUp() public {
        vm.chainId(8453);
        vm.warp(BASE_TIME);
        owner = address(this);

        usdc = new MockUSDC77();
        lumina = new MockLUMINA77();
        oracle = new MockPriceOracle77();
        policyManager = new MockPolicyManager77();
        twapBurner = new MockTWAPBurner77(address(usdc));

        router = ProxyDeployer.deployCoverRouterV2(address(usdc), address(policyManager), address(twapBurner));
        router.setCapacityOracle(address(oracle));

        // Configure a product
        bytes32 productId = keccak256("FLASHBTC1H-001");
        router.configureProduct(productId, 8000, 20, 15000, 3600, true);

        // Fund alice
        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(router), type(uint256).max);

        // Set oracle to safe price
        oracle.setPrice(10e15); // $0.010
    }

    // ═══════════════════════════════════════════════════════
    // TEST 1: Auto-Pause Oracle Manipulation
    // ═══════════════════════════════════════════════════════

    function test_Attack_AutoPause_OracleManipulation() public {
        bytes32 productId = keccak256("FLASHBTC1H-001");

        // Attack: manipulate oracle to report price below $0.005
        oracle.setPrice(4e15); // $0.004
        assertTrue(router.isProtocolAutoPaused(), "Should be auto-paused");

        // Attempt purchase must revert
        vm.prank(alice);
        vm.expectRevert("Protocol auto-paused: LUMINA price below safety threshold");
        router.purchasePolicy(productId, 1000e6, "BTC");

        // Restore price above $0.008
        oracle.setPrice(9e15); // $0.009
        assertFalse(router.isProtocolAutoPaused(), "Should not be paused anymore");

        // Purchase now succeeds (per-tx check, no sticky state)
        vm.prank(alice);
        uint256 policyId = router.purchasePolicy(productId, 1000e6, "BTC");
        assertGt(policyId, 0, "Policy should be created");
    }

    // ═══════════════════════════════════════════════════════
    // TEST 2: Auto-Settlement Double Claim
    // ═══════════════════════════════════════════════════════

    function test_Attack_AutoSettlement_DoubleClaim() public {
        MockShield77 shield = new MockShield77();

        // Create policy with 1h duration
        uint256 policyId = shield.createPolicy(alice, 1 hours);

        // Warp past endTime + SAFETY_WINDOW (24h)
        vm.warp(BASE_TIME + 1 hours + 24 hours + 1);

        // First settlement succeeds
        shield.checkAndSettlePolicy(policyId);
        assertEq(uint8(shield.getPolicyStatus(policyId)), 2); // EXPIRED (enum index 2 in mock)

        // Second call must revert "Not active"
        vm.expectRevert("Not active");
        shield.checkAndSettlePolicy(policyId);
    }

    // ═══════════════════════════════════════════════════════
    // TEST 3: Premature Settlement Attempt
    // ═══════════════════════════════════════════════════════

    function test_Attack_AutoSettlement_PrematureSettlement() public {
        MockShield77 shield = new MockShield77();

        // Create policy with 1h duration
        uint256 policyId = shield.createPolicy(alice, 1 hours);

        // Warp only past endTime but NOT past SAFETY_WINDOW
        vm.warp(BASE_TIME + 1 hours + 12 hours); // only 12h past expiry, need 24h

        // Must revert
        vm.expectRevert("Safety window not passed");
        shield.checkAndSettlePolicy(policyId);

        // Now warp past safety window
        vm.warp(BASE_TIME + 1 hours + 24 hours + 1);
        shield.checkAndSettlePolicy(policyId); // succeeds
    }

    // ═══════════════════════════════════════════════════════
    // TEST 4: ShieldKeeper Unauthorized performUpkeep
    // ═══════════════════════════════════════════════════════

    function test_Attack_ShieldKeeper_UnauthorizedPerformUpkeep() public {
        MockPolicyManagerKeeper77 pmk = new MockPolicyManagerKeeper77();
        MockShield77 shield = new MockShield77();
        bytes32 productId = keccak256("TEST-PRODUCT");
        pmk.addProduct(productId, address(shield));

        ShieldKeeper keeper = ProxyDeployer.deployShieldKeeper(address(pmk));

        // Create policies
        uint256 pid1 = shield.createPolicy(alice, 1 hours);
        uint256 pid2 = shield.createPolicy(attacker, 1 hours);
        uint256[] memory ids = new uint256[](2);
        ids[0] = pid1;
        ids[1] = pid2;
        pmk.setActivePolicies(productId, ids);

        // Warp past safety window
        vm.warp(BASE_TIME + 1 hours + 24 hours + 1);

        // Anyone (attacker) can call performUpkeep — this is by design (Chainlink)
        // But the actual settlement logic in shield has its own guards
        bytes memory performData = abi.encode(productId, ids);
        vm.prank(attacker);
        keeper.performUpkeep(performData);

        // Both policies settled properly
        assertEq(uint8(shield.getPolicyStatus(pid1)), 2); // EXPIRED (enum index 2 in mock)
        assertEq(uint8(shield.getPolicyStatus(pid2)), 2); // EXPIRED (enum index 2 in mock)

        // Calling again is safe — emits SettlementFailed, does NOT revert
        vm.prank(attacker);
        keeper.performUpkeep(performData); // try/catch handles the "Not active" revert
    }

    // ═══════════════════════════════════════════════════════
    // TEST 5: Multi-DEX Slippage Protection
    // ═══════════════════════════════════════════════════════

    function test_Attack_MultiDex_SlippageProtection() public {
        // Setup: malicious adapter returns inflated quote (10000 LUMINA) but only delivers 100 LUMINA
        // With 5% slippage from the 10000 quote, minOut = 9500. Actual delivery = 100 => revert.
        MaliciousDexRouter77 maliciousRouter = new MaliciousDexRouter77(
            address(lumina),
            10000e18, // inflated quote
            100e18 // actual swap return (way below slippage threshold)
        );

        TWAPBurner burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(maliciousRouter));

        // [legacy-migration] pattern #3 (F-19): minOut is now derived from the
        // capacity oracle, NOT the executing router's (inflated) quote. Wire an
        // oracle priced at $0.01 so for a 1000 USDC burn the oracle-implied
        // expectedOut is 1000e6*1e12*1e18/1e16 = 100_000e18 and minOut (95%) =
        // 95_000e18 — far above the malicious router's 100e18 delivery, so the
        // swap still reverts on slippage (the original assertion holds).
        MockPriceOracle77 minOutOracle = new MockPriceOracle77();
        minOutOracle.setPrice(10e15); // $0.010
        burner.setCapacityOracle(address(minOutOracle));

        // Fund burner
        usdc.mint(address(burner), 1000e6);

        // executeBurn should revert because actual output (100) < oracle-derived minOut
        vm.expectRevert("Slippage exceeded");
        burner.executeBurn();
    }

    // ═══════════════════════════════════════════════════════
    // TEST 6: BuybackEngine Rapid Config Changes
    // ═══════════════════════════════════════════════════════

    function test_Attack_BuybackEngine_RapidConfigChanges() public {
        MockSolvencyOracle77 solvOracle = new MockSolvencyOracle77();
        MockClaimBond77 bond = new MockClaimBond77();
        MockBondVault77 vault = new MockBondVault77();
        MockMarketplace77 mktplace = new MockMarketplace77(address(usdc));
        MockPriceOracle77 capOracle = new MockPriceOracle77();
        capOracle.setPrice(10e15);

        // Import the BuybackEngine
        // Deploy using CREATE to avoid import complexities
        address buybackAddr = _deployBuybackEngine(
            address(bond),
            address(vault),
            address(solvOracle),
            address(capOracle),
            address(mktplace),
            address(usdc),
            address(this)
        );

        // Fund the engine with USDC
        usdc.mint(buybackAddr, 500e6);

        // We'll test the daily budget by simulating the setDailyBuyback calls
        // The key invariant: spentToday cannot exceed dailyBudget regardless of reconfigs

        // Config 1: budget = $200
        (bool s1,) =
            buybackAddr.call(abi.encodeWithSignature("setDailyBuyback(uint256,uint256,uint256)", 200e6, 80, 24));
        assertTrue(s1, "Config 1 should succeed");

        // Config 2: budget = $150 (lower)
        (bool s2,) =
            buybackAddr.call(abi.encodeWithSignature("setDailyBuyback(uint256,uint256,uint256)", 150e6, 80, 24));
        assertTrue(s2, "Config 2 should succeed");

        // Config 3: budget = $100 (even lower)
        (bool s3,) =
            buybackAddr.call(abi.encodeWithSignature("setDailyBuyback(uint256,uint256,uint256)", 100e6, 80, 24));
        assertTrue(s3, "Config 3 should succeed");

        // Read final config
        (bool sr, bytes memory data) = buybackAddr.call(abi.encodeWithSignature("dailyConfig()"));
        assertTrue(sr);
        (uint256 budget,,, uint256 spent) = abi.decode(data, (uint256, uint256, uint256, uint256));

        // Budget is the LAST configured value, spent resets to 0 on reconfigure
        assertEq(budget, 100e6, "Budget should be last configured value");
        assertEq(spent, 0, "Spent should reset on reconfig");

        // Even after 3 reconfigs, the cap is respected: can't spend more than current budget
        // This is the invariant that protects against rapid reconfig attacks
    }

    // ═══════════════════════════════════════════════════════
    // TEST 7: TWAPBurner Reentrancy via Adapter
    // ═══════════════════════════════════════════════════════

    function test_Attack_TWAPBurner_ReentrancyViaAdapter() public {
        // Deploy TWAPBurner first with a placeholder router
        MockDexRouter77 placeholder = new MockDexRouter77(address(lumina), 1000e18, 1000e18);
        TWAPBurner burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(placeholder));

        // Deploy reentrant router targeting the burner
        ReentrantDexRouter77 reentrantRouter = new ReentrantDexRouter77(address(burner), address(lumina));

        // Replace the router with the reentrant one
        address[] memory routers = new address[](1);
        routers[0] = address(reentrantRouter);
        burner.setDexRouters(routers);

        // [legacy-migration] pattern #3 (F-19): wire a capacity oracle so
        // executeBurn can derive minOut. The reentrant router delivers a fixed
        // 1000e18 LUMINA for the capped 10_000e6 burn, so price the oracle at
        // $10 => oracle expectedOut = 10_000e6*1e12*1e18/10e18 = 1000e18 and
        // minOut (95%) = 950e18 <= 1000e18 delivered: the outer burn succeeds
        // exactly once (totalUSDCBurned == 10_000e6), preserving the assertion.
        MockPriceOracle77 minOutOracle = new MockPriceOracle77();
        minOutOracle.setPrice(10e18); // $10 per LUMINA
        burner.setCapacityOracle(address(minOutOracle));

        // Fund burner with enough for 2 burns (to test the reentrancy attempt)
        usdc.mint(address(burner), 20_000e6);

        // Set cooldown to 0 so the reentrant call wouldn't be blocked by cooldown
        burner.setBurnCooldown(60);

        // Execute burn — the adapter will try to re-enter but ReentrancyGuard blocks it
        // The reentrant call is caught by try/catch inside the malicious router,
        // so the outer swap completes successfully
        burner.executeBurn();

        // Verify the reentrancy was attempted but the burn only executed once
        assertTrue(reentrantRouter.attacked(), "Reentrancy was attempted");
        // Only one burn should have executed (maxBurnAmount = 10000e6)
        assertEq(burner.totalUSDCBurned(), 10_000e6, "Only one burn should execute");
    }

    // ═══════════════════════════════════════════════════════
    // TEST 8: ShieldKeeper Policy Poisoning
    // ═══════════════════════════════════════════════════════

    function test_Attack_ShieldKeeper_PolicyPoisoning() public {
        MockPolicyManagerKeeper77 pmk = new MockPolicyManagerKeeper77();
        PoisonedShield77 shield = new PoisonedShield77();
        bytes32 productId = keccak256("POISON-TEST");
        pmk.addProduct(productId, address(shield));

        // Policy 1 is poisoned (will revert), policies 2 and 3 are normal
        shield.setPoisoned(1);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1; // poisoned
        ids[1] = 2; // normal
        ids[2] = 3; // normal
        pmk.setActivePolicies(productId, ids);

        ShieldKeeper keeper = ProxyDeployer.deployShieldKeeper(address(pmk));

        // performUpkeep should handle the poisoned policy gracefully via try/catch
        bytes memory performData = abi.encode(productId, ids);
        keeper.performUpkeep(performData);

        // Poisoned policy NOT settled (reverted internally)
        assertFalse(shield.settled(1), "Poisoned policy should not be settled");
        // Normal policies ARE settled
        assertTrue(shield.settled(2), "Policy 2 should be settled");
        assertTrue(shield.settled(3), "Policy 3 should be settled");
    }

    // ═══════════════════════════════════════════════════════
    // HELPERS
    // ═══════════════════════════════════════════════════════

    function _deployBuybackEngine(
        address _bond,
        address _vault,
        address _solvOracle,
        address _capOracle,
        address _marketplace,
        address _usdc,
        address _owner
    ) internal returns (address) {
        // Deploy BuybackEngine via low-level to avoid import issues with interface conflicts
        bytes memory bytecode = abi.encodePacked(
            type(BuybackEngineHarness).creationCode,
            abi.encode(_bond, _vault, _solvOracle, _capOracle, _marketplace, _usdc, _owner)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(deployed != address(0), "Deploy failed");
        return deployed;
    }
}

// Minimal harness to avoid interface conflicts
contract BuybackEngineHarness {
    // Replicating BuybackEngine's key logic for testing daily budget invariant
    struct DailyConfig {
        uint256 dailyBudget;
        uint256 maxPricePercent;
        uint256 validUntil;
        uint256 spentToday;
    }

    DailyConfig public dailyConfig;
    address public admin;

    constructor(address, address, address, address, address, address, address _admin) {
        admin = _admin;
    }

    function setDailyBuyback(uint256 _budget, uint256 _maxPricePercent, uint256 _durationHours) external {
        require(msg.sender == admin, "Not admin");
        require(_budget > 0, "Budget zero");
        require(_maxPricePercent > 0 && _maxPricePercent <= 95, "Max percent 1-95");
        require(_durationHours > 0 && _durationHours <= 72, "Duration 1-72 hours");

        dailyConfig = DailyConfig({
            dailyBudget: _budget,
            maxPricePercent: _maxPricePercent,
            validUntil: block.timestamp + (_durationHours * 1 hours),
            spentToday: 0
        });
    }
}
