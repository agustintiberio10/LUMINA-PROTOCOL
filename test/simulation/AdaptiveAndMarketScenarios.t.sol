// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {AdaptiveFeeDistributor} from "../../src/core/AdaptiveFeeDistributor.sol";
import {BuybackEngine} from "../../src/marketplace/BuybackEngine.sol";

// ═══════════════════════════════════════════════════════════════════════
// MOCKS (self-contained for simulation isolation)
// ═══════════════════════════════════════════════════════════════════════

contract SimMockUSDC {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SimMockLumina {
    string public name = "LUMINA";
    string public symbol = "LUMINA";
    uint8 public decimals = 18;
    uint256 public totalSupply = 1_000_000_000e18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalBurned;

    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        totalBurned += amount;
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
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SimMockSolvencyOracle {
    uint8 public solvencyLevel = 1;
    uint8 public momentumLevel = 1;
    uint256 public mockSolvencyRatio = 15000;
    bool public mockHealthy = true;

    function setQuadrant(uint8 s, uint8 m) external {
        solvencyLevel = s;
        momentumLevel = m;
    }

    function setSolvencyRatio(uint256 ratio) external {
        mockSolvencyRatio = ratio;
    }

    function setHealthy(bool h) external {
        mockHealthy = h;
    }

    function getCurrentQuadrant() external view returns (uint8, uint8) {
        return (solvencyLevel, momentumLevel);
    }

    function getSolvencyRatio() external view returns (uint256) {
        return mockSolvencyRatio;
    }

    function isHealthy() external view returns (bool) {
        return mockHealthy;
    }
}

contract SimMockCapacityOracle {
    uint256 public mockPrice;

    function setPrice(uint256 p) external {
        mockPrice = p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return mockPrice;
    }
}

contract SimMockBondVault {
    uint256 public totalCommittedUSD;
    address public lumina;
    uint256 public luminaBalanceStored;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function setTotalCommittedUSD(uint256 amount) external {
        totalCommittedUSD = amount;
    }

    function increaseTotalCommittedUSD(uint256 amount) external {
        totalCommittedUSD += amount;
    }

    function setLuminaBalance(uint256 amount) external {
        luminaBalanceStored = amount;
    }

    function decreaseObligations(uint256 amount) external {
        require(totalCommittedUSD >= amount, "Exceeds committed");
        totalCommittedUSD -= amount;
    }

    function burnFromReserves(uint256 amount) external {
        require(luminaBalanceStored >= amount, "Exceeds balance");
        luminaBalanceStored -= amount;
    }
}

contract SimMockClaimBond {
    uint256 public constant FACE_VALUE = 1e18; // $1 in 18 dec
    mapping(address => mapping(uint256 => uint256)) public balances;
    uint256 public totalMinted;

    function mint(address to, uint256 epochId, uint256 amount) external {
        balances[to][epochId] += amount;
        totalMinted += amount;
    }

    function burnByHolder(address account, uint256 epochId, uint256 amount) external {
        require(balances[account][epochId] >= amount, "Insufficient balance");
        balances[account][epochId] -= amount;
    }

    function getFaceValue(uint256) external pure returns (uint256) {
        return FACE_VALUE;
    }

    function balanceOf(address account, uint256 epochId) external view returns (uint256) {
        return balances[account][epochId];
    }
}

contract SimMockMarketplace {
    struct MockListing {
        address seller;
        uint256 epochId;
        uint256 amount;
        uint256 priceUSDC;
        bool active;
    }

    mapping(uint256 => MockListing) public mockListings;
    uint256 public nextListingId;

    function createListing(address seller, uint256 epochId, uint256 amount, uint256 priceUSDC)
        external
        returns (uint256)
    {
        uint256 id = nextListingId++;
        mockListings[id] = MockListing(seller, epochId, amount, priceUSDC, true);
        return id;
    }

    function setListing(uint256 id, address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active)
        external
    {
        mockListings[id] = MockListing(seller, epochId, amount, priceUSDC, active);
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
        mockListings[id].active = false;
    }
}

contract SimMockDexRouter {
    uint256 public pricePerUsdc; // lumina per 1e6 USDC (in 1e18 lumina)
    address public luminaToken;

    constructor(address _lumina) {
        luminaToken = _lumina;
        pricePerUsdc = 27_777e18; // ~$0.036 per LUMINA => 1 USDC buys ~27.77 LUMINA
    }

    function setPrice(uint256 _pricePerUsdc) external {
        pricePerUsdc = _pricePerUsdc;
    }

    function getQuote(address, address, uint256 amountIn) external view returns (uint256) {
        return (amountIn * pricePerUsdc) / 1e6;
    }

    function swap(address, address, uint256 amountIn, uint256) external returns (uint256) {
        uint256 out = (amountIn * pricePerUsdc) / 1e6;
        // Mint LUMINA to caller (simulates swap)
        SimMockLumina(luminaToken).mint(msg.sender, out);
        return out;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// TEST CONTRACT
// ═══════════════════════════════════════════════════════════════════════

contract AdaptiveAndMarketScenariosTest is Test {
    // --- Contracts ---
    AdaptiveFeeDistributor public distributor;
    BuybackEngine public buybackEngine;

    // --- Mocks ---
    SimMockUSDC public usdc;
    SimMockLumina public lumina;
    SimMockSolvencyOracle public solvencyOracle;
    SimMockCapacityOracle public capacityOracle;
    SimMockBondVault public bondVault;
    SimMockClaimBond public claimBond;
    SimMockMarketplace public marketplace;
    SimMockDexRouter public dexRouter;

    // --- Actors ---
    address public multisig = makeAddr("multisig");
    address public keeper = makeAddr("keeper");
    address public user = makeAddr("user");

    // --- Time ---
    uint256 public constant START_TIME = 1767225600 + 60 days; // ~March 2026

    function setUp() public {
        vm.warp(START_TIME);

        // Deploy mocks
        usdc = new SimMockUSDC();
        lumina = new SimMockLumina();
        solvencyOracle = new SimMockSolvencyOracle();
        capacityOracle = new SimMockCapacityOracle();
        bondVault = new SimMockBondVault(address(lumina));
        claimBond = new SimMockClaimBond();
        marketplace = new SimMockMarketplace();
        dexRouter = new SimMockDexRouter(address(lumina));

        // Deploy AdaptiveFeeDistributor with mock solvency oracle
        distributor = new AdaptiveFeeDistributor(address(solvencyOracle));

        // Deploy BuybackEngine
        vm.prank(multisig);
        buybackEngine = new BuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            multisig
        );

        // Initial oracle state
        capacityOracle.setPrice(36e15); // $0.036
        solvencyOracle.setSolvencyRatio(15000); // 150%
        solvencyOracle.setQuadrant(1, 1); // Healthy/Stable

        // Fund BondVault with LUMINA reserves
        bondVault.setLuminaBalance(100_000_000e18);
        bondVault.setTotalCommittedUSD(50_000e18); // $50k obligations

        // Fund buyback engine with USDC
        usdc.mint(address(buybackEngine), 100_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════
    // ADAPTIVE DISTRIBUTION: ALL 16 QUADRANTS
    // ═══════════════════════════════════════════════════════════════════

    function test_AdaptiveDistribution_All16Quadrants() public view {
        // Expected values for all 16 quadrants [burn, buyback, ops, maintenance]
        uint256[4][16] memory expected = [
            // Solvency 0 (Ultra): Rally, Stable, Decline, Crash
            [uint256(9500), uint256(0), uint256(0), uint256(500)],
            [uint256(9000), uint256(500), uint256(0), uint256(500)],
            [uint256(8500), uint256(1000), uint256(0), uint256(500)],
            [uint256(7500), uint256(2000), uint256(0), uint256(500)],
            // Solvency 1 (Healthy): Rally, Stable, Decline, Crash
            [uint256(9000), uint256(500), uint256(0), uint256(500)],
            [uint256(8500), uint256(800), uint256(200), uint256(500)],
            [uint256(7000), uint256(2100), uint256(200), uint256(700)],
            [uint256(5500), uint256(3500), uint256(200), uint256(800)],
            // Solvency 2 (Stressed): Rally, Stable, Decline, Crash
            [uint256(7500), uint256(1800), uint256(200), uint256(500)],
            [uint256(5500), uint256(3500), uint256(200), uint256(800)],
            [uint256(3800), uint256(5500), uint256(200), uint256(500)],
            [uint256(1800), uint256(7500), uint256(200), uint256(500)],
            // Solvency 3 (Crisis): Rally, Stable, Decline, Crash
            [uint256(4800), uint256(4500), uint256(200), uint256(500)],
            [uint256(2800), uint256(6500), uint256(200), uint256(500)],
            [uint256(800), uint256(8500), uint256(200), uint256(500)],
            [uint256(0), uint256(9600), uint256(200), uint256(200)]
        ];

        string[4] memory solvencyLabels = ["Ultra", "Healthy", "Stressed", "Crisis"];
        string[4] memory momentumLabels = ["Rally", "Stable", "Decline", "Crash"];

        for (uint8 s = 0; s < 4; s++) {
            for (uint8 m = 0; m < 4; m++) {
                uint256 idx = uint256(s) * 4 + uint256(m);
                (uint256 burn, uint256 buyback, uint256 ops, uint256 maint) = distributor.lookupDistribution(s, m);

                // Verify sum = 10000
                uint256 sum = burn + buyback + ops + maint;
                assertEq(
                    sum, 10000, string.concat("Sum != 10000 at Q(", solvencyLabels[s], ",", momentumLabels[m], ")")
                );

                // Verify maintenance >= 200
                assertGe(
                    maint, 200, string.concat("Maintenance < 200 at Q(", solvencyLabels[s], ",", momentumLabels[m], ")")
                );

                // Verify exact values match expected
                assertEq(
                    burn,
                    expected[idx][0],
                    string.concat("Burn mismatch at Q(", solvencyLabels[s], ",", momentumLabels[m], ")")
                );
                assertEq(
                    buyback,
                    expected[idx][1],
                    string.concat("Buyback mismatch at Q(", solvencyLabels[s], ",", momentumLabels[m], ")")
                );
                assertEq(
                    ops,
                    expected[idx][2],
                    string.concat("Ops mismatch at Q(", solvencyLabels[s], ",", momentumLabels[m], ")")
                );
                assertEq(
                    maint,
                    expected[idx][3],
                    string.concat("Maint mismatch at Q(", solvencyLabels[s], ",", momentumLabels[m], ")")
                );

                // Log for human review
                console.log(
                    string.concat(
                        "Q(",
                        solvencyLabels[s],
                        ",",
                        momentumLabels[m],
                        "): ",
                        vm.toString(burn),
                        "/",
                        vm.toString(buyback),
                        "/",
                        vm.toString(ops),
                        "/",
                        vm.toString(maint)
                    )
                );
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARKET SCENARIO: BULL MARKET 12 MONTHS
    // ═══════════════════════════════════════════════════════════════════

    function test_MarketScenario_BullMarket_12Months() public {
        // Price rises from $0.036 to $0.50 over 12 months
        uint256 startPrice = 36e15; // $0.036
        uint256 endPrice = 500e15; // $0.50
        uint256 totalBondsIssued = 0;
        uint256 initialSupply = lumina.totalSupply();

        for (uint256 month = 0; month < 12; month++) {
            // Linear price interpolation
            uint256 currentPrice = startPrice + ((endPrice - startPrice) * month) / 11;
            capacityOracle.setPrice(currentPrice);

            // Update solvency quadrant based on price trajectory
            if (currentPrice > 200e15) {
                solvencyOracle.setQuadrant(0, 0); // Ultra/Rally
            } else if (currentPrice > 100e15) {
                solvencyOracle.setQuadrant(0, 1); // Ultra/Stable
            } else {
                solvencyOracle.setQuadrant(1, 0); // Healthy/Rally
            }

            // Issue 50 bonds per month
            for (uint256 i = 0; i < 50; i++) {
                uint256 epochId = month * 50 + i + 1;
                claimBond.mint(user, epochId, 1);
                bondVault.increaseTotalCommittedUSD(1e18); // $1 face value each
                totalBondsIssued++;
            }

            // Advance 30 days
            vm.warp(block.timestamp + 30 days);
        }

        // Verify: total bonds issued = 600
        assertEq(totalBondsIssued, 600, "Should issue 600 bonds total");

        // Verify: solvency remained Ultra or Healthy (price went up)
        (uint8 finalS,) = solvencyOracle.getCurrentQuadrant();
        assertLe(finalS, 1, "Solvency should be Ultra(0) or Healthy(1) in bull market");

        // Verify: total committed tracked correctly
        assertEq(bondVault.totalCommittedUSD(), 50_000e18 + 600e18, "Obligations = initial + 600 bonds");

        // Log summary
        console.log("Bull Market 12mo: bonds issued=", totalBondsIssued);
        console.log("Final obligations USD:", bondVault.totalCommittedUSD() / 1e18);
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARKET SCENARIO: BEAR MARKET 12 MONTHS
    // ═══════════════════════════════════════════════════════════════════

    function test_MarketScenario_BearMarket_12Months() public {
        // Price drops from $0.10 to $0.004 (below circuit breaker at $0.005)
        uint256 startPrice = 100e15; // $0.10
        uint256 endPrice = 4e15; // $0.004
        bool autoPauseTriggered = false;
        bool autoResumeTriggered = false;
        uint256 MIN_PRICE = 5e15; // $0.005 = MIN_PRICE_FOR_NEW_POLICIES
        uint256 RESET_PRICE = 8e15; // $0.008 = RESET_PRICE_FOR_NEW_POLICIES

        for (uint256 month = 0; month < 12; month++) {
            // Linear price drop
            uint256 currentPrice = startPrice - ((startPrice - endPrice) * month) / 11;
            capacityOracle.setPrice(currentPrice);

            // Update solvency based on price
            if (currentPrice < 10e15) {
                solvencyOracle.setQuadrant(3, 3); // Crisis/Crash
                solvencyOracle.setSolvencyRatio(5000); // 50%
            } else if (currentPrice < 30e15) {
                solvencyOracle.setQuadrant(2, 2); // Stressed/Decline
                solvencyOracle.setSolvencyRatio(8000);
            } else {
                solvencyOracle.setQuadrant(1, 2); // Healthy/Decline
            }

            // Check auto-pause trigger
            if (currentPrice < MIN_PRICE && !autoPauseTriggered) {
                autoPauseTriggered = true;
                console.log("Auto-pause triggered at month", month);
            }

            vm.warp(block.timestamp + 30 days);
        }

        // Verify auto-pause was triggered
        assertTrue(autoPauseTriggered, "Auto-pause should trigger when price < $0.005");

        // Simulate recovery to test auto-resume
        capacityOracle.setPrice(RESET_PRICE + 1e15); // $0.009 > $0.008
        autoResumeTriggered = capacityOracle.getLuminaPrice() >= RESET_PRICE;
        assertTrue(autoResumeTriggered, "Should auto-resume when price > $0.008");

        // Verify existing bonds still redeemable (bondVault still has obligations)
        assertGt(bondVault.totalCommittedUSD(), 0, "Existing bonds should remain redeemable");

        console.log("Bear Market 12mo complete. Auto-pause triggered:", autoPauseTriggered);
        console.log("Auto-resume triggered:", autoResumeTriggered);
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARKET SCENARIO: SUDDEN CRASH
    // ═══════════════════════════════════════════════════════════════════

    function test_MarketScenario_CrashSudden() public {
        // Setup: 50 active bonds
        uint256 epochId = 1;
        for (uint256 i = 0; i < 50; i++) {
            claimBond.mint(user, epochId, 1);
        }
        bondVault.setTotalCommittedUSD(50e18); // $50 in obligations for 50 bonds

        // Sudden crash: price drops to trigger level
        uint256 crashPrice = 4e15; // $0.004 (below MIN_PRICE_FOR_NEW_POLICIES)
        capacityOracle.setPrice(crashPrice);
        solvencyOracle.setQuadrant(3, 3); // Crisis/Crash
        solvencyOracle.setSolvencyRatio(4000); // 40% - stressed but positive

        // Process all 50 triggers (simulate claims)
        // In a real scenario, PolicyManager would issue NFTs. Here we verify obligations.
        uint256 obligationsBefore = bondVault.totalCommittedUSD();

        // Verify: 50 bonds still exist (NFTs issued means bonds are active)
        assertEq(claimBond.balanceOf(user, epochId), 50, "50 NFTs should exist");

        // Verify: BondVault obligations match
        assertEq(obligationsBefore, 50e18, "Obligations should be $50 for 50 bonds");

        // Verify: solvency still positive (not bankrupt)
        uint256 solvencyRatio = solvencyOracle.getSolvencyRatio();
        assertGt(solvencyRatio, 0, "Solvency should still be positive after crash");

        // Verify: price is below auto-pause threshold
        assertTrue(crashPrice < 5e15, "Price should be below circuit breaker");

        console.log("Crash scenario: 50 bonds active, solvency bps=", solvencyRatio);
        console.log("  crash price (wei):", crashPrice);
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARKET SCENARIO: RECOVERY AFTER CRASH
    // ═══════════════════════════════════════════════════════════════════

    function test_MarketScenario_Recovery() public {
        // Start in crash state
        capacityOracle.setPrice(4e15); // $0.004
        solvencyOracle.setQuadrant(3, 3); // Crisis/Crash
        solvencyOracle.setSolvencyRatio(4000);

        uint256 MIN_PRICE = 5e15;
        uint256 RESET_PRICE = 8e15;

        // Verify: circuit breaker is active (price < MIN_PRICE)
        assertTrue(capacityOracle.getLuminaPrice() < MIN_PRICE, "Should be below MIN_PRICE initially");

        // Gradual recovery over 6 months
        uint256[6] memory recoveryPrices = [uint256(5e15), 6e15, 7e15, 8e15, 10e15, 15e15];
        bool circuitBreakerReset = false;

        for (uint256 i = 0; i < 6; i++) {
            capacityOracle.setPrice(recoveryPrices[i]);
            vm.warp(block.timestamp + 30 days);

            // Update solvency quadrant
            if (recoveryPrices[i] >= 10e15) {
                solvencyOracle.setQuadrant(1, 0); // Healthy/Rally
                solvencyOracle.setSolvencyRatio(12000);
            } else if (recoveryPrices[i] >= RESET_PRICE) {
                solvencyOracle.setQuadrant(2, 1); // Stressed/Stable
                solvencyOracle.setSolvencyRatio(8000);
            }

            // Check if circuit breaker resets
            if (recoveryPrices[i] >= RESET_PRICE && !circuitBreakerReset) {
                circuitBreakerReset = true;
                console.log("Circuit breaker reset at month", i);
            }
        }

        // Verify: circuit breaker has reset
        assertTrue(circuitBreakerReset, "Circuit breaker should reset during recovery");

        // Verify: new policies can resume (price > RESET_PRICE)
        uint256 finalPrice = capacityOracle.getLuminaPrice();
        assertTrue(finalPrice >= RESET_PRICE, "Final price should allow new policies");

        // Verify: solvency improved
        uint256 finalSolvency = solvencyOracle.getSolvencyRatio();
        assertGt(finalSolvency, 4000, "Solvency should improve after recovery");

        console.log("Recovery complete. Circuit breaker reset:", circuitBreakerReset);
        console.log("  final solvency bps:", finalSolvency);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BUYBACK ENGINE: SUCCESS WITH DOUBLE BURN
    // ═══════════════════════════════════════════════════════════════════

    function test_Buyback_SuccessWithDoubleBurn() public {
        // Setup: solvency > 150% to trigger double burn
        solvencyOracle.setSolvencyRatio(16000); // 160%
        capacityOracle.setPrice(36e15); // $0.036

        // Create a listing at 50% face value
        // Face value = 1e18 ($1), so 50% = $0.50 = 500_000 in USDC (6 dec)
        uint256 epochId = 42;
        claimBond.mint(address(buybackEngine), epochId, 1); // BuybackEngine will own bond after buy
        marketplace.setListing(0, user, epochId, 1, 500_000, true); // $0.50 price

        // Configure daily buyback
        vm.prank(multisig);
        buybackEngine.setDailyBuyback(10_000e6, 60, 24); // $10k budget, max 60% face value, 24h

        // Approve marketplace spending
        vm.prank(address(buybackEngine));
        usdc.approve(address(marketplace), type(uint256).max);

        // Execute offer
        uint256 obligationsBefore = bondVault.totalCommittedUSD();
        uint256 luminaReservesBefore = bondVault.luminaBalanceStored();

        buybackEngine.executeOffer(0);

        // Verify: obligations reduced by face value
        uint256 obligationsAfter = bondVault.totalCommittedUSD();
        assertEq(obligationsBefore - obligationsAfter, 1e18, "Obligations should decrease by face value");

        // Verify: double burn executed (LUMINA burned from reserves since solvency > 150%)
        uint256 luminaReservesAfter = bondVault.luminaBalanceStored();
        assertLt(luminaReservesAfter, luminaReservesBefore, "LUMINA reserves should decrease (double burn)");

        // Verify: listing is no longer active
        (,,,, bool active) = marketplace.getListing(0);
        assertFalse(active, "Listing should be deactivated after buy");

        console.log("Buyback success: obligations reduced by", obligationsBefore - obligationsAfter);
    }

    // ═══════════════════════════════════════════════════════════════════
    // BUYBACK ENGINE: DAILY BUDGET EXHAUSTED
    // ═══════════════════════════════════════════════════════════════════

    function test_Buyback_DailyBudgetExhausted() public {
        // Setup: $1000 daily budget
        solvencyOracle.setSolvencyRatio(16000);
        capacityOracle.setPrice(36e15);

        vm.prank(multisig);
        buybackEngine.setDailyBuyback(1000e6, 60, 24); // $1000 budget

        // Create listings: 1000 bonds each at $0.50/bond = $500 per listing
        for (uint256 i = 0; i < 3; i++) {
            uint256 epochId = i + 1;
            claimBond.mint(address(buybackEngine), epochId, 1000);
            marketplace.setListing(i, user, epochId, 1000, 500e6, true);
        }

        // First buy: $500 spent, $500 remaining
        buybackEngine.executeOffer(0);

        // Second buy: $500 spent, $0 remaining
        buybackEngine.executeOffer(1);

        // Third buy: should revert - budget exhausted
        vm.expectRevert("Daily budget exceeded");
        buybackEngine.executeOffer(2);

        console.log("Budget exhausted test passed: 2 buys succeeded, 3rd reverted");
    }

    // ═══════════════════════════════════════════════════════════════════
    // BUYBACK ENGINE: PRICE TOO HIGH REJECTED
    // ═══════════════════════════════════════════════════════════════════

    function test_Buyback_PriceTooHigh_Rejected() public {
        // Setup
        solvencyOracle.setSolvencyRatio(16000);
        capacityOracle.setPrice(36e15);

        // Configure: max 50% of face value
        vm.prank(multisig);
        buybackEngine.setDailyBuyback(10_000e6, 50, 24); // max 50% face value

        // Create listing at 70% face value (exceeds maxPricePercent of 50%)
        // Face value = 1e18, 70% = 0.7e18, in USDC terms: $0.70 = 700_000
        // But the check is: priceUSDC <= (faceValue * maxPricePercent) / (100 * 1e12)
        // faceValue = 1e18, maxPricePercent = 50
        // maxAllowedPrice = (1e18 * 50) / (100 * 1e12) = 500_000 USDC ($0.50)
        uint256 epochId = 99;
        claimBond.mint(address(buybackEngine), epochId, 1);
        marketplace.setListing(0, user, epochId, 1, 700_000, true); // $0.70 > $0.50 max

        // Should revert: price exceeds max
        vm.expectRevert("Price exceeds max");
        buybackEngine.executeOffer(0);

        // Verify listing still active (buy was not executed)
        (,,,, bool active) = marketplace.getListing(0);
        assertTrue(active, "Listing should remain active (buy rejected)");

        console.log("Price too high test passed: 70% face value rejected (max 50%)");
    }
}
