// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";

/// @title DeployBondVaultSetC
/// @notice Sprint V-A — Deploys a fresh BondVault (SET C) on Sepolia using the
///         Sprint T fix (no self-revoke). Replaces the upgrade-locked SET B
///         (block 41,213,954 lockdown — see ADR-012).
///
/// Required env vars:
///   LUMINA_TOKEN, CLAIMBOND, POLICY_MANAGER, CAPACITY_ORACLE, DEPLOYER_PRIVATE_KEY
///
/// Init pattern: 2-step (initialize with policyManager=address(0), then setPolicyManager)
/// per BondVault.sol:120 + :135. Avoids the encoder-length mismatch in the original
/// spec script (3-arg selector vs 4-arg signature).
contract DeployBondVaultSetC is Script {
    function run() external returns (address proxy, address impl) {
        address luminaToken = vm.envAddress("LUMINA_TOKEN");
        address claimBond = vm.envAddress("CLAIMBOND");
        address policyManager = vm.envAddress("POLICY_MANAGER");
        address priceOracle = vm.envAddress("CAPACITY_ORACLE");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. Deploy impl
        BondVault implContract = new BondVault();
        impl = address(implContract);

        // 2. Deploy proxy with initialize (2-step: policyManager=address(0))
        bytes memory initData =
            abi.encodeWithSelector(BondVault.initialize.selector, luminaToken, claimBond, priceOracle, address(0));
        ERC1967Proxy proxyContract = new ERC1967Proxy(impl, initData);
        proxy = address(proxyContract);

        // 3. setPolicyManager (one-shot, only callable by deployer)
        BondVault(proxy).setPolicyManager(policyManager);

        // 4. CRITICAL invariant: deployer retains BOTH admin roles
        require(
            BondVault(proxy).hasRole(BondVault(proxy).DEFAULT_ADMIN_ROLE(), deployer),
            "Deployer must keep DEFAULT_ADMIN_ROLE"
        );
        require(
            BondVault(proxy).hasRole(BondVault(proxy).AUTHORIZED_CALLER_ADMIN_ROLE(), deployer),
            "Deployer must keep AUTHORIZED_CALLER_ADMIN_ROLE"
        );

        vm.stopBroadcast();

        console.log("=== BondVault SET C deployed ===");
        console.log("Proxy:", proxy);
        console.log("Impl:", impl);
        console.log("Deployer admin role: CONFIRMED");
    }
}
