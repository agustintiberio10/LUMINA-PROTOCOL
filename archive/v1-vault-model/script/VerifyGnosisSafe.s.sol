// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

interface IGnosisSafe {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
}

contract VerifyGnosisSafe is Script {
    function run() external view {
        address safe = vm.envAddress("GNOSIS_SAFE_ADDRESS");
        IGnosisSafe gnosis = IGnosisSafe(safe);

        address[] memory owners = gnosis.getOwners();
        uint256 threshold = gnosis.getThreshold();

        console.log("Safe address:", safe);
        console.log("Threshold:", threshold);
        console.log("Total owners:", owners.length);

        for (uint256 i = 0; i < owners.length; i++) {
            console.log("  Owner", i + 1, ":", owners[i]);
        }

        require(threshold >= 2, "Threshold too low");
        require(owners.length >= 3, "Need at least 3 owners");
        console.log("VERIFICATION: PASSED");
    }
}
