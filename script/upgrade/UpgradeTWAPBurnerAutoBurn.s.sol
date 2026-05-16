// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice UUPS upgrade of TWAPBurner that introduces auto-burn-on-purchase.
///         Triggers a burn every 50 premium receipts OR $500 USDC accumulated,
///         with optional gas refund to the buyer that crosses the threshold.
contract UpgradeTWAPBurnerAutoBurn is Script {
    // Base Sepolia proxy (chainId 84532).
    address constant PROXY = 0x0000000000000000000000000000000000000000; // OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0x357BAF511383be70d1F3A5de7D3b07561Eec7d99)

    // V2 config
    uint256 constant MAX_PURCHASES = 50;
    uint256 constant MAX_ACCUMULATED_USDC = 500e6; // $500
    bool constant GAS_REFUND_ENABLED = true;
    uint256 constant GAS_REFUND_CAP = 0.001 ether;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);

        address owner = TWAPBurner(payable(PROXY)).owner();
        require(owner == sender, "Sender is not the proxy owner");

        vm.startBroadcast(pk);

        TWAPBurner newImpl = new TWAPBurner();
        console.log("New TWAPBurner implementation:", address(newImpl));

        bytes memory initData = abi.encodeWithSelector(
            TWAPBurner.initializeV2.selector,
            MAX_PURCHASES,
            MAX_ACCUMULATED_USDC,
            GAS_REFUND_ENABLED,
            GAS_REFUND_CAP,
            sender // refund treasury (deployer for testnet; rotate to multisig on mainnet)
        );

        UUPSUpgradeable(PROXY).upgradeToAndCall(address(newImpl), initData);

        vm.stopBroadcast();

        TWAPBurner b = TWAPBurner(payable(PROXY));
        console.log("=== TWAPBurner V2 UPGRADED ===");
        console.log("Proxy:                       ", PROXY);
        console.log("Implementation (new):        ", address(newImpl));
        console.log("maxPurchasesBeforeBurn:      ", b.maxPurchasesBeforeBurn());
        console.log("maxAccumulatedUSDCBeforeBurn:", b.maxAccumulatedUSDCBeforeBurn());
        console.log("gasRefundEnabled:            ", b.gasRefundEnabled());
        console.log("gasRefundCap (wei):          ", b.gasRefundCap());
        console.log("gasRefundTreasury:           ", b.gasRefundTreasury());
        console.log("Chain ID:                    ", block.chainid);
    }
}
