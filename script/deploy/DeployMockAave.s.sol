// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {MockAavePool} from "../../src/mocks/MockAavePool.sol";

/// @title DeployMockAave
/// @notice Sprint H: deploys 1 controllable `MockAavePool` to Sepolia and
///         seeds healthy initial USDC rates (5% borrow, 3% liquidity APY).
///         Replaces the legacy stub at `0xcc0606b64275c08539770864081D209A8C9b178a`,
///         which was a minimal mock without setters.
/// @dev Run with:
///   forge script script/deploy/DeployMockAave.s.sol \
///     --rpc-url $BASE_SEPOLIA_RPC --private-key $DEPLOYER_PRIVATE_KEY \
///     --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY
contract DeployMockAave is Script {
    /// @dev USDC on Base Sepolia (Circle official, set in Sprint C).
    address internal constant USDC_SEPOLIA = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    function run() external {
        vm.startBroadcast();

        MockAavePool pool = new MockAavePool();
        pool.setBorrowRate(USDC_SEPOLIA, 500); // 5% APY (healthy default)
        pool.setLiquidityRate(USDC_SEPOLIA, 300); // 3% APY

        vm.stopBroadcast();

        console.log("===== MOCK AAVE V3 POOL DEPLOYED (Sepolia) =====");
        console.log("MockAavePool:", address(pool));
        console.log("USDC seeded: 5%% borrow / 3%% liquidity APY");
        console.log("=================================================");
    }
}
