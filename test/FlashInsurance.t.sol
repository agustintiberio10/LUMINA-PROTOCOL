// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlashBTCShield24h} from "../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../src/products/FlashBTCShield48h.sol";
import {FlashETHShield24h} from "../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../src/products/FlashETHShield48h.sol";
import {FlashVault} from "../src/vaults/FlashVault.sol";
import {IShield} from "../src/interfaces/IShield.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

/// @notice Mock oracle that returns configurable prices and always validates EIP-712 proofs
contract MockOracleFlash {
    address public oracleKey;
    mapping(bytes32 => int256) public prices;

    constructor(address _key) {
        oracleKey = _key;
    }

    function setPrice(bytes32 asset, int256 price) external {
        prices[asset] = price;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        return prices[asset];
    }

    function verifySignature(bytes32, bytes calldata) external view returns (address) {
        return oracleKey;
    }

    function getSequencerDowntime(uint256) external pure returns (uint256) {
        return 0;
    }

    /// @dev Always returns a non-zero address to pass EIP-712 verification in shields
    function verifyPriceProofEIP712(
        int256,
        bytes32,
        uint256,
        bytes calldata
    ) external view returns (address) {
        return oracleKey;
    }

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return keccak256("MOCK_DOMAIN");
    }
}

contract FlashInsuranceTest is Test {
    FlashBTCShield24h btc24;
    FlashBTCShield48h btc48;
    FlashETHShield24h eth24;
    FlashETHShield48h eth48;
    FlashVault vault;
    MockOracleFlash oracle;
    MockERC20 usdc;
    MockERC20 aToken;
    MockAavePool aavePool;

    address router = address(0xD);
    address oracleKey = address(0xAA);
    address buyer = address(0xBEEF);
    address owner = address(0xA);
    address policyManager = address(0xE);

    int256 constant BTC_PRICE = 50_000_00000000; // $50,000 (8 decimals)
    int256 constant ETH_PRICE = 3_000_00000000;  // $3,000 (8 decimals)

    function setUp() public {
        // Deploy mock oracle
        oracle = new MockOracleFlash(oracleKey);
        oracle.setPrice("BTC", BTC_PRICE);
        oracle.setPrice("ETH", ETH_PRICE);

        // Deploy all 4 shields
        btc24 = new FlashBTCShield24h(router, address(oracle));
        btc48 = new FlashBTCShield48h(router, address(oracle));
        eth24 = new FlashETHShield24h(router, address(oracle));
        eth48 = new FlashETHShield48h(router, address(oracle));

        // Deploy vault via UUPS proxy
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aToken = new MockERC20("Aave Base USDC", "aBasUSDC", 6);
        aavePool = new MockAavePool(address(aToken));

        FlashVault impl = new FlashVault();
        bytes memory initData = abi.encodeCall(
            FlashVault.initialize,
            (owner, address(usdc), router, policyManager, address(aavePool), address(aToken))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = FlashVault(address(proxy));
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════

    function _createBTCPolicy(FlashBTCShield24h shield, uint32 duration) internal returns (uint256) {
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: 10_000e6,
            premiumAmount: 500e6,
            durationSeconds: duration,
            asset: "BTC",
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });
        vm.prank(router);
        return shield.createPolicy(params);
    }

    function _createBTC48Policy(FlashBTCShield48h shield, uint32 duration) internal returns (uint256) {
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: 10_000e6,
            premiumAmount: 500e6,
            durationSeconds: duration,
            asset: "BTC",
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });
        vm.prank(router);
        return shield.createPolicy(params);
    }

    function _createETH24Policy(FlashETHShield24h shield, uint32 duration) internal returns (uint256) {
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: 10_000e6,
            premiumAmount: 500e6,
            durationSeconds: duration,
            asset: "ETH",
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });
        vm.prank(router);
        return shield.createPolicy(params);
    }

    function _createETH48Policy(FlashETHShield48h shield, uint32 duration) internal returns (uint256) {
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: 10_000e6,
            premiumAmount: 500e6,
            durationSeconds: duration,
            asset: "ETH",
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });
        vm.prank(router);
        return shield.createPolicy(params);
    }

    /// @dev Build an oracle proof for verifyAndCalculate
    function _buildProof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27)); // dummy 65-byte sig
        return abi.encode(price, asset, verifiedAt, sig);
    }

    // ═══════════════════════════════════════════════════════════
    //  FlashBTCShield24h — 15 tests
    // ═══════════════════════════════════════════════════════════

    function test_btc24_product_id() public {
        assertEq(btc24.productId(), keccak256("FLASHBTC24-001"));
    }

    function test_btc24_trigger_1800_bps() public {
        assertEq(btc24.TRIGGER_DROP_BPS(), 1800);
    }

    function test_btc24_deductible_2000() public {
        assertEq(btc24.DEDUCTIBLE_BPS(), 2000);
    }

    function test_btc24_waiting_zero() public {
        assertEq(btc24.WAITING_PERIOD(), 0);
    }

    function test_btc24_duration_fixed() public {
        (uint32 minD, uint32 maxD) = btc24.durationRange();
        assertEq(minD, 86400);
        assertEq(maxD, 86400);
    }

    function test_btc24_max_proof_age() public {
        assertEq(btc24.MAX_PROOF_AGE(), 900);
    }

    function test_btc24_asset_btc() public {
        uint256 policyId = _createBTCPolicy(btc24, 86400);
        FlashBTCShield24h.BSSData memory data = btc24.getBSSData(policyId);
        assertEq(data.asset, bytes32("BTC"));
    }

    function test_btc24_max_allocation() public {
        assertEq(btc24.MAX_ALLOCATION_BPS(), 3000);
    }

    function test_btc24_trigger_at_18pct() public {
        uint256 policyId = _createBTCPolicy(btc24, 86400);
        // Strike = 50000e8, trigger = 50000e8 * 8200 / 10000 = 41000e8
        // Price dropped 18% => 41000e8. Need price BELOW trigger to pass.
        // 18% drop = price at 82% = 41000e8. Trigger price = 41000e8.
        // verifiedPrice must be < triggerPrice, so use a price slightly below
        int256 crashPrice = 40_999_00000000; // just below trigger
        uint256 verifiedAt = block.timestamp + 1; // during coverage (after waitingEndsAt)
        vm.warp(block.timestamp + 2); // move time so verifiedAt is in the past but within MAX_PROOF_AGE

        bytes memory proof = _buildProof(crashPrice, "BTC", verifiedAt);
        vm.prank(router);
        IShield.PayoutResult memory result = btc24.verifyAndCalculate(policyId, proof);
        assertTrue(result.triggered);
    }

    function test_btc24_no_trigger_at_17pct() public {
        uint256 policyId = _createBTCPolicy(btc24, 86400);
        // 17% drop => price at 83% = 41500e8. Trigger is 41000e8. Price is above trigger.
        int256 notCrashPrice = 41_500_00000000;
        uint256 verifiedAt = block.timestamp + 1;
        vm.warp(block.timestamp + 2);

        bytes memory proof = _buildProof(notCrashPrice, "BTC", verifiedAt);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IShield.TriggerNotMet.selector, policyId, bytes32("PRICE_ABOVE_TRIGGER")));
        btc24.verifyAndCalculate(policyId, proof);
    }

    function test_btc24_payout_80pct() public {
        uint256 coverageAmount = 10_000e6;
        uint256 policyId = _createBTCPolicy(btc24, 86400);

        IShield.PolicyInfo memory info = btc24.getPolicyInfo(policyId);
        uint256 expectedPayout = (coverageAmount * 8000) / 10_000;
        assertEq(info.maxPayout, expectedPayout);
    }

    function test_btc24_expired_proof_reverts() public {
        uint256 policyId = _createBTCPolicy(btc24, 86400);
        int256 crashPrice = 40_000_00000000;
        uint256 verifiedAt = block.timestamp + 1;
        // Warp past MAX_PROOF_AGE (900s) from verifiedAt
        vm.warp(verifiedAt + 901);

        bytes memory proof = _buildProof(crashPrice, "BTC", verifiedAt);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield24h.ProofTooOld.selector, verifiedAt, verifiedAt + 901));
        btc24.verifyAndCalculate(policyId, proof);
    }

    function test_btc24_trigger_price_calculated() public {
        uint256 policyId = _createBTCPolicy(btc24, 86400);
        FlashBTCShield24h.BSSData memory data = btc24.getBSSData(policyId);
        // triggerPrice = strikePrice * (10000 - 1800) / 10000 = 50000e8 * 82 / 100
        int256 expectedTrigger = (BTC_PRICE * 8200) / 10000;
        assertEq(data.strikePrice, BTC_PRICE);
        assertEq(data.triggerPrice, expectedTrigger);
    }

    function test_btc24_rejects_eth_asset_on_create() public {
        IShield.CreatePolicyParams memory params = IShield.CreatePolicyParams({
            buyer: buyer,
            coverageAmount: 10_000e6,
            premiumAmount: 500e6,
            durationSeconds: 86400,
            asset: "ETH",
            stablecoin: bytes32(0),
            protocol: address(0),
            extraData: ""
        });
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield24h.InvalidAsset.selector, bytes32("ETH")));
        btc24.createPolicy(params);
    }

    function test_btc24_wrong_asset_reverts() public {
        uint256 policyId = _createBTCPolicy(btc24, 86400);
        int256 crashPrice = 40_000_00000000;
        uint256 verifiedAt = block.timestamp + 1;
        vm.warp(block.timestamp + 2);

        // Submit proof with ETH asset on BTC shield
        bytes memory proof = _buildProof(crashPrice, "ETH", verifiedAt);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield24h.AssetMismatch.selector, bytes32("BTC"), bytes32("ETH")));
        btc24.verifyAndCalculate(policyId, proof);
    }

    // ═══════════════════════════════════════════════════════════
    //  FlashBTCShield48h — 5 tests
    // ═══════════════════════════════════════════════════════════

    function test_btc48_product_id() public {
        assertEq(btc48.productId(), keccak256("FLASHBTC48-001"));
    }

    function test_btc48_trigger_2200() public {
        assertEq(btc48.TRIGGER_DROP_BPS(), 2200);
    }

    function test_btc48_duration_172800() public {
        (uint32 minD, uint32 maxD) = btc48.durationRange();
        assertEq(minD, 172800);
        assertEq(maxD, 172800);
    }

    function test_btc48_trigger_at_22pct() public {
        uint256 policyId = _createBTC48Policy(btc48, 172800);
        // Strike = 50000e8, trigger = 50000e8 * 7800 / 10000 = 39000e8
        int256 crashPrice = 38_999_00000000; // below trigger
        uint256 verifiedAt = block.timestamp + 1;
        vm.warp(block.timestamp + 2);

        bytes memory proof = _buildProof(crashPrice, "BTC", verifiedAt);
        vm.prank(router);
        IShield.PayoutResult memory result = btc48.verifyAndCalculate(policyId, proof);
        assertTrue(result.triggered);
    }

    function test_btc48_no_trigger_at_21pct() public {
        uint256 policyId = _createBTC48Policy(btc48, 172800);
        // 21% drop => price at 79% = 39500e8. Trigger is 39000e8. Above trigger.
        int256 notCrashPrice = 39_500_00000000;
        uint256 verifiedAt = block.timestamp + 1;
        vm.warp(block.timestamp + 2);

        bytes memory proof = _buildProof(notCrashPrice, "BTC", verifiedAt);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IShield.TriggerNotMet.selector, policyId, bytes32("PRICE_ABOVE_TRIGGER")));
        btc48.verifyAndCalculate(policyId, proof);
    }

    // ═══════════════════════════════════════════════════════════
    //  FlashETHShield24h — 5 tests
    // ═══════════════════════════════════════════════════════════

    function test_eth24_product_id() public {
        assertEq(eth24.productId(), keccak256("FLASHETH24-001"));
    }

    function test_eth24_trigger_2000() public {
        assertEq(eth24.TRIGGER_DROP_BPS(), 2000);
    }

    function test_eth24_asset_eth() public {
        uint256 policyId = _createETH24Policy(eth24, 86400);
        FlashETHShield24h.BSSData memory data = eth24.getBSSData(policyId);
        assertEq(data.asset, bytes32("ETH"));
    }

    function test_eth24_trigger_at_20pct() public {
        uint256 policyId = _createETH24Policy(eth24, 86400);
        // Strike = 3000e8, trigger = 3000e8 * 8000 / 10000 = 2400e8
        int256 crashPrice = 2_399_00000000; // below trigger
        uint256 verifiedAt = block.timestamp + 1;
        vm.warp(block.timestamp + 2);

        bytes memory proof = _buildProof(crashPrice, "ETH", verifiedAt);
        vm.prank(router);
        IShield.PayoutResult memory result = eth24.verifyAndCalculate(policyId, proof);
        assertTrue(result.triggered);
    }

    function test_eth24_no_trigger_at_19pct() public {
        uint256 policyId = _createETH24Policy(eth24, 86400);
        // 19% drop => price at 81% = 2430e8. Trigger is 2400e8. Above trigger.
        int256 notCrashPrice = 2_430_00000000;
        uint256 verifiedAt = block.timestamp + 1;
        vm.warp(block.timestamp + 2);

        bytes memory proof = _buildProof(notCrashPrice, "ETH", verifiedAt);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IShield.TriggerNotMet.selector, policyId, bytes32("PRICE_ABOVE_TRIGGER")));
        eth24.verifyAndCalculate(policyId, proof);
    }

    // ═══════════════════════════════════════════════════════════
    //  FlashETHShield48h — 5 tests
    // ═══════════════════════════════════════════════════════════

    function test_eth48_product_id() public {
        assertEq(eth48.productId(), keccak256("FLASHETH48-001"));
    }

    function test_eth48_trigger_2800() public {
        assertEq(eth48.TRIGGER_DROP_BPS(), 2800);
    }

    function test_eth48_duration() public {
        (uint32 minD, uint32 maxD) = eth48.durationRange();
        assertEq(minD, 172800);
        assertEq(maxD, 172800);
    }

    function test_eth48_trigger_at_28pct() public {
        uint256 policyId = _createETH48Policy(eth48, 172800);
        // Strike = 3000e8, trigger = 3000e8 * 7200 / 10000 = 2160e8
        int256 crashPrice = 2_159_00000000; // below trigger
        uint256 verifiedAt = block.timestamp + 1;
        vm.warp(block.timestamp + 2);

        bytes memory proof = _buildProof(crashPrice, "ETH", verifiedAt);
        vm.prank(router);
        IShield.PayoutResult memory result = eth48.verifyAndCalculate(policyId, proof);
        assertTrue(result.triggered);
    }

    function test_eth48_no_trigger_at_27pct() public {
        uint256 policyId = _createETH48Policy(eth48, 172800);
        // 27% drop => price at 73% = 2190e8. Trigger is 2160e8. Above trigger.
        int256 notCrashPrice = 2_190_00000000;
        uint256 verifiedAt = block.timestamp + 1;
        vm.warp(block.timestamp + 2);

        bytes memory proof = _buildProof(notCrashPrice, "ETH", verifiedAt);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IShield.TriggerNotMet.selector, policyId, bytes32("PRICE_ABOVE_TRIGGER")));
        eth48.verifyAndCalculate(policyId, proof);
    }

    // ═══════════════════════════════════════════════════════════
    //  FlashVault — 5 tests
    // ═══════════════════════════════════════════════════════════

    function test_vault_cooldown() public {
        assertEq(vault.cooldownDuration(), 604800);
    }

    function test_vault_name() public {
        assertEq(vault.name(), "Lumina FlashVault");
    }

    function test_vault_symbol() public {
        assertEq(vault.symbol(), "lmFLASH");
    }
}
