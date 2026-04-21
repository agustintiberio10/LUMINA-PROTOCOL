// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

interface ICoverRouter {
    function configureProduct(
        bytes32 _productId,
        uint256 _payoutRatioBps,
        uint256 _triggerProbBps,
        uint256 _marginBps,
        uint32 _durationSeconds,
        bool _active
    ) external;
}

/// @notice Configure all 9 shield products in CoverRouterV2 on Base Sepolia
contract ConfigureProductsScript is Script {
    address constant COVER_ROUTER = 0x71DBcE71AA36370f7357F6D8E0c8ba96343C8306;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        ICoverRouter router = ICoverRouter(COVER_ROUTER);

        // FlashBTC1H: 5% drop in 1h, 80% payout, ~0.20% trigger prob, 1.5x margin
        router.configureProduct(keccak256("FLASHBTC1H-001"), 8000, 20, 15000, 3600, true);

        // FlashBTC4H: 8% drop in 4h
        router.configureProduct(keccak256("FLASHBTC4H-001"), 8000, 30, 15000, 14400, true);

        // FlashBTC24H: 10% drop in 24h
        router.configureProduct(keccak256("FLASHBTC24-001"), 8000, 50, 15000, 86400, true);

        // FlashBTC48H: 15% drop in 48h
        router.configureProduct(keccak256("FLASHBTC48-001"), 8000, 40, 15000, 172800, true);

        // FlashETH1H: 7% drop in 1h
        router.configureProduct(keccak256("FLASHETH1H-001"), 8000, 25, 15000, 3600, true);

        // FlashETH24H: 12% drop in 24h
        router.configureProduct(keccak256("FLASHETH24-001"), 8000, 60, 15000, 86400, true);

        // FlashETH48H: 18% drop in 48h
        router.configureProduct(keccak256("FLASHETH48-001"), 8000, 50, 15000, 172800, true);

        // MicroDepeg: USDT < $0.995, 7 days
        router.configureProduct(keccak256("MICRODEPEG-001"), 8000, 100, 15000, 604800, true);

        // RateShock: Aave rate > 10%, 7 days
        router.configureProduct(keccak256("RATESHOCK-001"), 8000, 80, 15000, 604800, true);

        vm.stopBroadcast();

        console.log("=== All 9 products configured in CoverRouterV2 ===");
    }
}
