// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DepegShield} from "../src/products/DepegShield.sol";
import {ExploitShield} from "../src/products/ExploitShield.sol";
import {IShield} from "../src/interfaces/IShield.sol";

/// @notice Minimal mock oracle that satisfies the IOracle interface
contract MockOracle {
    address public oracleKey;

    constructor(address _key) {
        oracleKey = _key;
    }

    function getLatestPrice(bytes32) external pure returns (int256) {
        return 100_000_000; // $1.00
    }

    function verifySignature(bytes32, bytes calldata) external view returns (address) {
        return oracleKey;
    }
}

/// @notice Minimal mock Phala verifier
contract MockPhalaVerifier {
    function verifyAttestation(bytes32, bytes calldata) external pure returns (bool) {
        return true;
    }
}

contract ExclusionsTest is Test {
    DepegShield depegShield;
    ExploitShield exploitShield;

    address router = address(0xD);
    address oracleKey = address(0xAA);
    MockOracle oracle;
    MockPhalaVerifier phalaVerifier;

    function setUp() public {
        oracle = new MockOracle(oracleKey);
        phalaVerifier = new MockPhalaVerifier();

        depegShield = new DepegShield(router, address(oracle));
        exploitShield = new ExploitShield(router, address(oracle), address(phalaVerifier));
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: DepegShield rejects USDC (settlement token exclusion)
    // ═══════════════════════════════════════════════════════════

    function test_depegShieldRejectsUSDC() public {
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: address(0xBEEF),
            coverageAmount: 1000e6,
            premiumAmount: 50e6,
            durationSeconds: 30 days,
            asset: bytes32(0),
            stablecoin: "USDC", // Excluded — USDC is the settlement token
            protocol: address(0),
            extraData: ""
        });

        // Call as router (onlyRouter modifier)
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(DepegShield.ExcludedStablecoin.selector, bytes32("USDC")));
        depegShield.createPolicy(params);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: ExploitShield rejects Aave V3 (circular risk exclusion)
    // ═══════════════════════════════════════════════════════════

    function test_exploitShieldRejectsAave() public {
        // The excluded address is the Aave V3 Pool on Base
        address aaveV3Pool = 0xA238Dd80C259A72E81D7E4674A5471b2F0730305;

        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: address(0xBEEF),
            coverageAmount: 10_000e6,
            premiumAmount: 500e6,
            durationSeconds: 90 days,
            asset: bytes32(0),
            stablecoin: bytes32(0),
            protocol: aaveV3Pool, // Excluded — vault funds are in Aave
            extraData: hex"01" // tier = 1
        });

        // Call as router (onlyRouter modifier)
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(ExploitShield.ExcludedProtocol.selector, aaveV3Pool));
        exploitShield.createPolicy(params);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: DepegShield accepts DAI (non-excluded stablecoin)
    // ═══════════════════════════════════════════════════════════

    function test_depegShieldAcceptsDAI() public {
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: address(0xBEEF),
            coverageAmount: 1000e6,
            premiumAmount: 50e6,
            durationSeconds: 30 days,
            asset: bytes32(0),
            stablecoin: "DAI", // NOT excluded
            protocol: address(0),
            extraData: ""
        });

        // Should succeed (not revert with ExcludedStablecoin)
        vm.prank(router);
        uint256 policyId = depegShield.createPolicy(params);
        assertGt(policyId, 0, "Policy should be created for DAI");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: ExploitShield accepts non-Aave protocol
    // ═══════════════════════════════════════════════════════════

    function test_exploitShieldAcceptsCompound() public {
        address compoundAddr = address(0xC0FEED); // any non-Aave address

        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: address(0xBEEF),
            coverageAmount: 10_000e6,
            premiumAmount: 500e6,
            durationSeconds: 90 days,
            asset: bytes32(0),
            stablecoin: bytes32(0),
            protocol: compoundAddr, // NOT excluded
            extraData: hex"01" // tier = 1
        });

        // Should succeed
        vm.prank(router);
        uint256 policyId = exploitShield.createPolicy(params);
        assertGt(policyId, 0, "Policy should be created for non-Aave protocol");
    }
}
