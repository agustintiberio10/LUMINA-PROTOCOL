// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";

contract MRM01MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// Minimal stubs so the router can be deployed behind a proxy. They are never
/// exercised by these tests (configureProduct never reaches a purchase path).
contract MRM01MockBurner {
    function receivePremium(uint256) external {}
}

contract MRM01MockPM {
    function recordPolicy(bytes32, address, uint256, uint256, uint32, bytes32) external pure returns (uint256) {
        return 1;
    }

    function triggerPayout(bytes32, uint256, bytes calldata) external {}
}

/// @notice MR-M01: configureProduct must enforce the payout-ratio coupling
///         invariant. The reserved payout (PolicyManagerV2: coverage*8000/10000)
///         and the shield payout (BaseFlashShield: coverage*80%) are both fixed
///         at 80%, so the ONLY consistent `payoutRatioBps` is 8000. Any other
///         value (bug-before) must revert; 8000 (no-after) must succeed.
contract MRM01PayoutRatioCouplingTest is Test {
    MRM01MockUSDC internal usdc;
    MRM01MockBurner internal burner;
    MRM01MockPM internal pm;
    CoverRouterV2 internal router;

    bytes32 internal constant PID = keccak256("FLASH-MRM01");

    function setUp() public {
        usdc = new MRM01MockUSDC();
        burner = new MRM01MockBurner();
        pm = new MRM01MockPM();

        router = ProxyDeployer.deployCoverRouterV2(address(usdc), address(pm), address(burner));
    }

    /// Bug-before: a 9000 bps payout ratio decoupled router pricing/payout from
    /// the hardcoded 80% reserve & shield payout. It must now revert.
    function test_ConfigureRevertsOnWrongPayoutRatio() external {
        vm.expectRevert(bytes("payoutRatioBps must be 8000 (==10000-deductible)"));
        router.configureProduct(PID, 9000, 20, 15000, 3600, true);
    }

    /// No-after: the canonical 8000 bps value still configures successfully.
    function test_ConfigureSucceedsAt8000() external {
        router.configureProduct(PID, 8000, 20, 15000, 3600, true);

        CoverRouterV2.ProductConfig memory cfg = router.getProductConfig(PID);
        assertEq(cfg.payoutRatioBps, 8000);
        assertEq(cfg.durationSeconds, uint32(3600));
        assertTrue(cfg.active);
    }

    /// The enforced constant equals 10000 - DEDUCTIBLE_BPS (2000) == 8000.
    function test_RequiredPayoutRatioConstant() external view {
        assertEq(router.REQUIRED_PAYOUT_RATIO_BPS(), 8000);
    }
}
