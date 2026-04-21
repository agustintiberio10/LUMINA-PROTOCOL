// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ShieldKeeper} from "../../src/automation/ShieldKeeper.sol";
import {PolicyManagerV2} from "../../src/core/PolicyManagerV2.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

// ═══════ INLINE MOCKS ═══════

contract MockBondVault_SK {
    uint256 public cap = 1_000_000; // integer dollars
    uint256 public totalReserved; // 18-dec USD-wei (matches real BondVault)
    uint256 public totalIssued;

    mapping(address => uint256) public bondBalances;

    function availableCapacityUSD() external view returns (uint256) {
        uint256 reservedDollars = totalReserved / 1e18;
        if (cap <= reservedDollars) return 0;
        return cap - reservedDollars;
    }

    function issueBond(address to, uint256 usdPayout) external {
        bondBalances[to] += usdPayout;
        totalIssued += usdPayout;
    }

    function reserveCapacity(uint256 amount) external {
        totalReserved += amount;
    }

    function releaseReservation(uint256 amount) external {
        totalReserved -= amount;
    }

    function commitReservation(uint256 amount) external {
        totalReserved -= amount;
    }

    function setCapacity(uint256 _cap) external {
        cap = _cap;
    }
}

contract MockOracle_SK {
    mapping(bytes32 => int256) public prices;

    function setPrice(bytes32 asset, int256 price) external {
        prices[asset] = price;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        return prices[asset];
    }

    function getSequencerDowntime(uint256) external pure returns (uint256) {
        return 0;
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        return address(0);
    }

    function oracleKey() external pure returns (address) {
        return address(0);
    }

    function verifyPriceProofEIP712(int256, bytes32, uint256, bytes calldata) external pure returns (address) {
        return address(0);
    }

    function verifyExploitGovProofEIP712(int256, int256, bytes32, uint256, bytes calldata)
        external
        pure
        returns (address)
    {
        return address(0);
    }

    function priceProofDigest(int256, bytes32, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }

    function exploitReceiptProofDigest(bool, bool, bytes32, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @dev Minimal mock shield that supports the new checkAndSettlePolicy flow.
///      Simulates BaseShield behavior with configurable trigger conditions.
contract MockSettleableShield_SK {
    bytes32 public immutable _productId;
    address public immutable policyManager;

    uint256 private _nextPolicyId;
    bool public triggerResult; // If true, checkAndSettlePolicy marks as triggered

    struct CreatePolicyParams {
        address buyer;
        uint256 coverageAmount;
        uint256 premiumAmount;
        uint32 durationSeconds;
        bytes32 asset;
        bytes32 stablecoin;
        address protocol;
        bytes extraData;
    }

    struct PayoutResult {
        bool triggered;
        uint256 payoutAmount;
        address recipient;
        bytes32 reason;
    }

    struct PolicyData {
        address buyer;
        uint256 coverageAmount;
        uint256 expiresAt;
        bool settled;
        bool triggered;
    }

    mapping(uint256 => PolicyData) public policyData;

    event PolicySettledTriggered(uint256 indexed policyId, address indexed buyer, uint256 maxPayout);
    event PolicySettledExpired(uint256 indexed policyId);

    constructor(bytes32 pid, address _pm) {
        _productId = pid;
        policyManager = _pm;
    }

    function productId() external view returns (bytes32) {
        return _productId;
    }

    function setTriggerResult(bool _result) external {
        triggerResult = _result;
    }

    function createPolicy(CreatePolicyParams calldata params) external returns (uint256 policyId) {
        _nextPolicyId++;
        policyId = _nextPolicyId;
        policyData[policyId] = PolicyData({
            buyer: params.buyer,
            coverageAmount: params.coverageAmount,
            expiresAt: block.timestamp + params.durationSeconds,
            settled: false,
            triggered: false
        });
    }

    function verifyAndCalculate(uint256 policyId, bytes calldata) external view returns (PayoutResult memory result) {
        PolicyData storage pd = policyData[policyId];
        result = PayoutResult({
            triggered: true,
            payoutAmount: (pd.coverageAmount * 8000) / 10000,
            recipient: pd.buyer,
            reason: "MOCK_TRIGGER"
        });
    }

    function checkAndSettlePolicy(uint256 policyId) external {
        PolicyData storage pd = policyData[policyId];
        require(pd.buyer != address(0), "Policy not found");
        require(!pd.settled, "Already settled");
        require(block.timestamp >= pd.expiresAt + 24 hours, "Safety window not passed");

        pd.settled = true;
        pd.triggered = triggerResult;

        if (triggerResult) {
            emit PolicySettledTriggered(policyId, pd.buyer, (pd.coverageAmount * 8000) / 10000);
        } else {
            emit PolicySettledExpired(policyId);
        }
    }

    function getPolicyStatus(uint256 policyId) external view returns (uint8) {
        PolicyData storage pd = policyData[policyId];
        if (pd.buyer == address(0)) return 0; // NONEXISTENT
        if (pd.settled && pd.triggered) return 5; // PAID_OUT
        if (pd.settled) return 3; // EXPIRED
        if (block.timestamp < pd.expiresAt) return 2; // ACTIVE
        return 3; // EXPIRED (not yet settled)
    }

    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (address insuredAgent, uint256, uint256, uint256, uint256, uint8)
    {
        PolicyData storage pd = policyData[policyId];
        return (pd.buyer, pd.coverageAmount, 0, 0, pd.expiresAt, 0);
    }
}

contract ShieldKeeperTest is Test {
    using ProxyDeployer for *;

    ShieldKeeper public keeper;
    PolicyManagerV2 public policyManager;
    MockBondVault_SK public bondVault;
    MockSettleableShield_SK public shield;

    bytes32 constant PRODUCT_ID = keccak256("TESTPRODUCT-001");
    address constant BUYER = address(0xBEEF);
    address constant USDC_MOCK = address(0xAAAA);

    function setUp() public {
        bondVault = new MockBondVault_SK();
        policyManager = ProxyDeployer.deployPolicyManagerV2(address(bondVault));

        shield = new MockSettleableShield_SK(PRODUCT_ID, address(policyManager));

        // Register shield in policy manager
        policyManager.registerProduct(PRODUCT_ID, address(shield));

        // Set router to this test contract so we can call recordPolicy
        policyManager.setRouter(address(this));

        // Create keeper
        keeper = new ShieldKeeper(address(policyManager));
    }

    // ═══════ HELPERS ═══════

    function _createPolicy() internal returns (uint256 policyId) {
        policyId = policyManager.recordPolicy(
            PRODUCT_ID,
            BUYER,
            1000e6, // 1000 USDC coverage
            50e6, // 50 USDC premium
            3600, // 1h duration
            "BTC"
        );
    }

    // ═══════ TESTS ═══════

    function test_Keeper_CheckUpkeep_FindsPendingPolicies() public {
        // Create a policy
        uint256 policyId = _createPolicy();
        assertEq(policyId, 1);

        // Before expiry + safety window: no upkeep needed
        // Policy expires at block.timestamp + 3600, safety window is 24h
        (bool upkeepNeeded,) = keeper.checkUpkeep(abi.encode(PRODUCT_ID));
        // The policy is active, getActivePolicyIds returns it, but it hasn't expired yet
        // The keeper finds active policies — the shield's checkAndSettlePolicy will revert
        // if safety window hasn't passed. The keeper catches that in performUpkeep.
        // So checkUpkeep returns true if there are active policies.
        assertTrue(upkeepNeeded, "Should find active policies");

        // Warp past expiry + safety window
        vm.warp(block.timestamp + 3600 + 24 hours + 1);

        // Now upkeep should still be needed (policy not settled yet)
        (upkeepNeeded,) = keeper.checkUpkeep(abi.encode(PRODUCT_ID));
        assertTrue(upkeepNeeded, "Should still find pending policies after safety window");
    }

    function test_Keeper_PerformUpkeep_SettlesPolicies() public {
        uint256 policyId = _createPolicy();

        // Warp past expiry + safety window
        vm.warp(block.timestamp + 3600 + 24 hours + 1);

        // Set shield to NOT trigger (expire the policy)
        shield.setTriggerResult(false);

        // Build performData
        uint256[] memory ids = new uint256[](1);
        ids[0] = policyId;
        bytes memory performData = abi.encode(PRODUCT_ID, ids);

        // Perform upkeep
        keeper.performUpkeep(performData);

        // Verify policy was settled as expired
        (,,, bool settled, bool triggered) = shield.policyData(policyId);
        assertTrue(settled, "Policy should be settled");
        assertFalse(triggered, "Policy should not be triggered");
    }

    function test_Keeper_PerformUpkeep_TriggeredPolicy() public {
        uint256 policyId = _createPolicy();

        // Warp past expiry + safety window
        vm.warp(block.timestamp + 3600 + 24 hours + 1);

        // Set shield to trigger
        shield.setTriggerResult(true);

        uint256[] memory ids = new uint256[](1);
        ids[0] = policyId;
        bytes memory performData = abi.encode(PRODUCT_ID, ids);

        keeper.performUpkeep(performData);

        // Verify policy was settled as triggered
        (,,, bool settled, bool triggered) = shield.policyData(policyId);
        assertTrue(settled, "Policy should be settled");
        assertTrue(triggered, "Policy should be triggered");
    }

    function test_Keeper_MaxPoliciesPerUpkeep() public {
        // Create 15 policies
        uint256[] memory policyIds = new uint256[](15);
        for (uint256 i = 0; i < 15; i++) {
            policyIds[i] = _createPolicy();
        }

        // Warp past expiry + safety window
        vm.warp(block.timestamp + 3600 + 24 hours + 1);
        shield.setTriggerResult(false);

        // Try to settle all 15 via performUpkeep — only 10 should be processed
        bytes memory performData = abi.encode(PRODUCT_ID, policyIds);
        keeper.performUpkeep(performData);

        // First 10 should be settled
        for (uint256 i = 0; i < 10; i++) {
            (,,, bool settled,) = shield.policyData(policyIds[i]);
            assertTrue(settled, "Policy should be settled");
        }

        // Last 5 should NOT be settled
        for (uint256 i = 10; i < 15; i++) {
            (,,, bool settled,) = shield.policyData(policyIds[i]);
            assertFalse(settled, "Policy should NOT be settled (over max)");
        }
    }

    function test_Keeper_PausedReverts() public {
        _createPolicy();
        vm.warp(block.timestamp + 3600 + 24 hours + 1);

        // Pause
        keeper.pause();

        // checkUpkeep should return false
        (bool upkeepNeeded,) = keeper.checkUpkeep(abi.encode(PRODUCT_ID));
        assertFalse(upkeepNeeded, "Should not need upkeep when paused");

        // performUpkeep should revert
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        bytes memory performData = abi.encode(PRODUCT_ID, ids);

        vm.expectRevert(ShieldKeeper.KeeperPausedError.selector);
        keeper.performUpkeep(performData);

        // Unpause and verify it works again
        keeper.unpause();
        (upkeepNeeded,) = keeper.checkUpkeep(abi.encode(PRODUCT_ID));
        assertTrue(upkeepNeeded, "Should need upkeep after unpause");
    }

    function test_Keeper_CheckUpkeep_NoProducts_ReturnsFalse() public view {
        // Check upkeep with a non-existent product
        bytes32 fakeProduct = keccak256("FAKE-001");
        (bool upkeepNeeded,) = keeper.checkUpkeep(abi.encode(fakeProduct));
        assertFalse(upkeepNeeded, "Should not need upkeep for unknown product");
    }

    function test_Keeper_PerformUpkeep_GracefulFailure() public {
        // Create policy but DON'T warp past safety window
        _createPolicy();

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        bytes memory performData = abi.encode(PRODUCT_ID, ids);

        // performUpkeep should NOT revert — it catches errors per-policy
        keeper.performUpkeep(performData);

        // Policy should NOT be settled (safety window not passed)
        (,,, bool settled,) = shield.policyData(1);
        assertFalse(settled, "Policy should not be settled before safety window");
    }

    function test_Keeper_CheckUpkeep_EmptyCheckData_ScansAllProducts() public {
        _createPolicy();

        // Empty checkData — should scan all registered products
        (bool upkeepNeeded, bytes memory performData) = keeper.checkUpkeep("");
        assertTrue(upkeepNeeded, "Should find policies across all products");
        assertTrue(performData.length > 0, "Should return perform data");
    }
}
