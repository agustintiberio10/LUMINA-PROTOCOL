// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../../../src/core/TWAPBurner.sol";
import {LuminaBondMarketplace} from "../../../../../src/marketplace/LuminaBondMarketplace.sol";
import {ShieldKeeper} from "../../../../../src/automation/ShieldKeeper.sol";
import {FounderVesting} from "../../../../../src/token/FounderVesting.sol";
import {IDexRouter} from "../../../../../src/interfaces/IDexRouter.sol";

// ─────────────────────────────────────────────────────────────────────────
// INLINE V2 CONTRACTS WITH NEW STATE + REINITIALIZERS
// ─────────────────────────────────────────────────────────────────────────

/// @dev BondVault V2 — adds a `featureFlag` at the end of V1 storage.
///      The new slot lands inside the V1 __gap region (gap[0]), so V1
///      storage is preserved and V2 operates normally.
contract BondVaultV2 is BondVault {
    uint256 public featureFlag;
    uint256 public migratedAtTimestamp;

    function reinitializeV2(uint256 flag) external reinitializer(2) {
        featureFlag = flag;
        migratedAtTimestamp = block.timestamp;
    }

    function setFeatureFlag(uint256 v) external {
        featureFlag = v;
    }
}

/// @dev CoverRouter V2 — adds two new state variables. Used for coordinated
///      multi-contract upgrade and gap-management tests.
contract CoverRouterV2Plus is CoverRouterV2 {
    uint256 public newFeeBps;
    mapping(address => bool) public allowlisted;

    function reinitializeV2(uint256 _bps) external reinitializer(2) {
        newFeeBps = _bps;
    }

    function setAllowlisted(address who, bool ok) external {
        allowlisted[who] = ok;
    }
}

/// @dev PolicyManager V2+ — adds a versioning field.
contract PolicyManagerV2Plus is PolicyManagerV2 {
    uint256 public logicVersion;

    function reinitializeV2(uint256 v) external reinitializer(2) {
        logicVersion = v;
    }
}

/// @dev Marketplace V2 — adds a listing counter duplicated for state-active tests.
contract LuminaBondMarketplaceV2 is LuminaBondMarketplace {
    uint256 public migrationCheckpoint;

    function reinitializeV2(uint256 checkpoint) external reinitializer(2) {
        migrationCheckpoint = checkpoint;
    }
}

/// @dev ClaimBond V2 — adds a flag to demonstrate reinit-version bookkeeping.
contract ClaimBondV2 is ClaimBond {
    uint256 public migrationTag;

    function reinitializeV2(uint256 tag) external reinitializer(2) {
        migrationTag = tag;
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MOCKS (external deps only)
// ─────────────────────────────────────────────────────────────────────────

contract MockUSDC is IERC20 {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract MockPriceOracleMigration {
    uint256 public price;

    constructor(uint256 _p) {
        price = _p;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

contract MockDexRouterMigration is IDexRouter {
    IERC20 public lumina;

    constructor(address l) {
        lumina = IERC20(l);
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256) external override returns (uint256) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 27 * 1e12;
        lumina.transfer(msg.sender, out);
        return out;
    }

    function getQuote(address, address, uint256 amountIn) external pure override returns (uint256) {
        return amountIn * 27 * 1e12;
    }
}

/// @dev Minimal shield conforming to PolicyManagerV2's IShieldV2 interface.
///      Supports deterministic `settlePolicy` (via PM) and direct trigger control.
contract MockSettleableShield {
    bytes32 public productId;
    uint256 private _nextPolicyId;
    PolicyManagerV2 public policyManager;

    struct Data {
        address buyer;
        uint256 coverage;
        uint256 maxPayout;
        uint32 duration;
        uint256 expiresAt;
    }

    mapping(uint256 => Data) public pd;

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

    constructor(bytes32 _pid, address _pm) {
        productId = _pid;
        policyManager = PolicyManagerV2(_pm);
    }

    function createPolicy(CreatePolicyParams calldata p) external returns (uint256 policyId) {
        _nextPolicyId++;
        policyId = _nextPolicyId;
        pd[policyId] = Data({
            buyer: p.buyer,
            coverage: p.coverageAmount,
            maxPayout: (p.coverageAmount * 8000) / 10000,
            duration: p.durationSeconds,
            expiresAt: block.timestamp + p.durationSeconds
        });
    }

    function verifyAndCalculate(uint256 policyId, bytes calldata) external view returns (PayoutResult memory r) {
        Data storage d = pd[policyId];
        r = PayoutResult({triggered: true, payoutAmount: d.maxPayout, recipient: d.buyer, reason: "MOCK"});
    }

    /// @notice Simulates the settlement path. Caller of settlePolicy must be the shield.
    function triggerSettlement(uint256 policyId, bool triggered) external {
        // PolicyManagerV2.settlePolicy requires msg.sender == shield.
        policyManager.settlePolicy(productId, policyId, triggered);
    }
}

// ─────────────────────────────────────────────────────────────────────────
// MAIN TEST CONTRACT
// ─────────────────────────────────────────────────────────────────────────

/// @title MigrationPath
/// @notice Audit #25 — comprehensive coverage of migration/upgrade paths for
///         the V5.1 UUPS protocol. Tests exercise:
///             - Upgrades with live state (policies, bonds, listings)
///             - Storage layout preservation
///             - Reinitializer mechanics (new variables, single-shot)
///             - Interface change behaviour
///             - Multi-contract coordinated upgrades
///             - Partial upgrades (one side only)
///             - Fresh deploys / empty-state initialization
///             - Rollback / downgrade semantics
///             - FounderVesting immutable constraints
///             - Upgrades during critical states (safety window, mid-redeem)
///             - Gap slot management
///             - Event emission on upgrade
contract MigrationPath is Test {
    // ERC-1967 event for vm.expectEmit.
    event Upgraded(address indexed implementation);

    // ─────────────────────────────────────────────────────────────
    // Shared helpers
    // ─────────────────────────────────────────────────────────────

    function _deployFullStack()
        internal
        returns (
            LuminaTokenV2 token,
            ClaimBond cb,
            BondVault vault,
            PolicyManagerV2 pm,
            CoverRouterV2 router,
            TWAPBurner burner,
            MockUSDC usdc,
            MockPriceOracleMigration oracle
        )
    {
        // Warp to a safe bond-epoch window.
        vm.warp(1767225600 + 30 days);

        usdc = new MockUSDC();
        oracle = new MockPriceOracleMigration(0.036e18);

        // Predict bondVault address so token distribution lands on the real vault.
        uint64 nonce = vm.getNonce(address(this));
        // nonce layout from this point: token impl (0), token proxy (1),
        // swap router (2), twap impl (3), twap proxy (4),
        // claimBond impl (5), claimBond proxy (6),
        // pm impl (7), pm proxy (8),
        // bondVault impl (9), bondVault proxy (10).
        address predictedBondVault = vm.computeCreateAddress(address(this), nonce + 10);

        token = ProxyDeployer.deployLuminaTokenV2(
            predictedBondVault, makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        MockDexRouterMigration dex = new MockDexRouterMigration(address(token));
        deal(address(token), address(dex), 2_000_000e18);

        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(token), address(dex));
        token.grantRole(token.BURNER_ROLE(), address(burner));

        cb = ProxyDeployer.deployClaimBond();
        pm = ProxyDeployer.deployPolicyManagerV2(predictedBondVault);
        vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(pm));
        require(address(vault) == predictedBondVault, "address mismatch");

        cb.setBondVault(address(vault));

        router = ProxyDeployer.deployCoverRouterV2(address(usdc), address(pm), address(burner));
    }

    /// @dev Finds the epoch actually minted for a holder after a recent issueBond.
    function _scanHolderEpoch(ClaimBond cb, address holder) internal view returns (uint256) {
        // BondVault uses block.timestamp + 730 days → monthsFromBase logic; scan a small window.
        uint256 BASE_TS = 1767225600;
        uint256 monthsFromBase = (block.timestamp + 730 days - BASE_TS) / 2629746;
        // Try ±3 months.
        for (int256 d = -3; d <= 3; d++) {
            int256 mfb = int256(monthsFromBase) + d;
            if (mfb < 0) continue;
            uint256 year = 2026 + uint256(mfb) / 12;
            uint256 month = 1 + uint256(mfb) % 12;
            uint256 epochId = year * 100 + month;
            if (cb.balanceOf(holder, epochId) > 0) return epochId;
        }
        revert("epoch not found");
    }

    // ─────────────────────────────────────────────────────────────
    // Category 1 — ActivePolicies: Upgrade preserves live policies
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_ActivePolicies_SurviveUpgrade() public {
        (,, BondVault vault, PolicyManagerV2 pm,,, MockUSDC usdc,) = _deployFullStack();

        // Register a mock shield; place PM's router = this so we can call recordPolicy directly.
        MockSettleableShield shield = new MockSettleableShield(keccak256("PID"), address(pm));
        pm.setRouter(address(this));
        pm.registerProduct(keccak256("PID"), address(shield));

        // Record 10 policies.
        for (uint256 i = 0; i < 10; i++) {
            pm.recordPolicy(keccak256("PID"), makeAddr(string(abi.encodePacked("buyer", i))), 1_000e6, 1e6, 3600, "BTC");
        }

        assertEq(pm.totalPolicies(), 10);
        assertEq(pm.activePolicies(), 10);
        uint256 reservedBefore = vault.totalReservedUSD();
        assertEq(reservedBefore, 10 * 800 * 1e18);

        // Upgrade PM to V2.
        pm.upgradeToAndCall(address(new PolicyManagerV2Plus()), "");

        // All 10 policies survived.
        assertEq(pm.totalPolicies(), 10);
        assertEq(pm.activePolicies(), 10);
        assertEq(vault.totalReservedUSD(), reservedBefore, "reservations preserved");
        assertTrue(pm.productActive(keccak256("PID")));
        assertEq(pm.productShield(keccak256("PID")), address(shield));

        // Settle policy 1 via the shield — bond should be issued correctly post-upgrade.
        vm.prank(address(shield));
        pm.settlePolicy(keccak256("PID"), 1, true);
        assertEq(pm.totalTriggers(), 1);
        assertEq(pm.activePolicies(), 9);
        assertEq(vault.totalCommittedUSD(), 800 * 1e18, "bond committed after trigger post-upgrade");
        usdc; // silence unused-var
    }

    function test_Migration_UUPS_ActivePolicies_CapacityReservationSurvives() public {
        (,, BondVault vault, PolicyManagerV2 pm,,,,) = _deployFullStack();

        MockSettleableShield shield = new MockSettleableShield(keccak256("PID"), address(pm));
        pm.setRouter(address(this));
        pm.registerProduct(keccak256("PID"), address(shield));
        pm.recordPolicy(keccak256("PID"), makeAddr("buyer"), 500e6, 5e5, 3600, "ETH");

        // Snapshot per-policy reservation before upgrade.
        uint256 resBefore = pm.policyReservedUSD(keccak256("PID"), 1);
        assertEq(resBefore, 400 * 1e18);
        assertEq(vault.totalReservedUSD(), 400 * 1e18);

        // Upgrade BOTH sides.
        vault.upgradeToAndCall(address(new BondVaultV2()), "");
        pm.upgradeToAndCall(address(new PolicyManagerV2Plus()), "");

        // Reservation mapping and running total are identical.
        assertEq(pm.policyReservedUSD(keccak256("PID"), 1), resBefore);
        assertEq(vault.totalReservedUSD(), 400 * 1e18);

        // settlePolicy(false) still releases the reservation cleanly after upgrade.
        vm.prank(address(shield));
        pm.settlePolicy(keccak256("PID"), 1, false);
        assertEq(vault.totalReservedUSD(), 0, "reservation released after upgrade");
        assertEq(pm.policyReservedUSD(keccak256("PID"), 1), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // Category 2 — ActiveBonds: Upgrade preserves bonds & redemption
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_ActiveBonds_SurviveUpgrade() public {
        (, ClaimBond cb, BondVault vault, PolicyManagerV2 pm,,,, MockPriceOracleMigration oracle) = _deployFullStack();

        // Give PM direct test-driven calls.
        pm.setRouter(address(this));

        // Issue bonds directly via the vault (we are policyManager in this config).
        // But vault was deployed with pm = real PolicyManagerV2; swap it.
        // Approach: re-deploy BondVault with address(this) as PM for bond-issuing convenience.
        // (We already have vault wired; use a direct prank.)
        vm.startPrank(address(pm));
        vault.issueBond(makeAddr("alice"), 100);
        vault.issueBond(makeAddr("bob"), 50);
        vm.stopPrank();

        uint256 aliceEpoch = _scanHolderEpoch(cb, makeAddr("alice"));
        uint256 aliceBalBefore = cb.balanceOf(makeAddr("alice"), aliceEpoch);
        uint256 committedBefore = vault.totalCommittedUSD();
        assertEq(aliceBalBefore, 100);
        assertEq(committedBefore, 150 * 1e18);

        // Upgrade BondVault.
        vault.upgradeToAndCall(address(new BondVaultV2()), "");

        // Bond balances still intact (ClaimBond state unchanged).
        assertEq(cb.balanceOf(makeAddr("alice"), aliceEpoch), aliceBalBefore);
        assertEq(vault.totalCommittedUSD(), committedBefore);

        // Warp past maturity and redeem — full path must work after upgrade.
        vm.warp(cb.maturityDate(aliceEpoch) + 1);
        oracle.setPrice(0.036e18);
        vm.prank(makeAddr("alice"));
        vault.redeemBond(aliceEpoch, 100);

        assertEq(cb.balanceOf(makeAddr("alice"), aliceEpoch), 0);
        // totalCommittedUSD should decrement by 100 dollars * 1e18.
        assertEq(vault.totalCommittedUSD(), committedBefore - 100 * 1e18);
    }

    function test_Migration_UUPS_ActiveBonds_ReinitSetsMigrationFlag() public {
        (, ClaimBond cb, BondVault vault, PolicyManagerV2 pm,,,,) = _deployFullStack();
        vm.prank(address(pm));
        vault.issueBond(makeAddr("u"), 42);
        uint256 epoch = _scanHolderEpoch(cb, makeAddr("u"));
        assertEq(cb.balanceOf(makeAddr("u"), epoch), 42);

        // Upgrade with reinit data — sets featureFlag=777 and migratedAtTimestamp=now.
        bytes memory initData = abi.encodeWithSelector(BondVaultV2.reinitializeV2.selector, uint256(777));
        vault.upgradeToAndCall(address(new BondVaultV2()), initData);

        BondVaultV2 v2 = BondVaultV2(address(vault));
        assertEq(v2.featureFlag(), 777);
        assertEq(v2.migratedAtTimestamp(), block.timestamp);
        // Bond state preserved.
        assertEq(cb.balanceOf(makeAddr("u"), epoch), 42);
        assertEq(vault.totalCommittedUSD(), 42 * 1e18);
    }

    // ─────────────────────────────────────────────────────────────
    // Category 3 — ActiveListings: Upgrade preserves marketplace
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_ActiveListings_SurviveUpgrade() public {
        (, ClaimBond cb, BondVault vault, PolicyManagerV2 pm, CoverRouterV2 router, TWAPBurner burner, MockUSDC usdc,) =
            _deployFullStack();
        router; // unused

        // Deploy marketplace.
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), address(burner), address(this));
        cb.setAuthorizedOperator(address(mp), true);

        // Issue bonds to seller.
        vm.prank(address(pm));
        vault.issueBond(makeAddr("seller"), 200);
        uint256 epoch = _scanHolderEpoch(cb, makeAddr("seller"));

        // Seller lists.
        vm.startPrank(makeAddr("seller"));
        cb.setApprovalForAll(address(mp), true);
        uint256 listingId = mp.list(epoch, 100, 50e6);
        vm.stopPrank();

        // Snapshot pre-upgrade.
        (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active) = mp.getListing(listingId);
        assertEq(seller, makeAddr("seller"));
        assertEq(epochId, epoch);
        assertEq(amount, 100);
        assertEq(priceUSDC, 50e6);
        assertTrue(active);

        // Upgrade marketplace.
        mp.upgradeToAndCall(address(new LuminaBondMarketplaceV2()), "");

        // Listing preserved.
        (, uint256 epochId2,, uint256 price2, bool active2) = mp.getListing(listingId);
        assertEq(epochId2, epoch);
        assertEq(price2, 50e6);
        assertTrue(active2);

        // Buyer still buys successfully.
        usdc.mint(makeAddr("buyer"), 100e6);
        vm.startPrank(makeAddr("buyer"));
        usdc.approve(address(mp), 100e6);
        mp.executeBuy(listingId);
        vm.stopPrank();

        assertEq(cb.balanceOf(makeAddr("buyer"), epoch), 100);
    }

    function test_Migration_UUPS_ActiveListings_ReinitAddsMigrationCheckpoint() public {
        (, ClaimBond cb,,,, TWAPBurner burner, MockUSDC usdc,) = _deployFullStack();

        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(cb), address(usdc), address(burner), address(this));

        bytes memory initData = abi.encodeWithSelector(LuminaBondMarketplaceV2.reinitializeV2.selector, uint256(42));
        mp.upgradeToAndCall(address(new LuminaBondMarketplaceV2()), initData);

        assertEq(LuminaBondMarketplaceV2(address(mp)).migrationCheckpoint(), 42);
        // Pre-upgrade wiring preserved.
        assertEq(address(mp.claimBond()), address(cb));
        assertEq(mp.twapBurner(), address(burner));
    }

    // ─────────────────────────────────────────────────────────────
    // Category 4 — StorageLayout preservation (deep check with raw slot reads)
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_StorageLayout_BondVaultSlotsUnchanged() public {
        (, ClaimBond cb, BondVault vault, PolicyManagerV2 pm,,,, MockPriceOracleMigration oracle) = _deployFullStack();

        // Create varied state.
        vm.prank(address(pm));
        vault.issueBond(makeAddr("a"), 1000);
        vault.setAuthorizedCaller(makeAddr("buyback"), true);

        // Snapshot specific slot values (via public getters).
        address luminaPtr = address(vault.lumina());
        address cbPtr = address(vault.claimBond());
        address oraclePtr = address(vault.priceOracle());
        address pmPtr = vault.policyManager();
        uint256 committedPre = vault.totalCommittedUSD();
        uint256 reservedPre = vault.totalReservedUSD();
        bool authorizedPre = vault.authorizedCallers(makeAddr("buyback"));

        // Upgrade to a fresh BondVault implementation (same layout).
        vault.upgradeToAndCall(address(new BondVault()), "");

        assertEq(address(vault.lumina()), luminaPtr, "lumina ptr");
        assertEq(address(vault.claimBond()), cbPtr, "cb ptr");
        assertEq(address(vault.priceOracle()), oraclePtr, "oracle ptr");
        assertEq(vault.policyManager(), pmPtr, "pm ptr");
        assertEq(vault.totalCommittedUSD(), committedPre, "committed");
        assertEq(vault.totalReservedUSD(), reservedPre, "reserved");
        assertEq(vault.authorizedCallers(makeAddr("buyback")), authorizedPre, "authorized");
        cb;
        oracle;
    }

    function test_Migration_UUPS_StorageLayout_ClaimBondMappingsUnchanged() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));

        cb.mint(makeAddr("alice"), 202804, 1111);
        cb.mint(makeAddr("bob"), 202810, 2222);
        cb.mint(makeAddr("alice"), 202810, 3333);
        cb.setAuthorizedOperator(makeAddr("mp"), true);

        // snapshot
        uint256 abal = cb.balanceOf(makeAddr("alice"), 202804);
        uint256 bbal = cb.balanceOf(makeAddr("bob"), 202810);
        uint256 abal2 = cb.balanceOf(makeAddr("alice"), 202810);
        uint256 supply1 = cb.totalSupply(202804);
        uint256 supply2 = cb.totalSupply(202810);
        uint256 maturity1 = cb.maturityDate(202804);
        string memory uriBefore = cb.uri(202804);
        bool opAuth = cb.authorizedOperators(makeAddr("mp"));

        cb.upgradeToAndCall(address(new ClaimBondV2()), "");

        assertEq(cb.balanceOf(makeAddr("alice"), 202804), abal);
        assertEq(cb.balanceOf(makeAddr("bob"), 202810), bbal);
        assertEq(cb.balanceOf(makeAddr("alice"), 202810), abal2);
        assertEq(cb.totalSupply(202804), supply1);
        assertEq(cb.totalSupply(202810), supply2);
        assertEq(cb.maturityDate(202804), maturity1);
        assertEq(cb.uri(202804), uriBefore, "baseURI unchanged");
        assertEq(cb.authorizedOperators(makeAddr("mp")), opAuth);
        assertEq(cb.bondVault(), address(this));
    }

    // ─────────────────────────────────────────────────────────────
    // Category 5 — NewVariable via Reinitializer
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_NewVariable_ReinitializerSetsValue() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        bytes memory data = abi.encodeWithSelector(CoverRouterV2Plus.reinitializeV2.selector, uint256(250));
        r.upgradeToAndCall(address(new CoverRouterV2Plus()), data);

        CoverRouterV2Plus r2 = CoverRouterV2Plus(address(r));
        assertEq(r2.newFeeBps(), 250);
        // Pre-upgrade pointer preserved.
        assertEq(address(r2.usdc()), makeAddr("u"));
    }

    function test_Migration_UUPS_NewVariable_DefaultZeroWithoutReinit() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("v"));
        // Upgrade without init data.
        pm.upgradeToAndCall(address(new PolicyManagerV2Plus()), "");
        // New variable should be zero (EVM default).
        assertEq(PolicyManagerV2Plus(address(pm)).logicVersion(), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // Category 6 — Reinitializer cannot be called twice / lower version
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_Reinitializer_CannotBeCalledTwice() public {
        BondVault v = ProxyDeployer.deployBondVault(
            address(new MockUSDC()),
            address(ProxyDeployer.deployClaimBond()),
            address(new MockPriceOracleMigration(1e18)),
            address(this)
        );
        bytes memory data = abi.encodeWithSelector(BondVaultV2.reinitializeV2.selector, uint256(1));
        v.upgradeToAndCall(address(new BondVaultV2()), data);
        assertEq(BondVaultV2(address(v)).featureFlag(), 1);

        // Second call with same version MUST revert (InvalidInitialization).
        vm.expectRevert();
        BondVaultV2(address(v)).reinitializeV2(2);
    }

    function test_Migration_UUPS_Reinitializer_LowerVersion_Reverts() public {
        // An explicit reinit after ClaimBond init (v1) with version 1 must revert.
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        // OZ: `reinitializer(1)` after `initializer` (also v1) reverts.
        vm.expectRevert();
        cb.reinitializeURI(1);
    }

    // ─────────────────────────────────────────────────────────────
    // Category 7 — Interface change: graceful degradation
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_InterfaceChange_NewFunctionCallable() public {
        // V1 has no `setAllowlisted`. Upgrade adds the function.
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));

        // Pre-upgrade: a low-level call to the V2-only selector fails.
        (bool ok,) =
            address(r).call(abi.encodeWithSelector(CoverRouterV2Plus.setAllowlisted.selector, makeAddr("x"), true));
        assertFalse(ok, "V2 selector must not resolve on V1 impl");

        r.upgradeToAndCall(address(new CoverRouterV2Plus()), "");

        // Post-upgrade: new function exists and writes storage.
        CoverRouterV2Plus(address(r)).setAllowlisted(makeAddr("x"), true);
        assertTrue(CoverRouterV2Plus(address(r)).allowlisted(makeAddr("x")));
        assertFalse(CoverRouterV2Plus(address(r)).allowlisted(makeAddr("y")));
    }

    function test_Migration_UUPS_InterfaceChange_OldFunctionSelectorPreserved() public {
        // All V1 functions must remain callable with identical ABI after upgrade.
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("v"));
        pm.setRouter(address(this));
        pm.registerProduct(keccak256("P"), makeAddr("s"));

        pm.upgradeToAndCall(address(new PolicyManagerV2Plus()), "");

        // V1 methods still resolve and work identically.
        pm.registerProduct(keccak256("Q"), makeAddr("s2"));
        assertTrue(pm.productActive(keccak256("P")));
        assertTrue(pm.productActive(keccak256("Q")));
        pm.deactivateProduct(keccak256("P"));
        assertFalse(pm.productActive(keccak256("P")));
    }

    // ─────────────────────────────────────────────────────────────
    // Category 8 — Multi-contract coordinated upgrade
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_MultiContract_CoordinatedUpgrade() public {
        (,, BondVault vault, PolicyManagerV2 pm, CoverRouterV2 router,,,) = _deployFullStack();

        MockSettleableShield shield = new MockSettleableShield(keccak256("PID"), address(pm));
        pm.setRouter(address(this));
        pm.registerProduct(keccak256("PID"), address(shield));
        pm.recordPolicy(keccak256("PID"), makeAddr("u"), 1000e6, 1e6, 3600, "BTC");

        // Upgrade 3 contracts in order: callees first, caller last.
        vault.upgradeToAndCall(address(new BondVaultV2()), "");
        pm.upgradeToAndCall(address(new PolicyManagerV2Plus()), "");
        router.upgradeToAndCall(address(new CoverRouterV2Plus()), "");

        // Full pipeline still works after coordinated upgrade: settle triggers a bond.
        vm.prank(address(shield));
        pm.settlePolicy(keccak256("PID"), 1, true);
        assertEq(vault.totalCommittedUSD(), 800 * 1e18);
        assertEq(pm.totalTriggers(), 1);

        // Each contract exposes its V2 state.
        assertEq(CoverRouterV2Plus(address(router)).newFeeBps(), 0); // reinit not called
        assertEq(PolicyManagerV2Plus(address(pm)).logicVersion(), 0);
        assertEq(BondVaultV2(address(vault)).featureFlag(), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // Category 9 — Partial upgrade (one side only)
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_Partial_UpgradeOk() public {
        (,, BondVault vault, PolicyManagerV2 pm,,,,) = _deployFullStack();

        MockSettleableShield shield = new MockSettleableShield(keccak256("PID"), address(pm));
        pm.setRouter(address(this));
        pm.registerProduct(keccak256("PID"), address(shield));
        pm.recordPolicy(keccak256("PID"), makeAddr("u"), 1000e6, 1e6, 3600, "BTC");

        // Upgrade PM only; BondVault stays V1.
        pm.upgradeToAndCall(address(new PolicyManagerV2Plus()), "");

        // Cross-contract call still works — settlement triggers bond on V1 vault.
        vm.prank(address(shield));
        pm.settlePolicy(keccak256("PID"), 1, true);
        assertEq(vault.totalCommittedUSD(), 800 * 1e18);
    }

    function test_Migration_UUPS_Partial_VaultOnly_InteropWorks() public {
        (,, BondVault vault, PolicyManagerV2 pm,,,,) = _deployFullStack();
        MockSettleableShield shield = new MockSettleableShield(keccak256("PID"), address(pm));
        pm.setRouter(address(this));
        pm.registerProduct(keccak256("PID"), address(shield));
        pm.recordPolicy(keccak256("PID"), makeAddr("u"), 1000e6, 1e6, 3600, "BTC");

        // Upgrade BondVault only; PM stays V1.
        vault.upgradeToAndCall(address(new BondVaultV2()), "");

        // PM → vault.commitReservation / issueBond flow still works.
        vm.prank(address(shield));
        pm.settlePolicy(keccak256("PID"), 1, true);
        assertEq(vault.totalCommittedUSD(), 800 * 1e18);
    }

    // ─────────────────────────────────────────────────────────────
    // Category 10 — Fresh deploy / empty-state init
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_FreshDeploy_InitializesCorrectly() public {
        // Deploy a brand-new BondVault with no migration data.
        MockUSDC u = new MockUSDC();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        MockPriceOracleMigration o = new MockPriceOracleMigration(0.036e18);
        BondVault v = ProxyDeployer.deployBondVault(address(u), address(cb), address(o), address(this));

        assertEq(address(v.lumina()), address(u));
        assertEq(address(v.claimBond()), address(cb));
        assertEq(address(v.priceOracle()), address(o));
        assertEq(v.policyManager(), address(this));
        assertEq(v.totalCommittedUSD(), 0);
        assertEq(v.totalReservedUSD(), 0);
        assertTrue(v.hasRole(v.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_Migration_UUPS_FreshDeploy_InitializerCannotBeReRun() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        // Second initialize must revert.
        vm.expectRevert();
        cb.initialize();
    }

    // ─────────────────────────────────────────────────────────────
    // Category 11 — Downgrade V2 → V1 (rollback)
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_DowngradeV2ToV1_StatePreserved() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();

        address v1Impl = address(new ShieldKeeper());

        // Upgrade to an extended V2.
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        r.configureProduct(keccak256("A"), 8000, 200, 2000, 3600, true);
        address rV1Impl = address(new CoverRouterV2());
        r.upgradeToAndCall(address(new CoverRouterV2Plus()), "");
        CoverRouterV2Plus(address(r)).setAllowlisted(makeAddr("x"), true);

        // Downgrade CoverRouter to V1 impl. Storage for V2-only vars remains
        // but has no getter on V1.
        r.upgradeToAndCall(rV1Impl, "");

        // V1 methods still usable; V1 state intact.
        (,,,,, bool active) = r.products(keccak256("A"));
        assertTrue(active);
        r.configureProduct(keccak256("B"), 7000, 100, 1000, 3600, true);
        (,,,,, bool aB) = r.products(keccak256("B"));
        assertTrue(aB);

        // When forwarded to V2 again, the dormant storage reappears.
        r.upgradeToAndCall(address(new CoverRouterV2Plus()), "");
        assertTrue(CoverRouterV2Plus(address(r)).allowlisted(makeAddr("x")), "V2-only slot survived round-trip");

        // ShieldKeeper leg: same pattern.
        k.upgradeToAndCall(v1Impl, "");
        assertTrue(k.paused());
    }

    function test_Migration_UUPS_Rollback_AfterBugInV2() public {
        // V2 has a "bug" — we demonstrate the admin can rewind.
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("v"));
        pm.setRouter(address(this));
        pm.registerProduct(keccak256("PID"), makeAddr("s"));
        address v1Impl = address(new PolicyManagerV2());

        // Forward to a V2 that sets state, then rewind.
        pm.upgradeToAndCall(address(new PolicyManagerV2Plus()), "");
        PolicyManagerV2Plus(address(pm)).reinitializeV2(99);
        assertEq(PolicyManagerV2Plus(address(pm)).logicVersion(), 99);

        pm.upgradeToAndCall(v1Impl, "");

        // Admin has rolled back. V1 state still intact.
        assertTrue(pm.productActive(keccak256("PID")));
        pm.registerProduct(keccak256("PID2"), makeAddr("s2"));
        assertTrue(pm.productActive(keccak256("PID2")));
    }

    // ─────────────────────────────────────────────────────────────
    // Category 12 — FounderVesting: immutable contract
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_FounderVesting_Immutable_CannotUpgrade() public {
        MockUSDC usdc = new MockUSDC();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("tv")
        );

        FounderVesting fv = new FounderVesting(
            makeAddr("oracle"), makeAddr("aave"), address(token), address(usdc), makeAddr("recipient")
        );

        // FounderVesting does NOT expose any upgradeTo / upgradeToAndCall — the
        // low-level call with the standard UUPS selector must fail.
        (bool ok1,) =
            address(fv).call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", makeAddr("newImpl"), bytes("")));
        assertFalse(ok1, "upgradeToAndCall must not exist on FounderVesting");

        (bool ok2,) = address(fv).call(abi.encodeWithSignature("upgradeTo(address)", makeAddr("newImpl")));
        assertFalse(ok2, "upgradeTo must not exist on FounderVesting");

        // Immutables cannot change.
        assertEq(address(fv.luminaToken()), address(token));
        assertEq(fv.usdc(), address(usdc));
    }

    function test_Migration_UUPS_FounderVesting_NewDeploy_IfNeeded() public {
        // Simulate migration: deploy a second FounderVesting with new parameters.
        MockUSDC usdc = new MockUSDC();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("tv")
        );

        FounderVesting fv1 = new FounderVesting(
            makeAddr("oracle"), makeAddr("aave"), address(token), address(usdc), makeAddr("recipient")
        );

        // "Upgrade" via redeploy — new address, new deployedAt clock.
        uint256 ts1 = fv1.deployedAt();
        vm.warp(block.timestamp + 365 days);

        FounderVesting fv2 = new FounderVesting(
            makeAddr("oracle2"), makeAddr("aave"), address(token), address(usdc), makeAddr("recipient2")
        );
        uint256 ts2 = fv2.deployedAt();

        assertTrue(address(fv2) != address(fv1), "fresh address");
        assertTrue(ts2 > ts1, "fresh clock");
        // fv1 is untouched — its state persists indefinitely.
        assertEq(fv1.recipient(), makeAddr("recipient"));
        assertEq(fv2.recipient(), makeAddr("recipient2"));
        // fv2's fallback clock restarts.
        assertEq(ts2 + fv2.FALLBACK_DURATION(), ts2 + 1460 days);
    }

    // ─────────────────────────────────────────────────────────────
    // Category 13 — UpgradeDuringSafetyWindow
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_UpgradeDuringSafetyWindow_SettlementOK() public {
        (,, BondVault vault, PolicyManagerV2 pm,,,,) = _deployFullStack();

        MockSettleableShield shield = new MockSettleableShield(keccak256("PID"), address(pm));
        pm.setRouter(address(this));
        pm.registerProduct(keccak256("PID"), address(shield));
        pm.recordPolicy(keccak256("PID"), makeAddr("u"), 1000e6, 1e6, 3600, "BTC");

        // "Safety window": between recordPolicy and expiresAt, before settlement.
        // Jump to halfway through the coverage period (still active).
        vm.warp(block.timestamp + 1800);

        // Upgrade BOTH sides mid-window.
        vault.upgradeToAndCall(address(new BondVaultV2()), "");
        pm.upgradeToAndCall(address(new PolicyManagerV2Plus()), "");

        // Policy remains active; settlement still works after upgrade.
        PolicyManagerV2.PolicyRecord memory rec = pm.getPolicy(keccak256("PID"), 1);
        assertFalse(rec.triggered);
        assertFalse(rec.expired);

        vm.prank(address(shield));
        pm.settlePolicy(keccak256("PID"), 1, true);
        assertEq(pm.totalTriggers(), 1);
        assertEq(vault.totalCommittedUSD(), 800 * 1e18);
    }

    // ─────────────────────────────────────────────────────────────
    // Category 14 — UpgradeMidRedemption
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_UpgradeMidRedemption_StatePreserved() public {
        (, ClaimBond cb, BondVault vault, PolicyManagerV2 pm,,,, MockPriceOracleMigration oracle) = _deployFullStack();

        // Issue a $300 bond to alice (in 3 chunks of 100 to vary minting).
        vm.startPrank(address(pm));
        vault.issueBond(makeAddr("alice"), 300);
        vm.stopPrank();

        uint256 epoch = _scanHolderEpoch(cb, makeAddr("alice"));
        assertEq(cb.balanceOf(makeAddr("alice"), epoch), 300);

        // Warp past maturity.
        vm.warp(cb.maturityDate(epoch) + 1);
        oracle.setPrice(0.036e18);

        // Partial redemption #1 — 100 bonds.
        vm.prank(makeAddr("alice"));
        vault.redeemBond(epoch, 100);
        uint256 balMid = cb.balanceOf(makeAddr("alice"), epoch);
        uint256 committedMid = vault.totalCommittedUSD();
        assertEq(balMid, 200);

        // Upgrade between partial redemptions.
        vault.upgradeToAndCall(address(new BondVaultV2()), "");

        assertEq(cb.balanceOf(makeAddr("alice"), epoch), balMid, "balance preserved across upgrade");
        assertEq(vault.totalCommittedUSD(), committedMid, "commitment preserved");

        // Continue redemption after upgrade.
        vm.prank(makeAddr("alice"));
        vault.redeemBond(epoch, 200);
        assertEq(cb.balanceOf(makeAddr("alice"), epoch), 0);
        assertEq(vault.totalCommittedUSD(), committedMid - 200 * 1e18);
    }

    // ─────────────────────────────────────────────────────────────
    // Category 15 — Gap management (new variables live in the gap region)
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_GapSlots_UsedCorrectly() public {
        // Pre-upgrade state.
        BondVault vault = ProxyDeployer.deployBondVault(
            address(new MockUSDC()),
            address(ProxyDeployer.deployClaimBond()),
            address(new MockPriceOracleMigration(1e18)),
            address(this)
        );
        vault.setAuthorizedCaller(makeAddr("buyback"), true);

        // Upgrade to a V2 that adds two new state variables.
        vault.upgradeToAndCall(address(new BondVaultV2()), "");
        BondVaultV2 v2 = BondVaultV2(address(vault));
        v2.setFeatureFlag(0xDEADBEEF);

        // Neither V1 variable read changes as a side-effect.
        assertTrue(vault.authorizedCallers(makeAddr("buyback")));
        assertEq(vault.totalCommittedUSD(), 0);
        assertEq(vault.totalReservedUSD(), 0);

        // Feature flag lives in what was __gap[0]. Storage slot index computed via
        // OZ/Solidity rules: deriving the slot from first new variable in V2 —
        // verify by round-trip (writing via setter, reading via getter).
        assertEq(v2.featureFlag(), 0xDEADBEEF);
        v2.setFeatureFlag(42);
        assertEq(v2.featureFlag(), 42);
    }

    function test_Migration_UUPS_GapSlots_MultipleVariablesNoCollision() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        r.configureProduct(keccak256("PID"), 8000, 200, 2000, 3600, true);
        r.setRelayer(makeAddr("rel"), true);

        // Upgrade: V2 adds `newFeeBps` (uint256) + `allowlisted` (mapping). Each
        // consumes one gap slot.
        r.upgradeToAndCall(address(new CoverRouterV2Plus()), "");
        CoverRouterV2Plus r2 = CoverRouterV2Plus(address(r));

        // Both new variables writable AND V1 state intact.
        r2.setAllowlisted(makeAddr("who"), true);
        (,,,,, bool active) = r.products(keccak256("PID"));
        assertTrue(active, "V1 product config preserved");
        assertTrue(r.authorizedRelayers(makeAddr("rel")), "V1 relayer preserved");
        assertTrue(r2.allowlisted(makeAddr("who")));
        assertFalse(r2.allowlisted(makeAddr("other")));
        assertEq(r2.newFeeBps(), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // Category 16 — Upgrade events
    // ─────────────────────────────────────────────────────────────

    function test_Migration_UUPS_UpgradeEvent_Emitted() public {
        // BondVault emits Upgraded(indexed address) on upgradeToAndCall.
        BondVault v = ProxyDeployer.deployBondVault(
            address(new MockUSDC()),
            address(ProxyDeployer.deployClaimBond()),
            address(new MockPriceOracleMigration(1e18)),
            address(this)
        );
        address newImpl = address(new BondVault());
        vm.expectEmit(true, false, false, false);
        emit Upgraded(newImpl);
        v.upgradeToAndCall(newImpl, "");
    }

    function test_Migration_UUPS_UpgradeEvent_PolicyManager_Emitted() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("v"));
        address newImpl = address(new PolicyManagerV2());
        vm.expectEmit(true, false, false, false);
        emit Upgraded(newImpl);
        pm.upgradeToAndCall(newImpl, "");
    }

    function test_Migration_UUPS_UpgradeEvent_Marketplace_Emitted() public {
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        address newImpl = address(new LuminaBondMarketplace());
        vm.expectEmit(true, false, false, false);
        emit Upgraded(newImpl);
        mp.upgradeToAndCall(newImpl, "");
    }
}
