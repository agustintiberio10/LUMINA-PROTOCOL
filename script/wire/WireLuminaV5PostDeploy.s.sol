// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

// ═══════════════════════════════════════════════════════════════════════
// Minimal interfaces for post-deploy wiring operations
// ═══════════════════════════════════════════════════════════════════════

interface IPolicyManagerWire {
    function registerProduct(bytes32 productId, address shield) external;
    function deactivateProduct(bytes32 productId) external;
    function setRouter(address router) external;
}

interface ICoverRouterWire {
    function configureProduct(
        bytes32 productId,
        uint256 payoutRatioBps,
        uint256 triggerProbBps,
        uint256 marginBps,
        uint32 durationSeconds,
        bool active
    ) external;
    function setTwapBurner(address burner) external;
}

interface ITWAPBurnerWire {
    function setFeeDistributor(address feeDistributor) external;
}

interface IBuybackEngineWire {
    function grantRole(bytes32 role, address account) external;
}

interface IOwnableWire {
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
}

interface IAccessControlWire {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title WireLuminaV5PostDeploy
/// @notice Utility script for post-deploy reconfiguration of LUMINA Protocol V5.0.
/// @dev Each function is a standalone broadcast operation. No single `run()` entry point.
///      Intended for targeted administrative operations via Gnosis Safe or deployer.
///
///      Example usage:
///        forge script script/wire/WireLuminaV5PostDeploy.s.sol \
///          --sig "addShield(address,address,address,bytes32,uint256,uint256,uint256,uint32)" \
///          $POLICY_MANAGER $COVER_ROUTER $SHIELD $PRODUCT_ID $PAYOUT $PROB $MARGIN $DURATION \
///          --rpc-url $RPC --broadcast
contract WireLuminaV5PostDeploy is Script {
    // ═══════════════════════════════════════════════════════════════════
    // ADD SHIELD
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Register a new shield in PolicyManager and configure its product in CoverRouter.
    /// @param policyManager Address of PolicyManagerV2
    /// @param coverRouter Address of CoverRouterV2
    /// @param shield Address of the shield contract
    /// @param productId Product identifier (e.g., keccak256("FLASHBTC1H-001"))
    /// @param payoutRatioBps Payout ratio in bps (e.g., 8000 = 80%)
    /// @param triggerProbBps Trigger probability in bps (e.g., 20 = 0.20%)
    /// @param marginBps Margin multiplier in bps (e.g., 15000 = 1.50x)
    /// @param durationSeconds Policy duration in seconds
    function addShield(
        address policyManager,
        address coverRouter,
        address shield,
        bytes32 productId,
        uint256 payoutRatioBps,
        uint256 triggerProbBps,
        uint256 marginBps,
        uint32 durationSeconds
    ) external {
        console2.log("=== Add Shield ===");
        console2.log("PolicyManager:", policyManager);
        console2.log("CoverRouter:", coverRouter);
        console2.log("Shield:", shield);
        console2.log("Duration (seconds):", uint256(durationSeconds));

        vm.startBroadcast();

        // 1. Register product in PolicyManager
        IPolicyManagerWire(policyManager).registerProduct(productId, shield);
        console2.log("[OK] Product registered in PolicyManager");

        // 2. Configure product pricing in CoverRouter
        ICoverRouterWire(coverRouter)
            .configureProduct(productId, payoutRatioBps, triggerProbBps, marginBps, durationSeconds, true);
        console2.log("[OK] Product configured in CoverRouter (active=true)");

        vm.stopBroadcast();

        console2.log("=== Shield Added Successfully ===");
    }

    // ═══════════════════════════════════════════════════════════════════
    // REMOVE SHIELD
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Deactivate a shield (soft removal). Does not delete, only marks inactive.
    /// @param policyManager Address of PolicyManagerV2
    /// @param productId Product identifier to deactivate
    function removeShield(address policyManager, bytes32 productId) external {
        console2.log("=== Remove Shield ===");
        console2.log("PolicyManager:", policyManager);

        vm.startBroadcast();

        IPolicyManagerWire(policyManager).deactivateProduct(productId);
        console2.log("[OK] Product deactivated in PolicyManager");

        vm.stopBroadcast();

        console2.log("=== Shield Removed Successfully ===");
    }

    // ═══════════════════════════════════════════════════════════════════
    // UPDATE FEE DISTRIBUTOR
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Update the fee distributor address on TWAPBurner.
    /// @param twapBurner Address of TWAPBurner
    /// @param newDistributor Address of the new AdaptiveFeeDistributor
    function updateFeeDistributor(address twapBurner, address newDistributor) external {
        console2.log("=== Update Fee Distributor ===");
        console2.log("TWAPBurner:", twapBurner);
        console2.log("New Distributor:", newDistributor);

        vm.startBroadcast();

        ITWAPBurnerWire(twapBurner).setFeeDistributor(newDistributor);
        console2.log("[OK] TWAPBurner.feeDistributor updated");

        vm.stopBroadcast();

        console2.log("=== Fee Distributor Updated Successfully ===");
    }

    // ═══════════════════════════════════════════════════════════════════
    // UPDATE TWAP BURNER
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Update the TWAPBurner address on CoverRouter.
    /// @param coverRouter Address of CoverRouterV2
    /// @param newTwapBurner Address of the new TWAPBurner
    function updateTwapBurner(address coverRouter, address newTwapBurner) external {
        console2.log("=== Update TWAP Burner ===");
        console2.log("CoverRouter:", coverRouter);
        console2.log("New TWAPBurner:", newTwapBurner);

        vm.startBroadcast();

        ICoverRouterWire(coverRouter).setTwapBurner(newTwapBurner);
        console2.log("[OK] CoverRouterV2.twapBurner updated");

        vm.stopBroadcast();

        console2.log("=== TWAP Burner Updated Successfully ===");
    }

    // ═══════════════════════════════════════════════════════════════════
    // GRANT BUYBACK OPERATOR
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Grant BUYBACK_OPERATOR_ROLE to an address on BuybackEngine.
    /// @param buybackEngine Address of BuybackEngine
    /// @param operator Address to grant the role to
    function grantBuybackOperator(address buybackEngine, address operator) external {
        console2.log("=== Grant Buyback Operator ===");
        console2.log("BuybackEngine:", buybackEngine);
        console2.log("Operator:", operator);

        bytes32 BUYBACK_OPERATOR_ROLE = keccak256("BUYBACK_OPERATOR_ROLE");

        vm.startBroadcast();

        IAccessControlWire(buybackEngine).grantRole(BUYBACK_OPERATOR_ROLE, operator);
        console2.log("[OK] BUYBACK_OPERATOR_ROLE granted");

        vm.stopBroadcast();

        // Verify
        bool hasRole = IAccessControlWire(buybackEngine).hasRole(BUYBACK_OPERATOR_ROLE, operator);
        if (hasRole) {
            console2.log("[VERIFIED] Operator has BUYBACK_OPERATOR_ROLE");
        } else {
            console2.log("[WARNING] Role grant may not have taken effect");
        }

        console2.log("=== Buyback Operator Granted Successfully ===");
    }

    // ═══════════════════════════════════════════════════════════════════
    // TRANSFER OWNERSHIP
    // ═══════════════════════════════════════════════════════════════════

    /// @notice Transfer ownership of an Ownable contract to a new owner.
    /// @param contract_ Address of the Ownable contract
    /// @param newOwner Address of the new owner (typically multisig)
    function transferOwnership(address contract_, address newOwner) external {
        console2.log("=== Transfer Ownership ===");
        console2.log("Contract:", contract_);
        console2.log("New Owner:", newOwner);

        address currentOwner = IOwnableWire(contract_).owner();
        console2.log("Current Owner:", currentOwner);

        vm.startBroadcast();

        IOwnableWire(contract_).transferOwnership(newOwner);
        console2.log("[OK] transferOwnership called");

        vm.stopBroadcast();

        // Verify
        address updatedOwner = IOwnableWire(contract_).owner();
        if (updatedOwner == newOwner) {
            console2.log("[VERIFIED] Ownership transferred to:", newOwner);
        } else {
            console2.log("[WARNING] Owner is now:", updatedOwner);
            console2.log("  If using Ownable2Step, new owner must call acceptOwnership()");
        }

        console2.log("=== Ownership Transfer Complete ===");
    }
}
