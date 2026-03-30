// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract DeployTimelock is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address gnosisSafe = vm.envAddress("GNOSIS_SAFE_ADDRESS");

        address[] memory proposers = new address[](1);
        proposers[0] = gnosisSafe;

        address[] memory executors = new address[](1);
        executors[0] = gnosisSafe;

        vm.startBroadcast(deployerKey);

        TimelockController timelock = new TimelockController(
            172800,     // 48 hours minimum delay
            proposers,  // only Gnosis Safe can propose
            executors,  // only Gnosis Safe can execute
            address(0)  // no admin — cannot bypass timelock
        );

        vm.stopBroadcast();

        console.log("TimelockController deployed at:", address(timelock));
        console.log("Min delay:", timelock.getMinDelay());
        console.log("Gnosis Safe (proposer + executor):", gnosisSafe);
    }
}
