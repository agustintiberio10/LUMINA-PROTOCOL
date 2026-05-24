// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";

contract F23MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Minimal stubs so _purchase can reach the coverage-ceiling check and (for the
/// happy path) complete a record.
contract F23MockBurner {
    function receivePremium(uint256) external {}
}

contract F23MockPM {
    function recordPolicy(bytes32, address, uint256, uint256, uint32, bytes32) external pure returns (uint256) {
        return 1;
    }

    function triggerPayout(bytes32, uint256, bytes calldata) external {}
}

/// @notice F-23: per-policy coverage ceiling of $10,000 must be enforced.
contract F23MaxCoverageTest is Test {
    F23MockUSDC internal usdc;
    F23MockBurner internal burner;
    F23MockPM internal pm;
    CoverRouterV2 internal router;

    bytes32 internal constant PID = keccak256("FLASH-1");
    address internal constant BUYER = address(0xB1);

    function setUp() public {
        vm.chainId(8453);
        usdc = new F23MockUSDC();
        burner = new F23MockBurner();
        pm = new F23MockPM();

        router = ProxyDeployer.deployCoverRouterV2(address(usdc), address(pm), address(burner));
        // No capacityOracle set => auto-pause check skipped.

        router.configureProduct(PID, 8000, 20, 15000, 3600, true);

        usdc.mint(BUYER, 1_000_000e6);
        vm.prank(BUYER);
        usdc.approve(address(router), type(uint256).max);
    }

    function test_CoverageCeilingEnforced() external {
        // Exactly at the cap ($10,000) is allowed.
        vm.prank(BUYER);
        router.purchasePolicy(PID, 10_000e6, "BTC");

        // One unit over the cap reverts with InvalidCoverage.
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.InvalidCoverage.selector, uint256(10_000e6 + 1)));
        router.purchasePolicy(PID, 10_000e6 + 1, "BTC");

        // A clearly excessive value also reverts.
        vm.prank(BUYER);
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.InvalidCoverage.selector, uint256(1_000_000e6)));
        router.purchasePolicy(PID, 1_000_000e6, "BTC");
    }

    function test_MaxCoverageConstant() external view {
        assertEq(router.MAX_COVERAGE_PER_POLICY(), 10_000e6);
    }
}
