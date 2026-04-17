// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/token/LuminaTokenV2.sol";

/// @title DeployLuminaWithSaltMining
/// @notice Mines a CREATE2 salt so that address(LuminaTokenV2) < USDC on Base.
/// @dev Guarantees the Uniswap V3 LUMINA/USDC pool has LUMINA as token0,
///      which is required by CapacityOracle's isToken0Lumina branch (LBL-H2).
///
///      Uses the canonical deterministic deployer at:
///      0x4e59b44847b379578588920cA78FbF26c0B4956C (available on Base).
///
///      Run: forge script script/DeployLuminaWithSaltMining.s.sol --rpc-url base --broadcast
contract DeployLuminaWithSaltMining is Script {
    /// @notice USDC on Base mainnet
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice Canonical deterministic deployer (Nick's method). Deployed on Base.
    address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Mine a salt that produces address(LuminaTokenV2) < USDC_BASE.
    /// @param bondVault The Bond Vault address
    /// @param lbpDeposit The LBP deposit address
    /// @param founderVesting The Founder Vesting address
    /// @param treasuryVesting The Treasury Vesting address
    /// @return salt The mined salt
    /// @return predicted The predicted deployment address
    /// @return iterations How many salts were tried
    function mineSalt(address bondVault, address lbpDeposit, address founderVesting, address treasuryVesting)
        public
        pure
        returns (bytes32 salt, address predicted, uint256 iterations)
    {
        // Compute the init code hash for LuminaTokenV2 with these constructor args
        bytes memory initCode = abi.encodePacked(
            type(LuminaTokenV2).creationCode, abi.encode(bondVault, lbpDeposit, founderVesting, treasuryVesting)
        );
        bytes32 initCodeHash = keccak256(initCode);

        // Iterate salts until we find one where predicted < USDC
        for (uint256 i = 0; i < 1_000_000; i++) {
            salt = bytes32(i);
            predicted = _computeCreate2Address(salt, initCodeHash);
            if (predicted < USDC_BASE) {
                iterations = i + 1;
                return (salt, predicted, iterations);
            }
        }

        revert("Salt mining failed after 1M iterations");
    }

    function run() external {
        // Read constructor params from environment or use defaults for testing
        address bondVault = vm.envOr("BOND_VAULT", address(0x1));
        address lbpDeposit = vm.envOr("LBP_DEPOSIT", address(0x2));
        address founderVesting = vm.envOr("FOUNDER_VESTING", address(0x3));
        address treasuryVesting = vm.envOr("TREASURY_VESTING", address(0x4));

        console.log("Mining salt for LuminaTokenV2...");
        console.log("Constraint: address(LUMINA) < USDC_BASE");
        console.log("USDC_BASE:", USDC_BASE);

        (bytes32 salt, address predicted, uint256 iterations) =
            mineSalt(bondVault, lbpDeposit, founderVesting, treasuryVesting);

        console.log("Salt found after iterations:", iterations);
        console.log("Salt:", uint256(salt));
        console.log("Predicted address:", predicted);

        // Hard assertion — abort if ordering invalid
        require(predicted < USDC_BASE, "LBL-H2: Pool ordering invalid - LUMINA must be token0");

        // If broadcasting, deploy via CREATE2
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            vm.startBroadcast();
            bytes memory initCode = abi.encodePacked(
                type(LuminaTokenV2).creationCode, abi.encode(bondVault, lbpDeposit, founderVesting, treasuryVesting)
            );
            // Deploy via CREATE2 factory: send salt + initCode as calldata
            (bool ok,) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(salt, initCode));
            require(ok, "CREATE2 deploy failed");
            vm.stopBroadcast();

            console.log("Deployed LuminaTokenV2 at:", predicted);
        }
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DETERMINISTIC_DEPLOYER, salt, initCodeHash))))
        );
    }
}
