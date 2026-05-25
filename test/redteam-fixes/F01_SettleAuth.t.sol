// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {CoverRouterV2} from "../../src/core/CoverRouterV2.sol";

contract F01MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract F01MockBurner {
    function receivePremium(uint256) external {}
}

/// PM that records whether triggerPayout was reached.
contract F01MockPM {
    bool public triggered;

    function recordPolicy(bytes32, address, uint256, uint256, uint32, bytes32) external pure returns (uint256) {
        return 1;
    }

    function triggerPayout(bytes32, uint256, bytes calldata) external {
        triggered = true;
    }
}

/// @notice F-01: submitTrigger (the settlement entrypoint) must be restricted
///         to authorized relayers (or owner), not permissionless.
contract F01SettleAuthTest is Test {
    F01MockUSDC internal usdc;
    F01MockBurner internal burner;
    F01MockPM internal pm;
    CoverRouterV2 internal router;

    bytes32 internal constant PID = keccak256("FLASH-1");
    address internal constant RELAYER = address(0xAbCd);
    address internal constant ATTACKER = address(0xBaD);

    function setUp() public {
        vm.chainId(8453);
        usdc = new F01MockUSDC();
        burner = new F01MockBurner();
        pm = new F01MockPM();
        router = ProxyDeployer.deployCoverRouterV2(address(usdc), address(pm), address(burner));
        router.setRelayer(RELAYER, true);
    }

    function test_SubmitTriggerOnlyRelayer() external {
        // Unauthorized caller reverts.
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.NotAuthorizedRelayer.selector, ATTACKER));
        router.submitTrigger(PID, 1, "");

        assertFalse(pm.triggered(), "trigger must not have reached PM");

        // Authorized relayer succeeds.
        vm.prank(RELAYER);
        router.submitTrigger(PID, 1, "");
        assertTrue(pm.triggered(), "relayer can settle");
    }

    function test_OwnerCanSettle() external {
        // Owner (this test contract is the deployer/owner) can settle too.
        router.submitTrigger(PID, 1, "");
        assertTrue(pm.triggered(), "owner can settle");
    }

    function test_RevokedRelayerCannotSettle() external {
        router.setRelayer(RELAYER, false);
        vm.prank(RELAYER);
        vm.expectRevert(abi.encodeWithSelector(CoverRouterV2.NotAuthorizedRelayer.selector, RELAYER));
        router.submitTrigger(PID, 1, "");
    }
}
