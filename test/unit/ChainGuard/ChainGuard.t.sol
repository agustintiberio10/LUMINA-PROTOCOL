// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ChainGuard} from "../../../src/utils/ChainGuard.sol";

/// @notice Test wrapper exposing the library function for direct symbolic testing.
contract ChainGuardWrapper {
    function callRequireValidChain() external view {
        ChainGuard.requireValidChain();
    }
}

/// @title ChainGuardTest
/// @notice Sprint CC — whitelist tests for the chain id guard library.
contract ChainGuardTest is Test {
    ChainGuardWrapper wrapper;

    function setUp() public {
        wrapper = new ChainGuardWrapper();
    }

    // ─────────────── Happy paths ───────────────

    function test_RequireValidChain_BaseMainnet_OK() public {
        vm.chainId(8453);
        wrapper.callRequireValidChain(); // should not revert
    }

    function test_RequireValidChain_BaseSepolia_OK() public {
        vm.chainId(84532);
        wrapper.callRequireValidChain(); // should not revert
    }

    // ─────────────── Revert paths ───────────────

    function test_RequireValidChain_Ethereum_Reverts() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.InvalidChainId.selector, uint256(1), uint256(8453)));
        wrapper.callRequireValidChain();
    }

    function test_RequireValidChain_Arbitrum_Reverts() public {
        vm.chainId(42_161);
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.InvalidChainId.selector, uint256(42_161), uint256(8453)));
        wrapper.callRequireValidChain();
    }

    function test_RequireValidChain_RandomChain_Reverts() public {
        vm.chainId(99_999);
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.InvalidChainId.selector, uint256(99_999), uint256(8453)));
        wrapper.callRequireValidChain();
    }

    function test_RequireValidChain_FoundryDefault_Reverts() public {
        // Foundry default chain_id is 31337 (Anvil/Hardhat). Explicitly verify
        // the library rejects it — even though foundry.toml pins chain_id=84532
        // globally, this guards against a regression if someone removes that.
        vm.chainId(31_337);
        vm.expectRevert(abi.encodeWithSelector(ChainGuard.InvalidChainId.selector, uint256(31_337), uint256(8453)));
        wrapper.callRequireValidChain();
    }

    // ─────────────── Constants ───────────────

    function test_Constants_BaseMainnet_Is_8453() public pure {
        assertEq(ChainGuard.BASE_MAINNET, uint256(8453));
    }

    function test_Constants_BaseSepolia_Is_84532() public pure {
        assertEq(ChainGuard.BASE_SEPOLIA, uint256(84_532));
    }
}
