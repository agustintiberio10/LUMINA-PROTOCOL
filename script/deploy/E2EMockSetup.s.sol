// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockChainlinkOracle} from "../../src/test-helpers/MockChainlinkOracle.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";

interface IPMRegister {
    function registerProduct(bytes32 productId, address shield) external;
}

interface ICRConfigure {
    function configureProduct(
        bytes32 productId,
        uint256 payoutRatioBps,
        uint256 triggerProbBps,
        uint256 marginBps,
        uint32 durationSeconds,
        bool active
    ) external;
}

/// @title E2EMockSetup — TESTNET E2E
/// @notice Deploys a parallel FLASHBTC1H shield wired to a MockChainlinkOracle
///         (controllable price) + its adapter, registers `FLASHBTC1H-MOCK-001` in
///         PolicyManagerV2 and configures it in CoverRouterV2 (payoutRatioBps=8000),
///         so the full purchase→trigger→bond→mature→redeem flow can be exercised
///         on-chain with a forced trigger. Founder (deployer) = owner/keeper/relayer.
contract E2EMockSetup is Script {
    // Canonical LIVE V5.4 (PR #160 manifest)
    address constant POLICY_MANAGER = 0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8;
    address constant COVER_ROUTER = 0xcdB70B40e6a3DEac3189185d947A0e458518F566;
    address constant SEQUENCER = address(0); // testnet: assume up
    bytes32 constant MOCK_PRODUCT_ID = keccak256("FLASHBTC1H-MOCK-001");
    int256 constant INITIAL_PRICE = 60_000 * 1e8; // $60k, 8-dec

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address founder = vm.addr(pk);
        vm.startBroadcast(pk);

        // 1. Mock oracle (controllable BTC/USD)
        MockChainlinkOracle mockOracle = new MockChainlinkOracle(INITIAL_PRICE);

        // 2. Adapter proxy (uninitialized — resolves the adapter<->shield cycle)
        FlashShieldAdapter adapter =
            FlashShieldAdapter(address(new ERC1967Proxy(address(new FlashShieldAdapter()), "")));

        // 3. Shield proxy initialized with router = adapter, priceFeed = mock
        FlashBTCShield1h shield = FlashBTCShield1h(
            address(
                new ERC1967Proxy(
                    address(new FlashBTCShield1h()),
                    abi.encodeCall(FlashBTCShield1h.initialize, (address(adapter), address(mockOracle), SEQUENCER))
                )
            )
        );

        // 4. Initialize + wire the adapter (founder is keeper + relayer so it can settle)
        adapter.initialize(address(shield), MOCK_PRODUCT_ID);
        adapter.setPolicyManager(POLICY_MANAGER);
        adapter.setKeeper(founder);
        adapter.setRelayer(founder);

        // 5. Register in PolicyManager + configure in CoverRouter (payoutRatioBps must be 8000)
        IPMRegister(POLICY_MANAGER).registerProduct(MOCK_PRODUCT_ID, address(adapter));
        ICRConfigure(COVER_ROUTER).configureProduct(MOCK_PRODUCT_ID, 8000, 18, 20000, 3600, true);

        vm.stopBroadcast();

        console.log("=== E2E Mock Setup ===");
        console.log("MockOracle:", address(mockOracle));
        console.log("MockShield:", address(shield));
        console.log("MockAdapter:", address(adapter));
        console.log("productId (keccak FLASHBTC1H-MOCK-001):");
        console.logBytes32(MOCK_PRODUCT_ID);
    }
}
