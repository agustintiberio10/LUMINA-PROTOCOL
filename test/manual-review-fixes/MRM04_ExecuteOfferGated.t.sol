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
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev Minimal USDC mock mirroring the pattern in BuybackEngineTest.t.sol.
contract MockUSDCMRM04 {
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

/// @title MRM04_ExecuteOfferGated
/// @notice [MR-M04 fix] Verifies executeOffer is now gated behind
///         BUYBACK_OPERATOR_ROLE. Before the fix, executeOffer was permissionless
///         (`external nonReentrant`), so any seller could self-execute. After the
///         fix:
///           - a NON-operator calling executeOffer REVERTS with an AccessControl
///             error (the "no-after" assertion), and
///           - the OPERATOR (granted BUYBACK_OPERATOR_ROLE) can STILL call it
///             successfully (the authorized "bug-before" path is preserved).
contract MRM04_ExecuteOfferGatedTest is Test {
    using ProxyDeployer for *;

    BuybackEngine engine;
    MockClaimBondV5 claimBond;
    MockBondVaultV5 bondVault;
    MockSolvencyOracle solvencyOracle;
    MockCapacityOracleV5 capacityOracle;
    MockMarketplace marketplace;
    MockUSDCMRM04 usdc;

    address multisig = makeAddr("multisig"); // gets DEFAULT_ADMIN + BUYBACK_OPERATOR on init
    address attacker = makeAddr("attacker"); // a non-operator (e.g. a self-dealing seller)

    uint256 constant LISTING_ID = 1;
    uint256 constant EPOCH_ID = 202805;
    uint256 constant AMOUNT = 100;
    // faceValue = 1e18 per bond * 100 = 100e18; maxPrice% = 60 →
    // maxAllowedPriceUSDC = (100e18 * 60) / (100 * 1e12) = 60e6. Keep price under cap.
    uint256 constant PRICE_USDC = 50e6;

    function setUp() public {
        vm.chainId(8453);
        claimBond = new MockClaimBondV5();
        usdc = new MockUSDCMRM04();
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

        // Operator opens a budget window large enough to cover the offer.
        vm.prank(multisig);
        engine.setDailyBuyback(10_000e6, 60, 24);

        // Active, in-cap listing the engine can buy.
        marketplace.setListing(LISTING_ID, attacker, EPOCH_ID, AMOUNT, PRICE_USDC, true);

        // Engine holds the bonds so claimBond.burnByHolder(address(this), ...) succeeds.
        claimBond.mint(address(engine), EPOCH_ID, AMOUNT);

        // Fund the engine's USDC (marketplace fee is 0 in the mock; approval path).
        usdc.mint(address(engine), 10_000e6);

        // Drive solvency BELOW MIN_SOLVENCY_FOR_DOUBLE_BURN (15000) so the
        // double-burn takes the circuit-breaker branch and we don't have to
        // configure the capacity oracle price / vault reserve balance. The role
        // gate — not the burn sizing — is what this test exercises.
        solvencyOracle.setSolvencyRatio(14000);
    }

    /// @notice [MR-M04 no-after] A non-operator can no longer execute offers.
    function test_ExecuteOffer_RevertIf_NotOperator() public {
        // Cache the role BEFORE pranking: `engine.BUYBACK_OPERATOR_ROLE()` is an
        // external call and would otherwise consume the prank, leaving the
        // executeOffer call to run as address(this) instead of `attacker`.
        bytes32 role = engine.BUYBACK_OPERATOR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role)
        );
        vm.prank(attacker);
        engine.executeOffer(LISTING_ID);
    }

    /// @notice [MR-M04 authorized path preserved] The operator can still execute.
    function test_ExecuteOffer_OperatorStillSucceeds() public {
        // Sanity: multisig holds the operator role granted at init.
        assertTrue(engine.hasRole(engine.BUYBACK_OPERATOR_ROLE(), multisig));

        vm.prank(multisig);
        engine.executeOffer(LISTING_ID);

        // Offer consumed: listing deactivated and budget spend recorded.
        (,,,, bool active) = marketplace.getListing(LISTING_ID);
        assertFalse(active, "listing should be deactivated after buy");
        // Marketplace fee is 0 in the mock, so spend == priceUSDC.
        assertEq(engine.spentThisWindow(), PRICE_USDC, "window spend should equal price");
    }
}
