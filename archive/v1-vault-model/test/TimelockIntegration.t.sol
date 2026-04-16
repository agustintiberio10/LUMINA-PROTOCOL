// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import {LuminaOracle} from "../src/oracles/LuminaOracle.sol";

contract TimelockIntegrationTest is Test {
    TimelockController timelock;
    LuminaOracle oracle;

    address gnosisSafe = address(0x5AFE);
    address deployer = address(this);
    address newOracleKey = address(0x1234);

    uint256 constant MIN_DELAY = 48 hours;

    function setUp() public {
        // Deploy timelock with gnosisSafe as proposer + executor
        address[] memory proposers = new address[](1);
        proposers[0] = gnosisSafe;
        address[] memory executors = new address[](1);
        executors[0] = gnosisSafe;

        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        // Deploy oracle owned by deployer
        oracle = new LuminaOracle(deployer, deployer, address(0));

        // Transfer ownership to timelock
        oracle.transferOwnership(address(timelock));
    }

    function test_timelockDeployedCorrectly() public {
        assertEq(timelock.getMinDelay(), MIN_DELAY);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), gnosisSafe));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), gnosisSafe));
    }

    function test_ownershipTransferred() public {
        assertEq(oracle.owner(), address(timelock));
    }

    function test_oldOwnerCannotCallAdmin() public {
        vm.expectRevert();
        oracle.setOracleKey(newOracleKey);
    }

    function test_proposeAndExecuteAfterDelay() public {
        // Encode the call: oracle.setOracleKey(newOracleKey)
        bytes memory data = abi.encodeWithSelector(LuminaOracle.setOracleKey.selector, newOracleKey);

        // Propose (as gnosisSafe)
        vm.prank(gnosisSafe);
        timelock.schedule(
            address(oracle),
            0,
            data,
            bytes32(0),
            bytes32(uint256(1)), // salt
            MIN_DELAY
        );

        // Try to execute before delay — should fail
        vm.prank(gnosisSafe);
        vm.expectRevert();
        timelock.execute(address(oracle), 0, data, bytes32(0), bytes32(uint256(1)));

        // Warp past delay
        vm.warp(block.timestamp + MIN_DELAY + 1);

        // Execute — should succeed
        vm.prank(gnosisSafe);
        timelock.execute(address(oracle), 0, data, bytes32(0), bytes32(uint256(1)));

        // Verify oracle key changed
        assertEq(oracle.oracleKey(), newOracleKey);
    }

    function test_executeBeforeDelayReverts() public {
        bytes memory data = abi.encodeWithSelector(LuminaOracle.setOracleKey.selector, newOracleKey);

        vm.prank(gnosisSafe);
        timelock.schedule(address(oracle), 0, data, bytes32(0), bytes32(uint256(2)), MIN_DELAY);

        // Only 1 hour passed — not enough
        vm.warp(block.timestamp + 1 hours);

        vm.prank(gnosisSafe);
        vm.expectRevert();
        timelock.execute(address(oracle), 0, data, bytes32(0), bytes32(uint256(2)));
    }

    function test_nonProposerCannotSchedule() public {
        bytes memory data = abi.encodeWithSelector(LuminaOracle.setOracleKey.selector, newOracleKey);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        timelock.schedule(address(oracle), 0, data, bytes32(0), bytes32(uint256(3)), MIN_DELAY);
    }

    function test_nonExecutorCannotExecute() public {
        bytes memory data = abi.encodeWithSelector(LuminaOracle.setOracleKey.selector, newOracleKey);

        vm.prank(gnosisSafe);
        timelock.schedule(address(oracle), 0, data, bytes32(0), bytes32(uint256(4)), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY + 1);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        timelock.execute(address(oracle), 0, data, bytes32(0), bytes32(uint256(4)));
    }
}
