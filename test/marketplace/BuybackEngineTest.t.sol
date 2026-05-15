// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {BuybackEngine} from "../../src/marketplace/BuybackEngine.sol";
import {MockSolvencyOracle} from "../mocks/MockSolvencyOracle.sol";
import {MockCapacityOracleV5} from "../mocks/MockCapacityOracleV5.sol";
import {MockClaimBondV5} from "../mocks/MockClaimBondV5.sol";
import {MockBondVaultV5} from "../mocks/MockBondVaultV5.sol";
import {MockMarketplace} from "../mocks/MockMarketplace.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockUSDCBB {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract BuybackEngineTest is Test {
    using ProxyDeployer for *;

    BuybackEngine engine;
    MockClaimBondV5 claimBond;
    MockBondVaultV5 bondVault;
    MockSolvencyOracle solvencyOracle;
    MockCapacityOracleV5 capacityOracle;
    MockMarketplace marketplace;
    MockUSDCBB usdc;
    address multisig = makeAddr("multisig");

    function setUp() public {
        vm.chainId(8453);
        claimBond = new MockClaimBondV5();
        usdc = new MockUSDCBB();
        bondVault = new MockBondVaultV5(address(0x1));
        solvencyOracle = new MockSolvencyOracle();
        capacityOracle = new MockCapacityOracleV5();
        marketplace = new MockMarketplace();

        engine = ProxyDeployer.deployBuybackEngine(
            address(claimBond),
            address(bondVault),
            address(solvencyOracle),
            address(capacityOracle),
            address(marketplace),
            address(usdc),
            multisig
        );
    }

    function test_SetDailyBuyback_Success() public {
        usdc.mint(address(engine), 10000e6);
        vm.prank(multisig);
        engine.setDailyBuyback(10000e6, 60, 24);
        (uint256 budget,,,) = engine.dailyConfig();
        assertEq(budget, 10000e6);
    }

    function test_RevertIf_InvalidPercent() public {
        usdc.mint(address(engine), 10000e6);
        vm.prank(multisig);
        vm.expectRevert("Max percent 1-95");
        engine.setDailyBuyback(10000e6, 96, 24);
    }

    function test_RevertIf_InvalidDuration() public {
        usdc.mint(address(engine), 10000e6);
        vm.prank(multisig);
        vm.expectRevert("Duration 1-72 hours");
        engine.setDailyBuyback(10000e6, 60, 73);
    }

    function test_Constructor_RevertIfZero() public {
        BuybackEngine impl = new BuybackEngine();
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                BuybackEngine.initialize.selector,
                address(0),
                address(bondVault),
                address(solvencyOracle),
                address(capacityOracle),
                address(marketplace),
                address(usdc),
                multisig
            )
        );
    }

    function test_ExecuteOffer_RevertIf_OfferExpired() public {
        // Set daily config with short duration
        vm.prank(multisig);
        engine.setDailyBuyback(10000e6, 60, 1);
        // Warp past validUntil
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert("Daily offer expired");
        engine.executeOffer(0);
    }

    function test_GetDailyConfig_ReturnsCorrectValues() public {
        vm.prank(multisig);
        engine.setDailyBuyback(5000e6, 50, 48);
        (uint256 budget, uint256 maxPercent, uint256 validUntil, uint256 spent) = engine.dailyConfig();
        assertEq(budget, 5000e6);
        assertEq(maxPercent, 50);
        assertEq(validUntil, block.timestamp + 48 hours);
        assertEq(spent, 0);
    }

    function test_SetDailyBuyback_RevertIf_BudgetZero() public {
        vm.prank(multisig);
        vm.expectRevert("Budget zero");
        engine.setDailyBuyback(0, 60, 24);
    }

    function test_SetDailyBuyback_RevertIf_UnauthorizedRole() public {
        address random = makeAddr("random");
        vm.prank(random);
        vm.expectRevert();
        engine.setDailyBuyback(1000e6, 60, 24);
    }

    // ═══════ Sprint X.1 — listing-existence path tests ═══════

    /// @notice executeOffer reverts when called with a non-existent listingId.
    ///         MockMarketplace.getListing for an un-set id returns default
    ///         struct (active=false). The `require(active, "Listing not active")`
    ///         is the canonical existence check, so `seller` validation is
    ///         intentionally omitted.
    function test_ExecuteOffer_RevertIf_NonexistentListing() public {
        vm.prank(multisig);
        engine.setDailyBuyback(10000e6, 60, 24);

        // listingId 999 was never set on the mock → returns all zeros + active=false.
        vm.expectRevert(bytes("Listing not active"));
        engine.executeOffer(999);
    }

    /// @notice executeOffer reverts when listing exists but active=false.
    function test_ExecuteOffer_RevertIf_ListingInactive() public {
        vm.prank(multisig);
        engine.setDailyBuyback(10000e6, 60, 24);

        // Set listing with active=false explicitly.
        marketplace.setListing(7, makeAddr("seller"), 202804, 100, 50e6, false);

        vm.expectRevert(bytes("Listing not active"));
        engine.executeOffer(7);
    }
}
