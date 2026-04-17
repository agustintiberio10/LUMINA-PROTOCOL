// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../script/DeployLuminaWithSaltMining.s.sol";
import "../src/token/LuminaTokenV2.sol";

/// @title SaltMiningTest
/// @notice Validates the CREATE2 salt mining for LBL-H2 (LUMINA must be token0 in V3 pool).
contract SaltMiningTest is Test {
    DeployLuminaWithSaltMining deployer;
    address constant USDC_BASE = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function setUp() public {
        deployer = new DeployLuminaWithSaltMining();
    }

    /// @notice Salt mining produces a valid address < USDC_BASE
    function test_saltMining_producesValidAddress() public {
        // Use dummy constructor args (pairwise distinct)
        address bv = address(0x1001);
        address lbp = address(0x2002);
        address fv = address(0x3003);
        address tv = address(0x4004);

        (bytes32 salt, address predicted, uint256 iterations) = deployer.mineSalt(bv, lbp, fv, tv);

        // Core assertion: LUMINA address < USDC (so LUMINA is token0 in V3)
        assertTrue(predicted < USDC_BASE, "LUMINA address must be < USDC for token0");
        assertGt(iterations, 0, "Must have tried at least 1 salt");

        // Log for the report
        emit log_named_uint("Iterations", iterations);
        emit log_named_address("Predicted LUMINA", predicted);
        emit log_named_bytes32("Salt", salt);
    }

    /// @notice Verify the computed address matches what CREATE2 would actually deploy
    function test_saltMining_addressMatchesCreate2() public {
        address bv = address(0x1001);
        address lbp = address(0x2002);
        address fv = address(0x3003);
        address tv = address(0x4004);

        (, address predicted,) = deployer.mineSalt(bv, lbp, fv, tv);

        // Recompute manually using the salt from the first call
        (bytes32 salt2,,) = deployer.mineSalt(bv, lbp, fv, tv);

        bytes memory initCode = abi.encodePacked(type(LuminaTokenV2).creationCode, abi.encode(bv, lbp, fv, tv));
        bytes32 initCodeHash = keccak256(initCode);

        address manual = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(0x4e59b44847b379578588920cA78FbF26c0B4956C), salt2, initCodeHash
                        )
                    )
                )
            )
        );
        assertEq(predicted, manual, "Predicted must match manual CREATE2 computation");
    }

    /// @notice Iterations should be reasonable (< 10K for 50% probability of landing below USDC)
    function test_saltMining_reasonableIterations() public {
        address bv = address(0xA001);
        address lbp = address(0xB002);
        address fv = address(0xC003);
        address tv = address(0xD004);

        (,, uint256 iterations) = deployer.mineSalt(bv, lbp, fv, tv);

        // USDC_BASE starts with 0x83... → roughly 51% of random addresses are lower.
        // Expected iterations = ~2 (1 / 0.51). Should be well under 100.
        assertLt(iterations, 10_000, "Salt mining should not need >10K iterations");
    }
}
