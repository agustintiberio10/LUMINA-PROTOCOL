// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract TransferOwnership is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        // All contracts that need ownership transfer
        address[] memory contracts = new address[](12);
        contracts[0] = vm.envAddress("COVER_ROUTER");
        contracts[1] = vm.envAddress("POLICY_MANAGER");
        contracts[2] = vm.envAddress("ORACLE");
        contracts[3] = vm.envAddress("PHALA");
        contracts[4] = vm.envAddress("VAULT_VOL_SHORT");
        contracts[5] = vm.envAddress("VAULT_VOL_LONG");
        contracts[6] = vm.envAddress("VAULT_STABLE_SHORT");
        contracts[7] = vm.envAddress("VAULT_STABLE_LONG");
        contracts[8] = vm.envAddress("SHIELD_BSS");
        contracts[9] = vm.envAddress("SHIELD_DEPEG");
        contracts[10] = vm.envAddress("SHIELD_IL");
        contracts[11] = vm.envAddress("SHIELD_EXPLOIT");

        vm.startBroadcast(deployerKey);

        for (uint256 i = 0; i < contracts.length; i++) {
            OwnableUpgradeable(contracts[i]).transferOwnership(timelock);
            console.log("Transferred ownership:", contracts[i], "->", timelock);
        }

        vm.stopBroadcast();
    }
}
