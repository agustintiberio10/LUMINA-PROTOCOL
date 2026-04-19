// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../../src/marketplace/BuybackEngine.sol";

// ═══════ MINIMAL MOCKS ═══════

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockClaimBondBuyback {
    uint256 public constant FACE_VALUE = 1e18; // $1 per token in 18-dec

    function getFaceValue(uint256) external pure returns (uint256) {
        return FACE_VALUE;
    }

    function burnByHolder(address, uint256, uint256) external pure {
        // no-op for mock
    }
}

contract MockBondVaultBuyback {
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function decreaseObligations(uint256) external pure {
        // no-op
    }

    function burnFromReserves(uint256) external pure {
        // no-op
    }
}

contract MockSolvencyOracleBuyback {
    uint256 public ratio = 15000;

    function setSolvencyRatio(uint256 r) external {
        ratio = r;
    }

    function getSolvencyRatio() external view returns (uint256) {
        return ratio;
    }
}

contract MockCapacityOracleBuyback {
    uint256 public price = 0.036e18;

    function setPrice(uint256 p) external {
        price = p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

contract MockMarketplaceBuyback {
    struct MockListing {
        address seller;
        uint256 epochId;
        uint256 amount;
        uint256 priceUSDC;
        bool active;
    }

    mapping(uint256 => MockListing) public mockListings;

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

// ═══════ TEST CONTRACT ═══════

contract BuybackFlowTest is Test {
    BuybackEngine engine;
    MockUSDC usdc;
    MockClaimBondBuyback claimBond;
    MockBondVaultBuyback bondVault;
    MockSolvencyOracleBuyback solvencyOracle;
    MockCapacityOracleBuyback capacityOracle;
    MockMarketplaceBuyback marketplace;

    address multisig = makeAddr("multisig");

    function setUp() public {
        // Warp to a sane base time (Jan 1 2026 + 30 days)
        vm.warp(1767225600 + 30 days);

        usdc = new MockUSDC();
        claimBond = new MockClaimBondBuyback();
        bondVault = new MockBondVaultBuyback(address(0));
        solvencyOracle = new MockSolvencyOracleBuyback();
        capacityOracle = new MockCapacityOracleBuyback();
        marketplace = new MockMarketplaceBuyback();

        engine = new BuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            multisig
        );
    }

    // ─── Test 1: setDailyBuyback reverts before ACTIVATION_DELAY (365 days) ───

    function test_Flow_Buyback_NotActiveBefore365Days() public {
        assertFalse(engine.isActivated(), "Should not be activated yet");
        assertTrue(engine.timeUntilActivation() > 0, "Activation time remaining");

        vm.prank(multisig);
        vm.expectRevert("Not yet activated");
        engine.setDailyBuyback(1000e6, 80, 24);
    }

    // ─── Test 2: setDailyBuyback succeeds after ACTIVATION_DELAY ───

    function test_Flow_Buyback_ActiveAfter365Days() public {
        uint256 delay = engine.ACTIVATION_DELAY();
        assertEq(delay, 365 days, "ACTIVATION_DELAY should be 365 days");

        // Warp past activation delay
        vm.warp(block.timestamp + delay + 1);
        assertTrue(engine.isActivated(), "Should be activated");
        assertEq(engine.timeUntilActivation(), 0, "No time remaining");

        vm.prank(multisig);
        engine.setDailyBuyback(5000e6, 80, 24);

        (uint256 dailyBudget, uint256 maxPricePercent, uint256 validUntil, uint256 spentToday) = engine.dailyConfig();
        assertEq(dailyBudget, 5000e6, "Budget mismatch");
        assertEq(maxPricePercent, 80, "MaxPricePercent mismatch");
        assertGt(validUntil, block.timestamp, "validUntil should be in the future");
        assertEq(spentToday, 0, "No spending yet");
    }

    // ─── Test 3: Daily budget is respected — exhausts budget then reverts ───

    function test_Flow_Buyback_DailyBudgetRespected() public {
        // Activate
        vm.warp(block.timestamp + engine.ACTIVATION_DELAY() + 1);

        // Configure: 100 USDC daily budget, 90% max price, 24h validity
        vm.prank(multisig);
        engine.setDailyBuyback(100e6, 90, 24);

        // Create a listing: 100 bonds @ 40 USDC (each bond face value = 1e18 = $1)
        // faceValueUSD = 1e18 * 100 = 100e18
        // maxAllowedPriceUSDC = (100e18 * 90) / (100 * 1e12) = 90e6
        // 40e6 < 90e6 so price check passes
        marketplace.setListing(0, makeAddr("seller"), 202804, 100, 40e6, true);

        // Fund engine with USDC for marketplace purchase
        usdc.mint(address(engine), 200e6);

        // First buy succeeds (spentToday: 0 + 40e6 = 40e6 <= 100e6)
        engine.executeOffer(0);

        // Create second listing that would exceed budget (40e6 + 70e6 = 110e6 > 100e6)
        marketplace.setListing(1, makeAddr("seller"), 202804, 100, 70e6, true);

        // Second buy reverts (spentToday: 40e6 + 70e6 = 110e6 > 100e6)
        vm.expectRevert("Daily budget exceeded");
        engine.executeOffer(1);
    }

    // ─── Test 4: Expiration is respected ───

    function test_Flow_Buyback_ExpirationRespected() public {
        // Activate
        vm.warp(block.timestamp + engine.ACTIVATION_DELAY() + 1);

        // Configure with 1-hour duration
        vm.prank(multisig);
        engine.setDailyBuyback(10_000e6, 90, 1);

        // Warp past validity window
        vm.warp(block.timestamp + 2 hours);

        marketplace.setListing(0, makeAddr("seller"), 202804, 10, 5e6, true);
        usdc.mint(address(engine), 10e6);

        vm.expectRevert("Daily offer expired");
        engine.executeOffer(0);
    }
}
